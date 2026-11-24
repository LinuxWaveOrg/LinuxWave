#!/usr/bin/env python3

# pkginstaller.py

import os
import sys
import contextlib
import json
import hashlib
import shutil
import time
import platform
import subprocess
import re
import grp
import pwd
from pathlib import Path


# -------------------- 颜色定义 --------------------

RED_BOLD = '\033[1;31m'
GREEN = '\033[32m'
YELLOW = '\033[33m'
RESET = '\033[0m'

# -------------------- 配置加载 --------------------

import common
import domains
import flags as flags_module
import silent
import steplog
import tls
from configpaths import (
    VERSION_FILE,
    assert_inside,
    load_base_dir,
    require_safe_filename,
    require_safe_token,
)


def github_api_headers(url):
    # api.github.com 未认证只有 60 次/小时，CI Runner / 办公网常常整栋楼共用一个出口 IP，
    # 很容易被限流（表现是 "Cannot fetch package list."）。有 token 就带上；
    # 只发给 api.github.com，raw.githubusercontent.com 与各下载站都不带。
    if "api.github.com" not in url:
        return {}
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if not token:
        return {}
    return {"Authorization": f"Bearer {token}"}


def get_version():
    if VERSION_FILE.exists():
        try:
            with open(VERSION_FILE, 'r') as f:
                data = json.load(f)
                return data.get("version", "unknown")
        except Exception:
            pass
    return "unknown"


BASE_DIR = load_base_dir()
DOWNLOAD_TMP = BASE_DIR / "downloads" / "tmp"

# -------------------- 依赖库检查 --------------------

try:
    import requests
    from requests.exceptions import HTTPError, ConnectionError, Timeout
except ImportError:
    print(f"{RED_BOLD}🌊 Error: 'requests' library is not installed.{RESET}")
    print(f"{RED_BOLD}🌊 Please install it using: pip3 install requests{RESET}")
    sys.exit(1)

try:
    from packaging.version import parse as parse_version, InvalidVersion
except ImportError:
    print(f"{RED_BOLD}🌊 Error: 'packaging' library is not installed.{RESET}")
    print(f"{RED_BOLD}🌊 Please install it using: pip3 install packaging{RESET}")
    sys.exit(1)

try:
    from rich.progress import (
        Progress, BarColumn, DownloadColumn, TextColumn,
        TimeRemainingColumn,
    )
    from rich.console import Console
    RICH_AVAILABLE = True
except ImportError:
    RICH_AVAILABLE = False

try:
    from depsinstaller import (
        install_dependencies, parse_common_fields, get_field, get_deps,
        transfer_installed_artifacts,
    )
except ImportError as error:
    print(f"{RED_BOLD}🌊 Error: 'surfboard' module is not available ({error}).{RESET}")
    sys.exit(1)


# -------------------- 辅助函数 --------------------

def _check_disk_space(path: Path, required_bytes: int = 10 * 1024 * 1024) -> bool:
    total, used, free = shutil.disk_usage(path)
    if free < required_bytes:
        print(f"{RED_BOLD}🌊 Error: Insufficient disk space in {path}.{RESET}")
        sys.exit(1)
    return True


# -------------------- 参数解析 --------------------

def parse_flags(input_string, command="install", shown=None):
    """校验这条命令接受的旗标；不在白名单里的就报错退出。

    白名单与报错文案的唯一判定处是 cli/common.py 的 check_allowed()：
    词法（`--name=value`、`-vC`、单独的 `-`）、别名（--unlink → --no-link）、
    拼错建议与静默输出都在那里。

    command / shown 给 upgrade 用：它内部会构造一条 `wave install placeholder …`
    的探针来复用 install 的解析路径，那条探针只该用于解析，报错必须说
    `wave upgrade` 并回显用户真正敲的那一行。

    白名单始终取 install 的（allow_from）：upgrade 能接受的就是 install 能接受的，
    减去它在 split_input 里已经剥掉的 -X / --all。--ver / --unlink 因此会走到
    upgrader 的 REJECTED_FLAGS，由那里给出比「这个命令不认」更具体的替代做法。
    """
    return common.check_allowed(input_string, command, shown=shown, allow_from="install")


def flag_value(input_string, name):
    # 取旗标的值，`--name value` 与 `--name=value` 都支持；没有该旗标时返回 None。
    tokens = input_string.split()
    for index, token in enumerate(tokens):
        if token == name:
            return tokens[index + 1] if index + 1 < len(tokens) else ""
        if token.startswith(name + "="):
            return token[len(name) + 1:]
    return None


# 带值旗标：它们的值不是包名。与 cli/common.py 的 VALUE_EXAMPLES 共用一份，
# 只多一个 --ver（安装独有）。package_specs 与 first_package_token 都读这里，
# 免得两处走散 —— 走散的后果是把 `--proxy http://…` 的地址当成包名去装。
FLAGS_TAKING_VALUE = set(common.VALUE_EXAMPLES) | {"--ver"}


def package_tokens(input_string):
    # `wave install` 之后的词里，哪些是包名（跳过旗标与旗标的值）
    tokens = []
    skip_next = False
    for word in input_string.split()[2:]:
        if skip_next:
            skip_next = False
            continue
        if word in FLAGS_TAKING_VALUE:
            skip_next = True
            continue
        if word.startswith("-"):
            continue
        tokens.append(word)
    return tokens


def first_package_token(input_string):
    # 取第一个真正的包名，
    # 这样 `wave install --unlink wget@1.25.0` 与 `wave install wget@1.25.0 --unlink` 等价
    tokens = package_tokens(input_string)
    return tokens[0] if tokens else None


