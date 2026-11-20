#!/usr/bin/env python3

# selfupdate.py

import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request


# -------------------- 颜色定义 --------------------

RED_BOLD = '\033[1;31m'
GREEN = '\033[32m'
YELLOW = '\033[33m'
RESET = '\033[0m'


# -------------------- 常量 --------------------

import common
import domains
import silent
import tls
from configpaths import VERSION_FILE_NAME, config_dir_candidates, find_config_dir, load_base_dir

# -------------------- 同意记录 --------------------
#
# 安装器把「用户同意的是哪一版协议」写进配置目录的 AGREEMENT.json，值就是这里的
# AGREEMENT_ID。CI 装完再跑 `wave selfupdate` 时据此免去再问一次 —— 否则无人值守
# 的流水线会卡在一个没人看的提示符上。
#
# 改协议内容时**必须**同时改 AGREEMENT_ID（用协议生效日期），否则已经同意旧协议
# 的用户会被当成同意过新的。
AGREEMENT_ID = "2026-11-19"
AGREEMENT_FILE_NAME = "AGREEMENT.json"

# 协议全文就在官网底部，安装器打印的也是这一句。
AGREEMENT_URL = "https://linuxwave.org"

# 协议是随哪个版本引入的。只有在「已装版本 ≤ 这个版本」时才需要问一次：
# 那批用户当初同意的是旧协议，而比这个版本新的安装一定来自一个问过新协议的安装器。
AGREEMENT_INTRODUCED_IN = "4.0.0"


# 4.0 起的两级结构：latest.toml 说「装哪个版本」，该版本的 update_commands.sh 说「怎么装」。
# 前者每次发版都变，后者按版本冻结 —— 装了旧版本的人继续用他们那份说明，而旧版本仍在运行。
#
# 本层只回答「有没有新版」；下载与落盘由 lib/selfupdate.sh 取回那份脚本再执行。
LATEST_TOML_URL = domains.selfupdate_latest_url()
FETCH_TIMEOUT = domains.DEFAULT_TIMEOUT
UPDATE_TIMEOUT = 1800


# -------------------- 版本数据 --------------------

def fetch_url_text(url):
    """取一段文本：优先标准库，本地 Python 缺根证书时改走 curl。取不到返回 None。"""
    try:
        with urllib.request.urlopen(url, timeout=FETCH_TIMEOUT,
                                    **tls.urlopen_kwargs()) as response:
            return response.read().decode()
    except (urllib.error.URLError, UnicodeDecodeError, OSError):
        pass

    result = subprocess.run(['curl', '-fsSL', '--max-time', str(FETCH_TIMEOUT)]
                            + tls.curl_flags() + [url],
                            capture_output=True, text=True)
    if result.returncode != 0:
        return None
    return result.stdout


def parse_toml(text):
    """只认本项目的用法：`key = "value"`，`#` 开头是注释，其余忽略。

    4.0 的 latest.toml 就长这样（上游用真正的 TOML，但字段只有四个字符串），
    为此引一个 TOML 解析器不值得 —— 但解析必须严格：值不带引号就当不存在，
    免得半行残缺被当成版本号。
    """
    fields = {}
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, separator, value = line.partition("=")
        key = key.strip()
        value = value.strip()
        if not separator or not key:
            continue
        if len(value) >= 2 and value.startswith('"') and value.endswith('"'):
            fields[key] = value[1:-1]
    return fields


def resolve_release():
    """返回版本数据；取不到或没有 version 字段时返回 None。

    只有 4.0 的 linuxwavedata/latest.toml 一种布局 —— 3.x 的
    versiondata/latest_version 与 files_info 一起退休了，回落会让「读到了什么」
    变成两说。
    """
    text = fetch_url_text(LATEST_TOML_URL)
    if not text:
        return None
    data = parse_toml(text)
    return data if data.get("version") else None


