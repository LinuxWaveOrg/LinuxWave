#!/usr/bin/env python3

# pkginfohelper.py
# 处理 wave 的 list / search / info 命令。

import json
import os
import sys
import platform
import re

# -------------------- 颜色定义 --------------------

RED_BOLD = '\033[1;31m'
GREEN = '\033[32m'
YELLOW = '\033[33m'
RESET = '\033[0m'

# -------------------- 配置加载 --------------------

import domains
import flags
import steplog
import tls
from configpaths import load_base_dir, require_safe_token


def github_api_headers(url):
    # 与 pkg/pkginstaller.py 一致：有 token 就只给 api.github.com 带上，
    # 缓解未认证 60 次/小时的限流。
    if "api.github.com" not in url:
        return {}
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if not token:
        return {}
    return {"Authorization": f"Bearer {token}"}

BASE_DIR = load_base_dir()
BIN_DIR = BASE_DIR / "bin"

# -------------------- 依赖库检查 --------------------

try:
    import requests
except ImportError:
    print(f"{RED_BOLD}🌊 Error: 'requests' library is not installed.{RESET}")
    sys.exit(1)

try:
    from versioncompare import sort_versions
except ImportError:
    print(f"{RED_BOLD}🌊 Error: 'versioncompare' module is not available.{RESET}")
    sys.exit(1)


# -------------------- 辅助函数 --------------------

def get_arch():
    machine = platform.machine().lower()
    if machine in ["arm64", "aarch64"]:
        return "arm64"
    elif machine in ["x86_64", "amd64"]:
        return "amd64"
    else:
        print(f"{RED_BOLD}🌊 Error: Unknown Arch!{RESET}")
        sys.exit(1)


def parse_pkg_from_bin(dirname):
    
    # 从 bin 目录下的目录名解析出包名和版本。
    # 形如 ldid@2.1.5-procursus7 -> ("ldid", "2.1.5-procursus7")
    
    if "@" in dirname:
        name, version = dirname.split("@", 1)
        return name, version
    return dirname, None


def fetch_remote_versions(pkg_name, arch, budget=None):
    
    # 通过 GitHub API 遍历 infosource 中的版本文件，返回所有可安装版本号列表。
    # 数据在 LinuxWaveOrg/infosource 仓库的 main 分支。
    
    pkg_name = require_safe_token(pkg_name, "package name")
    api_url = domains.index_list_url(arch, pkg_name)
    try:
        resp = requests.get(api_url, timeout=_to(budget), headers=github_api_headers(api_url),
                      **tls.request_kwargs())
        if resp.status_code != 200:
            return []
        # GitHub API 是 JSON 数组，镜像是一行一条的纯文本；listing_names 统一两者。
        versions = []
        for fname in domains.listing_names(resp.text):
            if fname.endswith("@common"):
                continue
            if "@" in fname:
                versions.append(fname.split("@")[1])
        return versions
    except Exception:
        return []


def fetch_remote_info(pkg_name, arch, budget=None):
    """取索引里的 `_<包名>@common`，返回 (字段字典, 原文)。

    原文给 `--raw` 用：它回答的是「这个作者名哪来的」，字段字典给不了。
    取不到时两个都是 None —— 调用方据此区分「没有这条记录」与「记录是空的」。
    """
    pkg_name = require_safe_token(pkg_name, "package name")
    common_url = f"{domains.api_domain()}/pkg/pkginfo_{arch}/{pkg_name}/_{pkg_name}@common"
    try:
        resp = requests.get(common_url, timeout=_to(budget), headers=github_api_headers(common_url),
                      **tls.request_kwargs())
        if resp.status_code != 200:
            return None, None
    except Exception:
        return None, None

    result = {}
    for key in ["des", "hom", "lic", "aut"]:
        match = re.search(rf'{key}:\s*"([^"]+)"', resp.text)
        if match:
            result[key] = match.group(1)
    return result, resp.text


# -------------------- list --------------------

def explain_unreachable_name_list(api_url, status=None):
    """名字清单拿不到时，说清「该往哪儿看」。

    这条路径最容易被误读成「镜像挂了」。实际最常见的两个原因是**本机配置**：
    域名少了 ref 段（镜像布局是 `<Org>/<repo>/<ref>/…`），或者域名指错产品。
    所以提示里必须把「期望形状」和「怎么看当前生效值」写出来 ——
    只说 `Cannot fetch package list` + 一个 404 的 URL，用户只能自己猜。
    """
    reason = "cannot read the package name list"
    if status:
        reason += f" (HTTP {status})"
    steplog.fail(
        reason,
        request=api_url,
        hint=["LINUXWAVE_API_DOMAIN must point at <mirror>/LinuxWave/infosource/<ref>",
              "the mirror lays files out under a ref segment — main or HEAD, whichever "
              "the mirror synced (see `wave mirror`)",
              "if the address is right, check the network / --proxy, or ask the "
              "administrator to re-run scripts/build_versions_index.py on the mirror"])