def package_specs(input_string):
    """把 `wave install` 后面的包名解析成列表。

    两种写法等价，逗号后面有没有空格都行：

        wave install jq, yq, fx@40.0.2
        wave install jq,yq,fx@40.0.2

    规则只有一条：**逗号分隔**。空格也当分隔（把非旗标的词都收下），因为
    `wave install jq yq` 本来就只有一个合理解释 —— 装两个。以前多余的那个被
    静默丢掉，用户以为装上了，`wave list` 里却没有。
    """
    common.reject_fullwidth_comma(input_string)
    return common.split_operands(package_tokens(input_string))


def _flag_words(input_string):
    """原样保留除包名以外的词（旗标及旗标值），供逐个安装时复用。"""
    kept = []
    skip_next = False
    for word in input_string.split()[2:]:
        if skip_next:
            skip_next = False
            kept.append(word)
            continue
        if word in FLAGS_TAKING_VALUE:
            skip_next = True
            kept.append(word)
            continue
        if word.startswith("-"):
            kept.append(word)
    return " ".join(kept)


# 一次安装只问一次：`wave install a b c` 与 `wave upgrade --all` 都会走到这里，
# 每下一个包装一遍同样的问题就成了骚扰。
_SKIP_SSL_ANSWER = None


def confirm_skip_ssl(flags):
    """`--skip-ssl` 的安全询问，并同步 net/tls.py 的状态。返回是否允许跳过校验。

    单独提出来是因为 `upgrade --all` 也要问：它在确认之前就要先取索引里的名字清单，
    若只在 handle_install 里问，那一次请求就享受不到这个旗标。已经授权过就不再问，
    批量升级因此只问一次。

    **拒绝 = 中止整个命令，不是「照装一份带校验的」。** 用户明明写了 --skip-ssl
    却拿到一个 SSL 错误，看起来像旗标没生效，实际是他自己刚拒绝过。
    """
    global _SKIP_SSL_ANSWER
    if tls.enabled():
        return True
    if "--skip-ssl" not in flags:
        tls.revoke()
        _SKIP_SSL_ANSWER = False
        return False
    if _SKIP_SSL_ANSWER is not None:
        return _SKIP_SSL_ANSWER

    if silent.is_silent():
        # 静默模式不提问，也**不**改走「按拒绝处理」那条路：用户已经把旗标写出来了，
        # 那就是他的意思。若这里默默拒绝，装失败时会抛一个 SSL 错误，
        # 而用户以为自己已经跳过了。
        tls.grant()
        _SKIP_SSL_ANSWER = True
        return True

    # 红色：这是本工具唯一一处「用户主动要求降低安全性」的地方，提示必须
    # 与普通询问区分开。
    print(f"{RED_BOLD}🌊 You selected --skip-ssl, this will skip SSL certificate "
          f"verification, which may cause security risks. Are you sure? [y/N]{RESET}")
    try:
        confirm = input().strip()
    except (EOFError, KeyboardInterrupt):
        # 非交互（CI / 脚本里 stdin 是 /dev/null）读不到答复：按拒绝处理，
        # 也就是**中止** —— 缺省往安全的方向倒。
        confirm = ""

    if confirm not in ("Y", "y"):
        tls.revoke()
        steplog.fail(
            "not installing with --skip-ssl: the confirmation was declined",
            hint=["nothing was downloaded or installed",
                  "run it again and answer y at the prompt to skip verification",
                  "or drop --skip-ssl if certificate verification works on this network"])

    tls.grant()
    _SKIP_SSL_ANSWER = True
    return True


def handle_download_args(input_string):
    """
    处理下载相关的参数逻辑。
    返回配置字典。

    公共旗标的值全部来自 cli/common.py 的 parse() —— 它已经校验过代理协议、
    限速与三档超时，并在不合法时报错退出。这里只做它不管的两件事：白名单校验
    （哪些旗标这条命令认）与 --skip-ssl 的安全询问。
    """
    found = parse_flags(input_string)
    options = common.parse(input_string)

    # 命令行写了 --skip-ssl 不等于用户可以跳过校验，要问过才算数。
    # 结论直接落到 net/tls.py 的开关上（grant/revoke），这里不再留一份 config
    # 副本 —— 两份状态最容易出现「某一处请求还按旧的判断走」。
    confirm_skip_ssl(found)

    config = {
        "verbose": options.verbose,
        "resume": options.resume,
        "limit_rate": options.limit_rate,
        # None 而不是空串：下游一律用 `if config["proxy"]` 判断
        "proxy": options.proxy or None,
        # Budget 而不是一个秒数：三档超时（连接 / 收数据 / 总额）各有各的默认值，
        # 摊平成一个数就再也分不开了。requests 那一侧读 .request_timeout。
        "max_time": options.timeouts.start(),
        "from_source": "--install-from-source" in found,
    }

    # 子脚本（pip / surfboard 的 shell）读同一个值，不必层层传参
    os.environ[domains.MAX_TIME_ENV] = str(options.timeouts.total)

    return config


# -------------------- 下载核心（含真正断点续传） -------------------