def run_script(environment, overall_timeout):
    """执行 lib/selfupdate.sh。它负责取回 update_commands.sh 并跑它。

    **必须从临时副本执行**：更新过程会覆盖 lib/selfupdate.sh 自己，而 bash 是
    边读边执行的，被覆盖的正文会让运行中的脚本读到半截内容。复制一份再跑，
    覆盖就发生在「已经读完的副本」之外，不影响本次执行。
    """
    source = os.path.join(os.path.dirname(os.path.abspath(__file__)), "selfupdate.sh")

    print("🌊 Preparing the update script for this version...")

    try:
        with open(source, encoding="utf-8") as stream:
            text = stream.read()
    except OSError:
        print(f"{RED_BOLD}🌊 Error: Cannot read the update script.{RESET}")
        print(f"{RED_BOLD}🌊 {source}{RESET}")
        sys.exit(1)

    handle, path = tempfile.mkstemp(prefix="linuxwave-selfupdate-", suffix=".sh")
    try:
        with os.fdopen(handle, "w") as stream:
            stream.write(text)
        return subprocess.run(['/bin/bash', path], env=environment, timeout=overall_timeout)
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


def version_key(value):
    # 只比较数字段（2.3 -> [2, 3, 0, 0]），避免依赖 packaging
    parts = [int(part) for part in re.findall(r'\d+', str(value))]
    while len(parts) < 4:
        parts.append(0)
    return parts


def version_file():
    # 配置目录可能在上一次升级里被迁移（见 update_commands.sh 里的迁移步骤），
    # 所以每次都重新解析一遍，不要用模块级常量。
    config_dir = find_config_dir()
    if config_dir is not None:
        return config_dir / VERSION_FILE_NAME
    return config_dir_candidates()[0] / VERSION_FILE_NAME


def installed_version():
    path = version_file()
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text()).get("version")
    except (ValueError, OSError):
        return None


# -------------------- 主流程 --------------------

def _apply_timeouts(input_string):
    """三档超时：本层留一份预算，同时把原始文本交给 selfupdate.sh。

    `wave.py` 已经把公共旗标解析过一次，但 selfupdate 的 handler 拿到的是原始
    命令行（自更新要能把参数原样交给脚本），所以这里用同一个入口再解析一次 ——
    common.parse() 是幂等的，报错文案与退出码也就只有一套。
    """
    global FETCH_TIMEOUT
    options = common.parse(input_string or "")
    common.export_timeouts(options)

    # 本层取版本数据用同一个预算；脚本那边自己解析文本，不读这个数
    FETCH_TIMEOUT = options.timeouts.total


def _wants_dry_run(input_string):
    """`--dry-run`：本层自己把计划打完就退出，不执行 selfupdate.sh。

    计划必须由**这一层**打：真正的下载发生在 update_commands.sh 里，而它是由
    selfupdate.sh 执行的 —— 让脚本自己去判断「试运行」就等于让下载路径多一种
    分支，迟早有一条会漏。
    """
    return bool(re.search(r"(^|\s)--dry-run(\s|$)", input_string or ""))


def _apply_python_source(input_string):
    """`--install-python-from-source`：自带解释器直接从上游取，不试我们托管的副本。

    客户端自己不下解释器（那一步在 selfupdate.sh / install.sh 里），所以这里只把
    旗标翻译成环境变量，由脚本去读。
    """
    if "--install-python-from-source" in input_string.split():
        os.environ["LINUXWAVE_PYTHON_FROM_SOURCE"] = "1"


# -------------------- 同意记录 --------------------
#
# 安装器把「用户同意的是哪一版协议」写进配置目录的 AGREEMENT.json（值就是
# AGREEMENT_ID）。自更新读它决定要不要再问一次。
#
# 单独一个文件、不塞进 VERSION.json：那份由 update_commands.sh 与 install.sh 写，
# 把协议状态放进去会被它们覆盖掉。


def agreement_file():
    config_dir = find_config_dir()
    if config_dir is not None:
        return config_dir / AGREEMENT_FILE_NAME
    return config_dir_candidates()[0] / AGREEMENT_FILE_NAME


def recorded_agreement():
    path = agreement_file()
    if not path.exists():
        return ""
    try:
        return json.loads(path.read_text()).get("agreement", "") or ""
    except (ValueError, OSError, AttributeError):
        return ""