def handle_list(budget=None):
    
    # 直接扫描 BASE_DIR/bin 目录下的子目录，列出所有已安装的包
    # （2.2 起每个包是一个 <包名>@<版本号> 目录）。
    
    if not BIN_DIR.exists():
        print("🌊 No packages installed yet.")
        return

    entries = sorted([f.name for f in BIN_DIR.iterdir() if f.is_dir()])
    if not entries:
        print("🌊 No packages installed yet.")
        return

    for name in entries:
        print(f"🌊 - {name}")


# -------------------- search --------------------

def handle_search(query, budget=None):
    
    # 远程搜索 infosource 分支下所有包名，匹配查询词。
    
    arch = get_arch()

    # 数据在 LinuxWaveOrg/infosource 仓库的 main 分支
    api_url = domains.index_list_url(arch)

    try:
        resp = requests.get(api_url, timeout=_to(budget), headers=github_api_headers(api_url),
                      **tls.request_kwargs())
        if resp.status_code != 200:
            explain_unreachable_name_list(api_url, resp.status_code)
    except SystemExit:
        raise
    except Exception as error:
        steplog.fail(f"cannot reach the index: {error}", request=api_url,
                     hint=["check the network and any --proxy setting, then retry",
                           "run `wave mirror` to see the addresses in use"])

    # GitHub API 是 JSON 数组（要挑 type == "dir"），镜像是一行一个包名。
    # dirs_only=True 只对 JSON 有意义，纯文本那一侧本来就是目录清单。
    all_packages = [name for name in domains.listing_names(resp.text, dirs_only=True) if name]

    query_lower = query.lower()
    matches = [p for p in all_packages if query_lower in p.lower()]

    if not matches:
        print(f"🌊 No packages found matching '{query}'")
        return

    print(f"🌊 Found {len(matches)} package(s) matching '{query}':")
    for pkg in matches:
        print(f"🌊 - {pkg}")


# -------------------- info --------------------

# -------------------- info 的输出格式 --------------------
#
# 三条机器可读格式共用一份数据，字段名与 `wave info` 的标签一一对应；
# --raw 例外，它给的是索引里的 @common 原文，用来回答「这个作者名哪来的」。

INFO_FORMATS = ("json", "yaml", "toml", "raw")


def info_fields(pkg_name, remote, installed_versions, available_versions):
    remote = remote or {}
    return {
        "name": pkg_name,
        "author": remote.get("aut"),
        "description": remote.get("des"),
        "homepage": remote.get("hom"),
        "license": remote.get("lic"),
        "installed": list(installed_versions),
        "available": list(available_versions),
        "latest": available_versions[0] if available_versions else None,
    }


def info_as_json(fields):
    return json.dumps(fields, indent=2, ensure_ascii=False)


def info_as_yaml(fields):
    # 标量一律走 json.dumps：JSON 的字符串写法是合法的 YAML 标量，
    # 这样引号、冒号、换行都不用自己处理。
    lines = []
    for key, value in fields.items():
        if value is None:
            continue
        if isinstance(value, list):
            if not value:
                lines.append(f"{key}: []")
                continue
            lines.append(f"{key}:")
            for item in value:
                lines.append(f"  - {json.dumps(item, ensure_ascii=False)}")
        else:
            lines.append(f"{key}: {json.dumps(value, ensure_ascii=False)}")
    return "\n".join(lines)


def info_as_toml(fields):
    lines = []
    for key, value in fields.items():
        if value is None:
            continue
        if isinstance(value, list):
            rendered = ", ".join(json.dumps(item, ensure_ascii=False) for item in value)
            lines.append(f"{key} = [{rendered}]")
        else:
            lines.append(f"{key} = {json.dumps(value, ensure_ascii=False)}")
    return "\n".join(lines)


def render_info(output_format, pkg_name, remote, record_text,
                installed_versions, available_versions):
    if output_format == "raw":
        # 索引里没有这条记录时没什么可打印的。打印空行等于让人以为「这条记录是空的」，
        # 而实际原因是「压根没有这条记录」—— 两者要分清楚。
        if record_text is None:
            print(f"{RED_BOLD}🌊 Error: {pkg_name} has no @common record in the index.{RESET}")
            steplog.hint_line(f"{GREEN}wave info {pkg_name} --json{RESET} prints what is available",
                              first=True)
            sys.exit(1)
        return record_text

    fields = info_fields(pkg_name, remote, installed_versions, available_versions)
    if output_format == "json":
        return info_as_json(fields)
    if output_format == "yaml":
        return info_as_yaml(fields)
    return info_as_toml(fields)


