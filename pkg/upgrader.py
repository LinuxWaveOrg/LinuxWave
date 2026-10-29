#!/usr/bin/env python3

# upgrader.py

# `wave upgrade <包名>`：装到索引里的最新版本。
#
# 与 `wave install <包名>` 的区别只有两点：
#   1. 版本由索引决定，不接受 `包名@版本`（要那版就直接 install）；
#   2. `-X` 会在升级之后把更旧的版本清掉。
#
# 版本是共存的（`bin/<名字>@<版本>` 各占一个目录），所以「升级」本质上就是再装一个，
# 旧的那份不会自己消失 —— 这也是为什么需要一个显式的 `-X`。

import os
import platform
import sys

import domains
import requests

from configpaths import require_safe_token
from depsinstaller import get_field, parse_common_fields
from linker import link_package
from pkginstaller import (
    fetch_max_version,
    first_package_token,
    handle_install,
    parse_flags,
)
from pkgversionparser import safe_parse_pkg_version as version_key
from uninstaller import find_installed_versions, select_versions, uninstall_versions

RED_BOLD = '\033[1;31m'
GREEN = '\033[32m'
YELLOW = '\033[33m'
RESET = '\033[0m'


# -------------------- 旗标 --------------------

# 「同时移除旧版本」的四种写法完全等价。长参数之所以给了三个，是因为
# -version 与 -versions 单复数都记不牢，索性都认；--rov 是它们的缩写。
# 短参数 -X 是刻意选的：R 要留给 recurse / reverse / rollback，X 没有别的含义，
# 而且形状像「删除」的叉。
#
# **帮助里只写 `-X, --remove-old-versions`**，但下面三个长写法必须继续能用：
# 3.2.0 发布过单数形式，已经写进别人的脚本和 CI 里了。
REMOVE_OLD_LONG = ("--remove-old-version", "--remove-old-versions", "--rov")
REMOVE_OLD_SHORT = "X"

# 需要记下来、但不属于「删除旧版本」的写法：给了替代做法，而不是静默忽略
REJECTED_FLAGS = {
    "--ver": "Use 'wave install <package>@<version>' to install a specific version",
    "--unlink": "Run 'wave link <package>@<version>' afterwards to choose the linked version",
}


def split_input(input_string):
    """把 upgrade 专属旗标剥掉，返回 (剩余词, 是否要求移除旧版本)。

    -X 既认单独出现的写法，也认混在短旗标簇里的写法（-Xv 等于 -X -v），
    与 pkginstaller.parse_flags 把 -abc 拆成 -a -b -c 的规则保持一致。
    """
    remove_old = False
    kept = []
    for word in input_string.split()[2:]:
        if word in REMOVE_OLD_LONG:
            remove_old = True
            continue
        # 单个 - 开头（且不是 --）：可能是 -X，也可能是 -Xv 这种簇
        if word.startswith("-") and not word.startswith("--") and len(word) > 1:
            letters = word[1:]
            if REMOVE_OLD_SHORT in letters:
                remove_old = True
                letters = letters.replace(REMOVE_OLD_SHORT, "")
                if not letters:
                    continue
                word = "-" + letters
        kept.append(word)
    return kept, remove_old


def ask_yes_no(prompt):
    """问一次 Y/n。返回 True / False；读到 EOF（非交互）时返回 None。"""
    while True:
        try:
            answer = input(prompt).strip().lower()
        except (EOFError, KeyboardInterrupt):
            return None
        if answer in ("y", "yes", ""):
            return True
        if answer in ("n", "no"):
            return False


# -------------------- 环境 --------------------

def detect_arch():
    machine = platform.machine().lower()
    if machine in ("arm64", "aarch64"):
        return "arm64"
    if machine in ("x86_64", "amd64"):
        return "amd64"
    print(f"{RED_BOLD}🌊 Error: Unknown Arch!{RESET}")
    sys.exit(1)


def fetch_common_fields(package_name, arch):
    """取 @common，拿 bin_name。包名与 bin_name 不一定相同（choma → ChOma），
    而 bin/ 与 links/ 用的是 bin_name。"""
    common_url = f"{domains.api_domain()}/pkg/pkginfo_{arch}/{package_name}/_{package_name}@common"
    try:
        response = requests.get(common_url, timeout=domains.timeout_from_env())
    except Exception as error:
        print(f"{RED_BOLD}🌊 Error: {error}{RESET}")
        sys.exit(1)
    if response.status_code != 200:
        print(f"{RED_BOLD}🌊 Error: Cannot fetch @common file.{RESET}")
        print(f"{RED_BOLD}🌊   {common_url}{RESET}")
        sys.exit(1)
    return parse_common_fields(response.text)


def apply_timeout(words):
    """把 --max-time 写进环境变量。

    只解析超时这一项：整份 `handle_download_args` 会去问 --skip-ssl，
    而那一步在后面的 handle_install 里还会再问一次，没必要问两遍。
    """
    for index, word in enumerate(words):
        raw = None
        if word == "--max-time":
            raw = words[index + 1] if index + 1 < len(words) else ""
        elif word.startswith("--max-time="):
            raw = word.split("=", 1)[1]
        else:
            continue

        if raw == "":
            print(f"{RED_BOLD}🌊 Error: Missing time after --max-time "
                  f"(e.g. --max-time=2min, --max-time=40).{RESET}")
            sys.exit(1)
        try:
            os.environ[domains.MAX_TIME_ENV] = str(domains.parse_duration(raw))
        except ValueError:
            print(f"{RED_BOLD}🌊 Error: Cannot parse --max-time '{raw}'.{RESET}")
            print(f"{RED_BOLD}🌊 Use seconds or a unit: 40, 40s, 1min, 1min20s, 2h.{RESET}")
            sys.exit(1)
        return