def agreement_needs_consent(current):
    """升级到这个版本之前，要不要问一次协议。

    只管「已经装着的版本」：全新安装由 install.sh 自己问。
    """
    if recorded_agreement() == AGREEMENT_ID:
        return False
    if not current:
        return False
    return version_key(current) <= version_key(AGREEMENT_INTRODUCED_IN)


def record_agreement():
    path = agreement_file()
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({"agreement": AGREEMENT_ID}, indent=2) + "\n")
    except OSError as error:
        # 记不下来不该让更新失败 —— 代价只是下次再问一次，比「更新到一半退出」轻。
        print(f"{YELLOW}🌊 Warning: cannot record the agreement acceptance ({error}).{RESET}")


def _wants_silence():
    # -s / --silent 会把 fd 1、2 指到 /dev/null，于是任何提示都看不见。
    # 延迟 import：selfupdate.py 也有 `python3 lib/selfupdate.py` 这条直接路径，
    # 那时 cli/ 可能不在 sys.path 上。
    try:
        import silent
    except ImportError:
        return False
    try:
        return bool(silent.is_silent())
    except AttributeError:
        return False


def _say_on_terminal(lines):
    # 静默模式下 stderr 也进了 /dev/null，只能直接写终端设备。
    # 没有终端（CI、管道）时什么都不写 —— 退出码是唯一的信号，与 -s 的约定一致。
    try:
        with open("/dev/tty", "w", encoding="utf-8") as tty:
            for line in lines:
                tty.write(line + "\n")
    except OSError:
        pass


def _refuse_agreement(current, quiet):
    if quiet:
        # 静默模式不能替用户同意，也不该挂在 input() 上等 —— 提示写终端，
        # 然后按「没有同意」退出。
        _say_on_terminal([
            f"🌊 Error: the user agreement was updated ({AGREEMENT_ID}) and cannot be "
            f"accepted in silent mode.",
            "🌊 Next      run `wave selfupdate` without -s to read and accept it",
            f"🌊           {AGREEMENT_URL}",
            f"🌊 Your current installation ({current}) has not been changed.",
        ])
    else:
        print(f"{RED_BOLD}🌊 Error: the updated user agreement was not accepted.{RESET}")
        print(f"{RED_BOLD}🌊 Next      your installation is unchanged; you are still on {current}.{RESET}")
        print(f"{RED_BOLD}🌊           read it when you like, then run selfupdate again:{RESET}")
        print(f"{RED_BOLD}🌊           {AGREEMENT_URL}{RESET}")
    sys.exit(1)


def _is_cross_major(current, latest):
    """这次更新是不是跨大版本。

    只用来决定**要不要问协议**，不参与拒绝：跨大版本的更新本来就装不了（要重装），
    在它上面问「同不同意新协议」纯属噪音 —— 用户答应了也还是得去官网重装。
    真正的拒绝在 lib/selfupdate.sh 里（那里才是唯一判定处，因为 selfupdate.sh 才是
    「从目标分支拉下来执行」的那一份，每个大版本自带自己的规则）。
    """
    def major_of(value):
        match = re.search(r"[0-9]+", str(value or ""))
        return match.group(0) if match else ""

    left, right = major_of(current), major_of(latest)
    return bool(left) and bool(right) and left != right


def confirm_agreement(current):
    """协议更新后的同意询问。

    不同意就中止，而不是「同意了才能继续」那种软提示：按协议第 2 条，用户可以选择
    放弃更新、继续用他已经同意的那一版 —— 中止就是那个选项。

    白名单语义与 `--skip-ssl` 一致：只有明确答复 y/Y 才继续，空回车、EOF、
    「yes」一律按拒绝处理。同意必须是明确表达，不能靠默认值。
    """
    if _wants_silence():
        _refuse_agreement(current, quiet=True)

    print(f"{RED_BOLD}🌊 LinuxWave's user agreement has been updated ({AGREEMENT_ID}).{RESET}")
    print(f"{YELLOW}🌊 Read it here: {AGREEMENT_URL}{RESET}")
    print(f"{RED_BOLD}🌊 If you do not accept it, LinuxWave will not be updated and you keep "
          f"{current}.{RESET}")
    print(f"{RED_BOLD}🌊 Do you accept the updated agreement? [y/N]{RESET}")

    try:
        answer = input().strip()
    except (EOFError, KeyboardInterrupt):
        # 非交互（stdin 是 /dev/null）读不到答复：按拒绝处理，缺省往安全方向倒。
        answer = ""

    if answer not in ("y", "Y"):
        _refuse_agreement(current, quiet=False)

    record_agreement()
    print(f"{GREEN}🌊 Agreement accepted ({AGREEMENT_ID}).{RESET}")