def handle_info(pkg_name, output_format=None, budget=None):
    
    # 先扫描本地 bin 目录，已安装则输出本地信息；
    # 未安装则拉远程 @common 文件。
    
    arch = get_arch()

    # 1. 扫描本地 bin 目录，找出所有该包的已安装版本
    # （2.2 起每个版本对应一个 <包名>@<版本号> 目录）
    installed_versions = []
    if BIN_DIR.exists():
        for f in BIN_DIR.iterdir():
            if f.is_dir():
                name, version = parse_pkg_from_bin(f.name)
                if name.lower() == pkg_name.lower() and version:
                    installed_versions.append(version)

    installed_versions = sort_versions(installed_versions)

    # 2. 拉取远程 @common
    remote, record_text = fetch_remote_info(pkg_name, arch, budget)

    # 3. 拉取远程所有可安装版本
    available_versions = fetch_remote_versions(pkg_name, arch, budget)
    available_versions = sort_versions(available_versions)

    # 4. 输出
    if output_format:
        text = render_info(output_format, pkg_name, remote, record_text,
                           installed_versions, available_versions)
        if text is not None:
            print(text)
        return

    print(f"🌊 Name:               {pkg_name}")

    if remote:
        print(f"🌊 Author:             {remote.get('aut', 'Unknown')}")
        print(f"🌊 Description:        {remote.get('des', 'No description')}")
        if remote.get("hom"):
            print(f"🌊 Homepage:           {remote.get('hom')}")

    if installed_versions:
        print(f"🌊 Installed versions: {installed_versions[0]}")
        for ver in installed_versions[1:]:
            print(f"                       {ver}")
    else:
        print(f"🌊 Installed versions: None")

    if available_versions:
        print(f"🌊 Available versions: {available_versions[0]}")
        for ver in available_versions[1:]:
            print(f"                       {ver}")


# -------------------- 入口 --------------------

def parse_info_arguments(words):
    """返回 (其余参数, 输出格式或 None)。

    四种格式互斥：同时给两个就报错，而不是悄悄挑一个 —— 「哪个生效」不该靠猜。
    """
    import timeouts

    chosen = []
    operands = []
    skip_next = False
    for word in words:
        if skip_next:
            skip_next = False          # 这是上一个超时旗标的值，不是包名
            continue
        if not word.startswith("-"):
            operands.append(word)
            continue
        name = flags.flag_name(word)
        if name.startswith("--") and name[2:] in INFO_FORMATS:
            chosen.append(name[2:])
        elif name in timeouts.FLAG_FIELDS:
            # 三档超时是全局旗标，由 _budget() 处理；这里只是跳过，
            # 不能当成「未知选项」—— 那会让 wave info 与其它命令不一致。
            if "=" not in word:
                skip_next = True       # --max-time 1min 的空格写法
        else:
            print(f"{RED_BOLD}🌊 Error: unknown option {word}{RESET}")
            steplog.hint_line("wave info accepts --json, --yaml, --toml or --raw",
                              first=True)
            sys.exit(1)

    if len(chosen) > 1:
        given = ", ".join(f"--{name}" for name in chosen)
        print(f"{RED_BOLD}🌊 Error: choose one output format, got: {given}{RESET}")
        steplog.hint_line("--json, --yaml, --toml and --raw are mutually exclusive",
                          first=True)
        sys.exit(1)

    return operands, (chosen[0] if chosen else None)


def _to(value):
    """Budget 或裸秒数都能喂给 requests。"""
    return value.request_timeout if hasattr(value, "request_timeout") else value


def _budget(input_string):
    import common

    # 三档超时与 install 走同一个入口，所以「值不合法」的报错与退出码也一样
    budget = common.parse(input_string).timeouts
    budget.start()
    return budget


def handle_info_command(input_string):

    # 解析完整输入字符串（如 "wave info ldid"），分派到 list / search / info

    words = input_string.split()
    if len(words) < 2:
        print(f"{RED_BOLD}🌊 Error: Missing subcommand.{RESET}")
        sys.exit(1)

    subcommand = words[1].lower()
    budget = _budget(input_string)

    if subcommand == "list":
        handle_list(budget)
    elif subcommand == "search":
        if len(words) < 3:
            print(f"{RED_BOLD}🌊 Error: Missing search query.{RESET}")
            sys.exit(1)
        handle_search(words[2], budget)
    elif subcommand == "info":
        operands, output_format = parse_info_arguments(words[2:])
        pkg_name = operands[0].partition("@")[0] if operands else ""
        if not pkg_name:
            print(f"{RED_BOLD}🌊 Error: Missing package name.{RESET}")
            sys.exit(1)
        handle_info(pkg_name, output_format, budget)
    else:
        print(f"{RED_BOLD}🌊 Error: Unknown subcommand '{subcommand}'.{RESET}")
        sys.exit(1)


if __name__ == "__main__":
    input_string = " ".join(sys.argv[1:])
    handle_info_command(input_string)