class _RawProgress:
    """`--raw` 的下载进度：纯 ASCII，每 10% 一行，没有颜色也没有光标移动。

    为什么不用 rich：rich 靠 ANSI 光标控制原地重绘，输出重定向到文件时是一串
    控制字符 —— 而这正是 `--raw` 要服务的场合（日志、diff、grep）。这里每行
    自带完整状态，日志里逐行可读。
    """

    STEP = 10
    WIDTH = 20

    def __init__(self, label, total, done=0):
        self._label = label
        self._total = total
        self._written = done
        self._shown = 0
        if not total:
            # 服务器没给 content-length：只能报字节数，不能报百分比
            print(f"{label}: downloading")
            return
        # 续传：已经落在盘上的那部分也算进度，否则从 0% 重新开始读着像重下了
        percent = min(100, self._written * 100 // self._total)
        self._shown = percent // self.STEP * self.STEP
        if self._shown:
            self._emit(self._shown)

    def advance(self, size):
        self._written += size
        if not self._total:
            return
        percent = min(100, self._written * 100 // self._total)
        while self._shown + self.STEP <= percent:
            self._shown += self.STEP
            self._emit(self._shown)

    def finish(self):
        if self._total and self._shown < 100:
            self._shown = 100
            self._emit(100)

    def _emit(self, percent):
        filled = percent * self.WIDTH // 100
        bar = "#" * filled + "." * (self.WIDTH - filled)
        print(f"{self._label}: {bar} {percent:3d}%")


@contextlib.contextmanager
def _progress(display_name, total, done=0):
    """按 `--raw` / rich / 静默 选一种进度呈现，yield 一个 advance(size) 回调。

    三种模式的生命周期各不相同（raw 要自己补满 100%、rich 要进 with），
    放在一个地方才不会出现「某个分支忘了 finish」。
    静默（-s / -sS）下什么都不打：它的每一次刷新都绕过 print 直接写终端。
    """
    if silent.is_raw():
        bar = _RawProgress(display_name, total, done)
        try:
            yield bar.advance
        finally:
            bar.finish()
        return

    if RICH_AVAILABLE and not silent.is_silent():
        console = Console()
        progress_columns = [
            TextColumn("[progress.description]{task.description}"),
            BarColumn(bar_width=None),
            TextColumn("[progress.percentage]{task.percentage:>3.0f}%"),
            DownloadColumn(),
            TextColumn("•"),
            TimeRemainingColumn(),
        ]
        with Progress(*progress_columns, console=console) as progress:
            task_id = progress.add_task(description=f"🌊 {display_name}", total=total or None)
            if done:
                progress.update(task_id, advance=done)
            yield lambda size: progress.update(task_id, advance=size)
        return

    yield lambda size: None


def download_file(url, temp_path, config, input_string, display_name):
    # SSL 策略只有一处：net/tls.py。--skip-ssl 已在 confirm_skip_ssl 里授权过，
    # LINUXWAVE_CACERT 也由它解析，所以这里不再自己传 verify= ——
    # 否则「下载包体走一套策略、取索引走另一套」这种分歧只会越来越难查。
    request_kwargs = {"stream": True, **tls.request_kwargs()}

    # 简单代理检查，避免低级错误
    if config["proxy"]:
        request_kwargs["proxies"] = {
            "http": config["proxy"],
            "https": config["proxy"],
        }

    # 断点续传准备
    existing_size = 0
    mode = "wb"
    if config["resume"] and temp_path.exists():
        existing_size = temp_path.stat().st_size
        if existing_size > 0:
            request_kwargs["headers"] = {"Range": f"bytes={existing_size}-"}
            mode = "ab"

    download_success = False
    while not download_success:
        try:
            # 超时交给 net/timeouts.py 的 Budget：它把「握手 / 收数据 / 总额」
            # 分三档，并保证总额用完时不再等一整个 content。
            # config 可能来自更早的调用方（或测试里的最小字典），缺键时退回当前生效值。
            budget = config.get("max_time")
            response = requests.get(
                url, timeout=budget.request_timeout if budget else domains.timeout_from_env(),
                **request_kwargs)

            if response.status_code == 416:
                download_success = True
                break
            elif response.status_code == 404:
                print(f"{RED_BOLD}🌊 Error: ErrorCode 404 - The URL or file does not exist.{RESET}")
                # 镜像地址可以带凭据（user:token@host），这条会进终端与工单
                print(f"{RED_BOLD}🌊 URL: {domains.redact_url(url)}{RESET}")
                sys.exit(404)
            elif response.status_code not in (200, 206):
                print(f"{RED_BOLD}🌊 Error: ErrorCode {response.status_code}{RESET}")
                # 镜像地址可以带凭据（user:token@host），这条会进终端与工单
                print(f"{RED_BOLD}🌊 URL: {domains.redact_url(url)}{RESET}")
                sys.exit(response.status_code)

            # 如果服务器不支持续传
            if response.status_code == 200 and existing_size > 0:
                silent.say(f"{RED_BOLD}🌊 Server does not support resume, restarting download.{RESET}")
                existing_size = 0
                mode = "wb"

            total_size = int(response.headers.get('content-length', 0))
            if existing_size > 0:
                total_size += existing_size

            limit_bps = config["limit_rate"]

            plain_progress = not (RICH_AVAILABLE and not silent.is_silent()) and not silent.is_raw()
            with _progress(display_name, total_size, existing_size) as advance:
                token_bucket = 0.0
                last_time = time.monotonic()

                with open(temp_path, mode) as f:
                    for chunk in response.iter_content(chunk_size=8192):
                        if not chunk:
                            continue
                        if limit_bps:
                            now = time.monotonic()
                            delta = now - last_time
                            token_bucket += delta * limit_bps
                            last_time = now
                            if token_bucket > 8192:
                                token_bucket = 8192
                            if token_bucket < len(chunk):
                                time.sleep((len(chunk) - token_bucket) / limit_bps)
                                now = time.monotonic()
                                delta = now - last_time
                                token_bucket += delta * limit_bps
                                last_time = now
                            token_bucket -= len(chunk)

                        f.write(chunk)
                        advance(len(chunk))
                        if plain_progress and config["verbose"]:
                            silent.say(".", end="", flush=True)
            if plain_progress and config["verbose"]:
                silent.say(" ")

            download_success = True
            break

        except (ConnectionError, Timeout) as e:
            # 超时或连接失败：每次都询问是否重试，不再直接放弃
            print(f"{RED_BOLD}🌊 Download failed: {e}{RESET}")
            silent.say(f"{RED_BOLD}🌊 Do you want to retry? [y/N]: {RESET}")
            try:
                # 静默（-s / -sS）下没人能回答，silent.ask 返回 None：按「不重试」
                # 处理，而不是卡在 input() 上等一个永远不会来的答复。
                answer = silent.ask()
                if answer is None:
                    raise EOFError
                retry = answer.strip().lower()
            except KeyboardInterrupt:
                # Ctrl-C 是「打断」，不是「不想重试」——交给顶层统一报成 interrupted，
                # 否则这里会打印 "Failed to download package"，把用户打断说成下载失败。
                print("", file=sys.stderr)
                raise
            except EOFError:
                retry = ""

            if retry == 'y':
                continue

            print(f"{RED_BOLD}🌊 Error: Failed to download package{RESET}")
            sys.exit(1)

        except HTTPError as e:
            status_code = e.response.status_code if e.response is not None else 1
            print(f"{RED_BOLD}🌊 Error: ErrorCode {status_code}{RESET}")
            sys.exit(status_code)

        except PermissionError as e:
            # 写 .partial 失败：共用安装树下这是最常见的一种失败
            print_write_permission_advice(str(e))
            sys.exit(1)

        except Exception as e:
            print(f"{RED_BOLD}🌊 Error: {e}{RESET}")
            sys.exit(1)

    return temp_path


# -------------------- 包名清单与 404 诊断 --------------------

def fetch_package_names(arch, timeout=None):
    """索引里的全部包名。列不出来（网络 / 镜像没有清单）时返回 None。

    返回值区分的是**两类完全不同的问题**，报错要据此分开说：
      None   → 名字清单都拿不到，是网络或镜像配置的事，别再猜包名
      []     → 清单是空的，镜像还没生成 versions
      [...]  → 有清单，于是能判断「这个名字在不在里面」
    """
    names_url = domains.index_list_url(arch)
    try:
        response = requests.get(names_url, timeout=timeout or domains.timeout_from_env(),
                                headers=github_api_headers(names_url),
                                **tls.request_kwargs())
    except Exception as error:
        steplog.detail(f"package list failed: {error}")
        return None
    if response.status_code != 200:
        steplog.detail(f"package list HTTP {response.status_code}")
        return None
    return [name for name in domains.listing_names(response.text, dirs_only=True) if name]


def _explain_missing_version_list(package_name, arch, api_url):
    """`<包名>/versions` 404 时分清三件事，报错只报其中一件。

    三种原因的话术完全不同，混成一句「读不到版本清单」会让用户去查镜像 ——
    而绝大多数情况只是包名打错了：

      名字清单拿不到      → 网络 / LINUXWAVE_API_DOMAIN / 镜像没生成清单
      名字不在清单里      → 包名错（最常见）；给出近似名与几个同类示例
      名字在、清单却 404  → 镜像缺这一份，数据问题
    """
    names = fetch_package_names(arch)

    if names is None:
        steplog.fail(
            f"cannot reach the package list, so {package_name} cannot be checked",
            request=api_url,
            hint=["LINUXWAVE_API_DOMAIN must point at <mirror>/LinuxWave/infosource/<ref>",
                  "the mirror lays files out under a ref segment — main or HEAD, "
                  "whichever the mirror synced (see `wave mirror`)",
                  "if the address is right, the mirror may not have generated its "
                  "versions lists yet (see docs/MIRROR-SETUP.md)",
                  "check the network and any --proxy setting, then retry"])

    if not names:
        steplog.fail(
            f"the package list is empty, so {package_name} cannot be checked",
            request=api_url,
            hint=["the mirror has not generated its versions lists yet "
                  "(see docs/MIRROR-SETUP.md)",
                  "ask the administrator to re-run scripts/build_versions_index.py"])

    folded = {name.casefold() for name in names}
    if package_name.casefold() not in folded:
        from suggest import closest_name, name_examples

        close = closest_name(package_name, names)
        examples, label = name_examples(package_name, names)
        hint = []
        if close:
            # 建议先 `wave info`：它只读、不装任何东西，用户想核对版本也方便。
            # 直接给 `wave upgrade` 是错的 —— 这里同时服务 install 与 upgrade 两条路。
            hint.append(f"did you mean `{close}`?  try: wave info {close}")
        # 这一句是整段提示的目的：把「名字错」与「网络 / 镜像挂了」分开。
        # 用户看到「HTTP 404」时的第一反应是去查镜像，而那通常不是原因。
        hint.append(f"the name was checked against all {len(names)} package name(s) "
                    f"in the index, so this is not a network or mirror problem")
        if examples:
            hint.append(f"{label}: " + ", ".join(examples))
        hint.append("list every match for part of a name: wave search <part of a name>")
        steplog.fail(f"no package named '{package_name}' in the index", hint=hint)

    # 名字确实存在，只是镜像没提供它的版本清单
    steplog.fail(
        f"the index has no version list for {package_name}",
        request=api_url,
        response="HTTP 404",
        hint=["the package name is right; the mirror is missing this file",
              "ask the administrator to re-run scripts/build_versions_index.py on the mirror",
              "if every package is like this, the mirror has no versions lists yet "
              "(see docs/MIRROR-SETUP.md)"])


# -------------------- 获取最高版本（GitHub API） --------------------

def fetch_max_version(package_name, arch):
    # 数据在 infosource 分支，API 必须显式带 ref，
    # 否则默认分支（main）下没有 pkginfo_{arch} 目录，会直接 404
    api_url = domains.index_list_url(arch, package_name)
    try:
        response = requests.get(api_url, timeout=domains.timeout_from_env(),
                                headers=github_api_headers(api_url),
                                **tls.request_kwargs())
        if response.status_code != 200:
            # 404 有三种完全不同的原因，混成一句「读不到」会把人引向镜像和网络
            if response.status_code == 404:
                _explain_missing_version_list(package_name, arch, api_url)
            print(f"{RED_BOLD}🌊 Error: Cannot fetch package list.{RESET}")
            print(f"{RED_BOLD}🌊 URL: {api_url}{RESET}")
            sys.exit(1)

        # 两种来源并存：GitHub API 返回 JSON 数组，镜像返回一行一条的纯文本。
        # listing_names 统一成名字列表，下面的解析不必关心是哪一种。
        names = domains.listing_names(response.text)
        versions = []
        for fname in names:
            if fname.endswith("@common"):
                continue
            if "@" in fname:
                versions.append(fname.split("@")[1])

        from versioncompare import get_max_version
        return get_max_version(versions)
    except Exception as e:
        print(f"{RED_BOLD}🌊 Error: Failed to fetch version list: {e}{RESET}")
        sys.exit(1)


# -------------------- 写入权限提示 --------------------

def group_name_for_gid(gid):
    """gid 对应的组名；gid 0 返回 None。

    树属 root:root（/opt、/usr/local 这类系统级安装就是）时，提示「加入 root 组」
    是害人的建议，所以那种情况只给 sudo 全路径，不提组。
    """
    if gid == 0:
        return None
    try:
        return grp.getgrgid(gid).gr_name
    except KeyError:
        return None


def tree_group_name():
    """安装树所属的组；取不到（树没了等）返回 None。"""
    try:
        return group_name_for_gid(os.stat(BASE_DIR).st_gid)
    except OSError:
        return None


def current_user_name():
    """提示里要给出可直接复制的 usermod 命令，所以得知道自己是谁。"""
    try:
        return pwd.getpwuid(os.getuid()).pw_name
    except KeyError:
        return os.environ.get("USER", "<your-user>")


def print_write_permission_advice(path=""):
    """共用/系统级安装树下普通用户写不进去。

    实录里这里原本只抛一个原始 `[Errno 13] Permission denied: ...`，用户看不出
    该怎么办；而「root 也能装包」这条提示在 `sudo wave` 下必然失败（sudo 用自己
    那套 PATH，找不到不在标准位置的 wave）。共享安装改成组共享写之后，最常见的
    原因变成了「刚被加进组、但还没重新登录」—— 这句必须说出来，否则用户会以为
    是装坏了。
    """
    group = tree_group_name()
    print(f"{RED_BOLD}🌊 Error: No write permission for the LinuxWave install tree.{RESET}")
    if path:
        print(f"🌊 Path: {path}")
    print(f"🌊 Packages are unpacked into {BASE_DIR}, which belongs to another account.")
    print(f"{YELLOW}🌊 Run it as root, giving the full path ('sudo' has its own PATH):{RESET}")
    print(f"     sudo {BASE_DIR}/lib/wave install <package>")
    if group:
        print(f"{YELLOW}🌊 Or join the '{group}' group that owns the tree, then log out and back in:{RESET}")
        print(f"     sudo usermod -aG {group} {current_user_name()}")
        print(f"🌊 Group membership only takes effect on a new login - if you were added to")
        print(f"🌊 '{group}' moments ago (a shared install does that), that is what is still")
        print(f"🌊 missing here. Afterwards plain 'wave install <package>' works, no sudo,")
        print(f"🌊 no full path.")
        print(f"🌊 If it is still unwritable after a re-login, the user manager started at")
        print(f"🌊 your first login is holding the old credentials: run")
        print(f"     systemctl --user exit")
        print(f"🌊 then log in again (a reboot does the same).")
    else:
        print(f"🌊 Only root can write there, so the 'sudo' form above is the way in.")


def ensure_install_writable():
    """真正开始下载之前就检查能否写入，避免下载到一半才失败。"""
    for label, path in (("the download directory", DOWNLOAD_TMP),
                        ("the package directory", BASE_DIR / "bin")):
        probe = path
        while not probe.exists() and probe != probe.parent:
            probe = probe.parent
        if os.access(probe, os.W_OK):
            continue
        print_write_permission_advice(path)
        sys.exit(1)


# -------------------- 核心安装流程 --------------------

# -------------------- 安装步骤（-v 与报错里的「第几步」） --------------------
#
# 顺序即实际执行顺序：它只用来给 -v 打「4/11」这样的计数器，以及让出错时能说清
# 「卡在哪一步」—— 光有一句 reason，用户不知道该往前查还是往后查。
INSTALL_STEPS = [
    "parse command line",
    "resolve package name",
    "detect architecture",
    "fetch version list",
    "read package metadata",
    "read version record",
    "choose payload",
    "download",
    "verify and install",
    "install dependencies",
    "relocate and link",
]


def confirm_min_client_version(record_text, pkg_name, pkg_version, force=False):
    """版本记录声明了 min_client_version 且本机 LinuxWave 更旧时中止安装。

    与 min_os 不是一回事：min_os 是「构建时声明的最低系统，可能偏保守」，问一句由
    用户决定；min_client_version 说的是「这个包要求客户端具备某种安装形态」——
    旧客户端不是「装得勉强」，而是**一定装坏**。

    实际例子：`git` 声明 install: "tree"（整树包）。不认识这个字段的客户端会按单文件
    装，只取一个 `bin/git`：`git --version` 还能跑，但 `--exec-path` / `runtime/` 全缺，
    依赖系统装的那个 git 提供 helper。所以默认硬拦，只有 -F/--force 越过。

    字段缺失时静默跳过；本机版本读不到（VERSION.json 不存在）时也跳过 —— 猜不出就
    别拦人。
    """
    match = re.search(r'min_client_version:\s*"([^"]*)"', record_text)
    if not match:
        return True

    required_text = match.group(1).strip()
    if not required_text:
        return True

    running_text = get_version()
    if running_text in ("", "unknown"):
        steplog.detail("min_client_version declared but the client version is unreadable, ignored")
        return True

    from versioncompare import version as parse_version
    try:
        required = parse_version(required_text)
        running = parse_version(running_text)
    except Exception:
        steplog.detail(f"min_client_version {required_text!r} is not a version, ignored")
        return True

    if running >= required:
        return True

    steplog.detail(f"min_client_version {required_text} > running {running_text}")

    if force:
        if not silent.is_silent():
            print(f"{YELLOW}🌊 Warning: {pkg_name}@{pkg_version} needs LinuxWave "
                  f"{required_text} or later, this is {running_text}; installing anyway "
                  f"because of --force.{RESET}")
        return True

    return False


def handle_install(input_string):
    """`wave install` 的入口：一个包走原路径，多个包（逗号分隔）逐个装。

    多个包时逐个安装，**一个失败不影响其余**：装完统一汇总，有失败就以非 0 退出。
    这样 `wave install jq, yq, fx` 里某一个名字打错，不会让另外两个白等一场 ——
    而「能一次给好几个」也正是 apt/brew 用户的直觉。
    """
    specs = package_specs(input_string)
    if len(specs) <= 1:
        return _install_single(input_string)

    ver_flag = flag_value(input_string, "--ver")
    if ver_flag is not None:
        steplog.fail(
            "--ver cannot be used when installing several packages",
            extra=f"packages: {', '.join(specs)}; --ver {ver_flag}",
            hint=["put the version on the package itself, e.g. "
                  "wave install jq@1.8.2, yq@2.47.1",
                  "or install them one by one if they need the same --ver"])

    flags = _flag_words(input_string)
    total = len(specs)
    installed = []
    failed = []

    for index, spec in enumerate(specs, 1):
        silent.say(f"🌊 [{index}/{total}] {spec}")
        try:
            _install_single(f"wave install {spec} {flags}".strip())
            installed.append(spec)
        except SystemExit as exit_error:
            code = exit_error.code
            if code in (None, 0):
                installed.append(spec)
            else:
                failed.append(spec)

    silent.say(f"🌊 Installed {len(installed)} of {total} package(s)")
    for spec in installed:
        silent.say(f"🌊   ok    {spec}")
    for spec in failed:
        silent.say(f"🌊   failed {spec}")

    if failed:
        print(f"{RED_BOLD}🌊 Error: {len(failed)} of {total} package(s) failed "
              f"to install: {', '.join(failed)}.{RESET}")
        print(f"{YELLOW}🌊 The ones listed as ok above are installed and usable.{RESET}")
        print(f"{YELLOW}🌊 Fix the problem and run the failed ones again, e.g. "
              f"wave install {failed[0]}{RESET}")
        sys.exit(1)


def _install_single(input_string):
    # 多包时每条都重新 plan 一次：上一个包的步骤条不能留给这一个
    steplog.reset()
    steplog.plan(INSTALL_STEPS)

    # 装包会写 bin/、links/、.depped_* 与 downloads/tmp，整段都要独占安装树
    # （见 lib/lock.py）。可重入，所以 upgrade --all / 多包装到同一个包时不会自锁。
    from lock import tree_lock
    with tree_lock("install"):
        # 拿到锁才敢打扫：downloads/tmp 里可能有另一个 wave 正在写的 .partial。
        # 放在下载之前，顺手腾出的空间正好给这次用。
        from downloads import sweep_stale_partials
        sweep_stale_partials()
        return _install_single_locked(input_string)


def _install_single_locked(input_string):

    # 参数解析
    config = handle_download_args(input_string)
    # 先解析旗标、打开追踪，再报第一步 —— 否则 -v 自己的这一步会被漏掉
    steplog.set_verbose(config["verbose"])
    steplog.begin("parse command line")

    # 1. 解析包名
    steplog.begin("resolve package name")
    raw_pkg = first_package_token(input_string)
    if not raw_pkg:
        print(f"{RED_BOLD}🌊 Error: Invalid package name{RESET}")
        sys.exit(1)

    if "@" in raw_pkg:
        ParsePkgName = raw_pkg.split("@")[0]
    else:
        ParsePkgName = raw_pkg

    # 包名会同时进入 URL 与文件路径，先过白名单（剔除 / \ % @ 空白等）
    ParsePkgName = require_safe_token(ParsePkgName, "package name")

    # 2. 获取架构
    steplog.begin("detect architecture")
    machine = platform.machine().lower()
    if machine in ["arm64", "aarch64"]:
        ARCH = "arm64"
    elif machine in ["x86_64", "amd64"]:
        ARCH = "amd64"
    else:
        print(f"{RED_BOLD}🌊 Error: Unknown Arch!{RESET}")
        sys.exit(1)

    # 3. 解析版本号（只看包名 token，避免 --proxy 里的 user:pass@host 被误认）
    #    放在联网取版本之前先确认能写入：写不进去时没必要先跑一遍网络请求
    ensure_install_writable()

    ver_flag = flag_value(input_string, "--ver")
    ParsePkgVersion = None
    if "@" in raw_pkg:
        if ver_flag is not None:
            print(f"{RED_BOLD}🌊 Error: Repeated Version Number{RESET}")
            sys.exit(1)
        ParsePkgVersion = raw_pkg.split("@", 1)[1].strip()
    elif ver_flag is not None:
        if not ver_flag:
            print(f"{RED_BOLD}🌊 Error: Missing version number after --ver{RESET}")
            sys.exit(1)
        ParsePkgVersion = ver_flag
    else:
        silent.say("🌊 Fetching version info...")
        steplog.begin("fetch version list")
        ParsePkgVersion = fetch_max_version(ParsePkgName, ARCH)
        silent.say("🌊 Version info fetched successfully.")

    # 版本号同样会进 URL 与目录名：`%`、`/`、`..` 这类一律拒绝
    ParsePkgVersion = require_safe_token(ParsePkgVersion, "package version")

    # 4. 获取 bin_name（从 @common 文件）
    steplog.begin("read package metadata")
    common_url = f"{domains.api_domain()}/pkg/pkginfo_{ARCH}/{ParsePkgName}/_{ParsePkgName}@common"
    try:
        common_resp = requests.get(common_url, timeout=domains.timeout_from_env(),
                                   **tls.request_kwargs())
        if common_resp.status_code != 200:
            print(f"{RED_BOLD}🌊 Error: Cannot fetch @common file.{RESET}")
            sys.exit(1)
    except Exception as e:
        print(f"{RED_BOLD}🌊 Error: {e}{RESET}")
        sys.exit(1)

    common_fields = parse_common_fields(common_resp.text)
    bin_name = get_field(common_fields, "bin_name")
    if not bin_name:
        print(f"{RED_BOLD}🌊 Missing \"bin_name\" field, Please contact the administrator.{RESET}")
        sys.exit(1)

    # bin_name 来自远端 @common，却要当目录名与文件名用，必须过白名单
    bin_name = require_safe_token(bin_name, "bin_name")

    # 5. 获取 URL 和 SHA256（deps 也写在该版本文件里）
    steplog.begin("read version record")
    pkg_version_url = f"{domains.api_domain()}/pkg/pkginfo_{ARCH}/{ParsePkgName}/_{ParsePkgName}@{ParsePkgVersion}"
    try:
        resp = requests.get(pkg_version_url, timeout=domains.timeout_from_env(),
                            **tls.request_kwargs())
        if resp.status_code != 200:
            if config["verbose"]:
                silent.say(resp.text)
            elif resp.status_code == 404:
                print(f"{RED_BOLD}🌊 Error: Can't find parse package version.\n🌊 If you certain this version is existent, Please contact the administrator.{RESET}")
                sys.exit(1)
            else:
                print(f"{RED_BOLD}🌊 Error: GitHub returned HTTP {resp.status_code} for the package data.{RESET}")
                print(f"{RED_BOLD}🌊   {pkg_version_url}{RESET}")
                print(f"{RED_BOLD}🌊 This is usually a network hiccup. Check your network or proxy, then run the command again.{RESET}")
                sys.exit(1)
    except Exception as e:
        print(f"{RED_BOLD}🌊 Error: {e}{RESET}")
        sys.exit(1)

    url_match = re.search(r'url:\s*"([^"]+)"', resp.text)
    sha_match = re.search(r'sha256:\s*"([^"]+)"', resp.text)
    # 4.0 的 payload 字段：上游文件名。缺它时若走镜像会由 resolve_payload 报数据缺陷。
    file_match = re.search(r'file:\s*"([^"]+)"', resp.text)

    if url_match:
        ParsePkgURL = url_match.group(1)
    else:
        print(f"{RED_BOLD}🌊 Error: URL field not found.{RESET}")
        sys.exit(1)

    # 没有校验值就必须拒绝安装：索引记录是信任的起点，缺了 sha256 就无法确认
    # 下载到的内容与索引声明的一致。HTTPS 只保护传输，不保护产物。
    if not sha_match:
        print(f"{RED_BOLD}🌊 Error: No SHA256 checksum for {ParsePkgName}@{ParsePkgVersion}.{RESET}")
        print(f"{RED_BOLD}🌊 Without it the download cannot be verified; refusing to install.{RESET}")
        print(f"{RED_BOLD}🌊 This is a data defect; please report it to the administrator.{RESET}")
        sys.exit(1)

    ParsePkgSHA256 = sha_match.group(1)
    ParsePkgFile = file_match.group(1) if file_match else ""

    if not re.fullmatch(r"[0-9a-f]{64}", ParsePkgSHA256):
        print(f"{RED_BOLD}🌊 Error: Malformed SHA256 checksum for {ParsePkgName}@{ParsePkgVersion}.{RESET}")
        print(f"{RED_BOLD}🌊 Expected 64 lowercase hexadecimal characters; refusing to install.{RESET}")
        sys.exit(1)

    # 4.1 决定从哪儿取字节：配了镜像就走我们自己的存储（4.0 的 payload 命名），
    # 没配或用户要求 --install-from-source 时仍按索引的 url 取（3.1.x 的既有行为）。
    steplog.begin("choose payload")
    payload_filename_hint = None
    if domains.use_mirror_for("bottle", config["from_source"]):
        payload = domains.resolve_payload("bottle", ParsePkgName, ParsePkgVersion, ARCH,
                                          ParsePkgFile, ParsePkgURL, False)
        ParsePkgURL = payload["url"]
        # 走镜像时文件名由 resolve_payload 拼好（URL 里那段是 quote 过的，不能直接用）
        payload_filename_hint = payload["filename"]

    # 5.1 解析 deps 字段（写在版本文件里，可能多行），缺失视为无依赖
    record_fields = parse_common_fields(resp.text)
    dep_refs = get_deps(record_fields)

    # 5.2 安装形态：缺省 binary（只取一个可执行文件），tree 表示整树软件包。
    #     两种形态都落在 bin/{名}@{版本}/，区别只在于整棵树是否保留。
    install_fields = record_fields.get("install") or ["binary"]
    install_mode = str(install_fields[0]).strip() or "binary"
    if install_mode not in ("binary", "tree"):
        steplog.fail(
            f"the version record for {ParsePkgName}@{ParsePkgVersion} has an unknown "
            f"install field",
            extra=f"got {install_mode!r}",
            hint=['expected "binary" (the default) or "tree"; this is an index data '
                  'defect, please report it to the administrator'])

    # 5.3 客户端门槛：tree 包在旧客户端上一定装坏（旧客户端不认识 install 字段，
    #     会按单文件装，只取一个 bin/{name} —— --exec-path / runtime 全缺）。
    #     与 min_os 不是一回事：后者是「可能不兼容」，这是「一定装坏」。
    force = any(flag in ("-F", "--force")
                for flag in flags_module.tokens(input_string.split(" ")))
    if not confirm_min_client_version(resp.text, ParsePkgName, ParsePkgVersion, force):
        steplog.fail(
            f"not installing {ParsePkgName}@{ParsePkgVersion}: it needs a newer LinuxWave",
            request=pkg_version_url,
            hint=["nothing was downloaded or installed",
                  "run `wave selfupdate` to get the current LinuxWave, then try again",
                  "add --force to install it anyway (the result will most likely be broken)"])

    # 6. 地址策略已经由步骤 4.1 定完了：走镜像时地址是 domains 拼出来的，
    # 走 --install-from-source 时 resolve_payload 已经拒绝过非 https 的 url。
    # 这里不再重复一遍 http/https 判断 —— 重复的那份只会挡住镜像与本机演练
    # 用的回环地址，而它挡不住任何 resolve_payload 没挡的东西。

    # 7. 下载
    steplog.begin("download")
    # 文件名会进下载路径，也会进 pkginstaller.sh 的参数 —— 过一遍文件名白名单。
    # 走镜像时用 resolve_payload 给出的那个（URL 末段被 quote 过，可能是 `%40`）；
    # 走 --install-from-source 时只能从 URL 末段取。
    original_filename = require_safe_filename(
        payload_filename_hint or ParsePkgURL.split("/")[-1], "file name")
    temp_path = DOWNLOAD_TMP / f"{original_filename}.partial"
    assert_inside(temp_path, DOWNLOAD_TMP, "download path")

    try:
        DOWNLOAD_TMP.mkdir(parents=True, exist_ok=True)
        download_file(ParsePkgURL, temp_path, config, input_string, bin_name)

        # 8. 删掉 .partial 后缀
        final_download_path = DOWNLOAD_TMP / original_filename
        assert_inside(final_download_path, DOWNLOAD_TMP, "download path")
        temp_path.rename(final_download_path)
    except PermissionError as e:
        # 预检查之后再出现，通常是权限被人改过或目录被换掉
        print_write_permission_advice(str(e))
        sys.exit(1)

    # 9. 拼接长字符串并传给 pkginstaller.sh（同时带上依赖列表）
    steplog.begin("verify and install")
    target_dir = BASE_DIR / "bin" / f"{bin_name}@{ParsePkgVersion}"
    assert_inside(target_dir, BASE_DIR / "bin", "install target")
    pkg_info_string = "\n".join([
        ParsePkgName,
        ParsePkgVersion,
        ParsePkgSHA256 or "",
        str(target_dir),
        str(BASE_DIR),
        bin_name,
        "",
        original_filename,
        install_mode,
    ])
    deps_string = "\n".join(dep_refs)

    try:
        script_path = os.path.join(os.path.dirname(__file__), 'pkginstaller.sh')
        result = subprocess.run(
            ['bash', script_path, pkg_info_string, deps_string],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
        )
        silent.show(result)
        if result.returncode != 0:
            sys.exit(result.returncode)
    except Exception as e:
        print(f"{RED_BOLD}🌊 Error: Failed to invoke shell script: {e}{RESET}")
        sys.exit(1)

    # 10. 安装依赖（递归处理依赖的依赖，进度条与软件包一致）
    steplog.begin("install dependencies")
    if dep_refs:
        install_dependencies(dep_refs, ARCH, config, input_string,
                             ("pkg", bin_name, ParsePkgVersion))

    # 11. 路径替换：依赖与软件包都就位后统一做一遍
    steplog.begin("relocate and link")
    #     （必须放最后：先装的依赖可能引用后装的依赖，提前替换会解析不到）
    transfer_installed_artifacts(target_dir)

    # 12. 把不带版本号的软链接指到刚装好的版本（--no-link / 旧名 --unlink 可跳过）
    if not any(flag in flags_module.NO_LINK for flag in flags_module.tokens(input_string.split(" "))):
        try:
            from linker import link_package
            if link_package(bin_name, ParsePkgVersion):
                silent.say(f"🌊 Linked {bin_name} -> {bin_name}@{ParsePkgVersion}")
        except Exception as error:
            print(f"{YELLOW}🌊 Warning: could not create the unversioned link ({error}).{RESET}")


if __name__ == "__main__":
    try:
        input_string = " ".join(sys.argv[1:])
        handle_install(input_string)
    except KeyboardInterrupt:
        silent.say("🌊 Operation cancelled by user.")
        silent.say("🌊 You can use -C to resume the download next time.")
        sys.exit(130)