# -------------------- 清理旧版本 --------------------

def remove_old_versions(bin_name, keep_version):
    """移除 keep_version 之外的所有已装版本，保留 keep_version。"""
    old = [version for version in find_installed_versions(bin_name)
           if version_key(version) < version_key(keep_version)]
    if not old:
        print(f"🌊 No old versions of {bin_name} to remove.")
        return

    # 只有一个旧版本：不必再问选哪个，「移除旧版本」已经表达得很清楚
    if len(old) == 1:
        print(f"🌊 Removing the old version {bin_name}@{old[0]}...")
        uninstall_versions(bin_name, old)
        return

    print(f"🌊 {len(old)} old versions of {bin_name} are installed: {', '.join(old)}")
    answer = ask_yes_no("🌊 Remove all of them? [Y/n] ")
    if answer is None:
        # 非交互（CI、管道）：没有人能替用户回答，保留旧版本比误删安全
        print(f"{YELLOW}🌊 Cannot ask without a terminal; no old version was removed.{RESET}")
        return

    if answer:
        uninstall_versions(bin_name, old)
        return

    print("🌊 Choose which old versions to remove, one or more.")
    try:
        selected = select_versions(bin_name, old)
    except SystemExit:
        # 选择过程本身被取消（Ctrl+C 或读不到输入）不该让已经完成的升级失败
        print(f"{YELLOW}🌊 No old version was removed.{RESET}")
        return
    uninstall_versions(bin_name, selected)


# -------------------- 主流程 --------------------

def handle_upgrade(input_string):
    words, remove_old = split_input(input_string)

    raw_package = first_package_token("wave upgrade " + " ".join(words))
    if not raw_package:
        print(f"{RED_BOLD}🌊 Error: Missing package name.{RESET}")
        print(f"{YELLOW}🌊 Usage: wave upgrade <package> [flags]{RESET}")
        sys.exit(1)

    if "@" in raw_package:
        print(f"{RED_BOLD}🌊 Error: upgrade always targets the latest version.{RESET}")
        print(f"{YELLOW}🌊 Use 'wave install {raw_package}' to install that exact version.{RESET}")
        sys.exit(1)

    package_name = require_safe_token(raw_package, "package name")

    # 其余旗标交给 install 的白名单校验：upgrade 自己的旗标已经在上面剥掉了，
    # 所以这里能接受的恰好就是 install 能接受的减去被拒绝的那两个。
    try:
        index = words.index(raw_package)
    except ValueError:
        index = 0
    rest = words[:index] + words[index + 1:]
    probe = "wave install placeholder " + " ".join(rest)
    flags = parse_flags(probe)
    for flag, hint in REJECTED_FLAGS.items():
        if flag in flags:
            print(f"{RED_BOLD}🌊 Error: {flag} is not accepted by upgrade.{RESET}")
            print(f"{YELLOW}🌊 {hint}.{RESET}")
            sys.exit(1)

    # 先定好超时，后面取索引与 @common 都按它来
    apply_timeout(rest)

    arch = detect_arch()
    print(f"🌊 Checking the latest version of {package_name}...")
    latest = fetch_max_version(package_name, arch)

    common_fields = fetch_common_fields(package_name, arch)
    bin_name = get_field(common_fields, "bin_name")
    if not bin_name:
        print(f'{RED_BOLD}🌊 Missing "bin_name" field, Please contact the administrator.{RESET}')
        sys.exit(1)
    bin_name = require_safe_token(bin_name, "bin_name")

    installed = find_installed_versions(bin_name)
    newer = [version for version in installed if version_key(version) > version_key(latest)]

    did_install = False
    if newer:
        # 索引落后于本机（例如某个版本后来被撤下）：降级不是升级，宁可不动
        keep = installed[0]
        print(f"{YELLOW}🌊 Warning: {bin_name}@{installed[0]} is newer than {latest}, "
              f"the latest version in the index.{RESET}")
        print(f"{YELLOW}🌊 Leaving it in place; nothing was downloaded.{RESET}")
    elif latest in installed:
        keep = latest
        print(f"{GREEN}🌊 {bin_name} is already at the latest version ({latest}).{RESET}")
    else:
        keep = latest
        if installed:
            print(f"🌊 Upgrading {bin_name}: {installed[0]} -> {latest}")
        else:
            print(f"🌊 {bin_name} is not installed; installing {latest}.")
        # 整个安装流水线（含依赖、路径重写、建链接）都复用 install，
        # 只把包名换成「包名@最新版本」，其余旗标原样带下去
        install_words = list(words)
        install_words[index] = f"{package_name}@{latest}"
        handle_install(" ".join(["wave", "install"] + install_words))
        did_install = True

    if did_install:
        # install 自己会建链接，这里只确认真的装上了，避免后面清理旧版本时误判
        if latest not in find_installed_versions(bin_name):
            print(f"{RED_BOLD}🌊 Error: the upgrade did not complete ({bin_name}@{latest} is missing).{RESET}")
            sys.exit(1)
    else:
        # 没下载任何东西时也要把不带版本号的链接指到 keep ——
        # 否则「已经是最新」却仍让 `wave` 命令跑着旧版本。
        try:
            linked = link_package(bin_name, keep)
            if linked:
                print(f"🌊 Linked {bin_name} -> {bin_name}@{linked}")
        except Exception as error:
            print(f"{YELLOW}🌊 Warning: could not re-point the unversioned link ({error}).{RESET}")

    if remove_old:
        remove_old_versions(bin_name, keep)


if __name__ == "__main__":
    try:
        handle_upgrade(" ".join(sys.argv[1:]))
    except KeyboardInterrupt:
        print("🌊 Operation cancelled by user.")
        sys.exit(130)