def handle_selfupdate(input_string=""):
    _apply_timeouts(input_string)
    _apply_python_source(input_string)

    if find_config_dir() is None:
        print(f"{RED_BOLD}🌊 Error: LinuxWave is not installed. Run lib/install.sh first.{RESET}")
        sys.exit(1)

    silent.say("🌊 Fetching the latest version...")

    data = resolve_release()
    if data is None:
        print(f"{RED_BOLD}🌊 Error: Cannot reach the LinuxWave version data.{RESET}")
        print(f"{RED_BOLD}🌊 {LATEST_TOML_URL}{RESET}")
        sys.exit(1)
    latest = data["version"]

    print(f"🌊 Latest version found: {latest}")

    current = installed_version()
    if current and version_key(current) >= version_key(latest):
        silent.say(f"{GREEN}🌊 LinuxWave is already up to date (current: {current}).{RESET}")
        sys.exit(0)

    environment = dict(os.environ)
    environment["LINUXWAVE_UPDATE_VERSION"] = latest
    if data.get("branch"):
        environment["LINUXWAVE_UPDATE_BRANCH"] = data["branch"]

    if _wants_dry_run(input_string):
        silent.say("🌊 Dry run: nothing will be downloaded or written.")
        silent.say(f"🌊 Latest version : {latest}")
        silent.say(f"🌊 Current version: {current or '<none>'}")
        silent.say(f"🌊 Branch         : {data.get('branch') or '<unchanged>'}")
        silent.say(f"🌊 Install dir    : {load_base_dir()}")
        silent.say(f"🌊 Config dir     : {find_config_dir()}")
        silent.say("🌊 Would fetch linuxwavedata/<版本>/update_commands.sh and run it,")
        silent.say("🌊 regenerate lib/wave, install the Python dependencies, and rewrite")
        silent.say("🌊 VERSION.json.")
        sys.exit(0)

    # 试运行在**问协议之前**结束：它既不该弹询问，也不该写 AGREEMENT.json。
    # 这一段判断全是只读的（版本比较、协议是否已记录）。
    #
    # 也正因为问在这里，问的是「要不要跨过这道门槛去做这次更新」——
    # 与协议第 2 条给的选项（放弃更新 / 继续用已同意的那一版）对得上。
    if agreement_needs_consent(current) and not _is_cross_major(current, latest):
        confirm_agreement(current)

    if current:
        silent.say(f"🌊 Updating LinuxWave from {current} to {latest}...")
    else:
        silent.say(f"{YELLOW}🌊 No installed version found, updating to {latest}...{RESET}")

    try:
        result = run_script(environment, UPDATE_TIMEOUT)
    except subprocess.TimeoutExpired:
        print(f"{RED_BOLD}🌊 Error: The update timed out.{RESET}")
        sys.exit(1)

    if result.returncode != 0:
        print(f"{RED_BOLD}🌊 Error: The update failed (exit code {result.returncode}).{RESET}")
        sys.exit(1)

    # VERSION.json 是「装好了」的唯一凭据：selfupdate.sh 只在全部文件到位之后才写它。
    # 再确认一次，避免任何一层把失败当成成功。
    final = installed_version()
    if not final or version_key(final) < version_key(latest):
        print(f"{RED_BOLD}🌊 Error: The update did not complete (still on {final or 'unknown'}).{RESET}")
        sys.exit(1)

    silent.say("")
    silent.say(f"{GREEN}🌊 LinuxWave has been updated to {final}!{RESET}")

    # wave.py 会被覆盖，但当前进程已经加载完了，直接退出即可
    sys.exit(0)


if __name__ == "__main__":
    handle_selfupdate()
