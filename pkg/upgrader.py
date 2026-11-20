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

import common
import domains
import flags as flags_module
import silent
import requests

from configpaths import require_safe_token
from depsinstaller import get_field, parse_common_fields
from linker import link_package
from pkginstaller import (
    confirm_skip_ssl,
    fetch_max_version,
    first_package_token,
    handle_install,
    parse_flags,
)
from versioncompare import safe_parse_pkg_version as version_key
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

# 「升级全部」的两种写法。它们同样要在 split_input 里剥掉 —— 否则会被当成
# 包名或未知旗标带下去，而批量模式里每个包都该收到同一批「其余旗标」。
ALL_LONG = ("--all",)
ALL_SHORT = "a"

# 需要记下来、但不属于「删除旧版本」的写法：给了替代做法，而不是静默忽略
REJECTED_FLAGS = {
    "--ver": "Use 'wave install <package>@<version>' to install a specific version",
    "--no-link": "Run 'wave link <package>@<version>' afterwards to choose the linked version",
    # 4.0 的旧名，同样拒绝；提示里给的是规范写法
    "--unlink": "Run 'wave link <package>@<version>' afterwards to choose the linked version",
}


def split_input(input_string):
    """把 upgrade 专属旗标剥掉，返回 (剩余词, 是否移除旧版本, 是否全部)。

    -X 与 -a 既认单独出现的写法，也认混在短旗标簇里的写法（-Xv 等于 -X -v，
    -aX 等于 -a -X），与 parse_flags 把 -abc 拆成 -a -b -c 的规则保持一致。
    """
    remove_old = False
    upgrade_all = False
    kept = []
    for word in input_string.split()[2:]:
        if word in REMOVE_OLD_LONG:
            remove_old = True
            continue
        if word in ALL_LONG:
            upgrade_all = True
            continue
        # 单个 - 开头（且不是 --）：可能是 -X / -a，也可能是 -Xv / -aX 这种簇
        if word.startswith("-") and not word.startswith("--") and len(word) > 1:
            letters = word[1:]
            if REMOVE_OLD_SHORT in letters:
                remove_old = True
                letters = letters.replace(REMOVE_OLD_SHORT, "")
            if ALL_SHORT in letters:
                upgrade_all = True
                letters = letters.replace(ALL_SHORT, "")
            if not letters:
                continue
            word = "-" + letters
        kept.append(word)
    return kept, remove_old, upgrade_all


def ask_yes_no(prompt):
    """问一次 Y/n。返回 True / False；读到 EOF（非交互）时返回 None。"""
    if silent.is_silent():
        # 静默（-s / -sS）下提示语被吞掉，还要用户回答就成了「看起来卡死」。
        # 返回 None，让调用方走非交互分支（保留旧版本，误删比漏删危险）。
        return None
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
    """把公共旗标里的超时写进环境变量（后面取索引、取 @common 都按它来）。

    解析交给 cli/common.py：取值校验与「40s 是多少秒」的换算只有那一份实现。
    只写环境变量而不重建整份 config —— --skip-ssl 的询问留给 handle_install，
    那次才是真正要下载的时候。
    """
    options = common.parse(words)
    os.environ[domains.MAX_TIME_ENV] = str(options.timeouts.total)


# -------------------- 清理旧版本 --------------------

def remove_old_versions(bin_name, keep_version, assume_yes=False):
    """移除 keep_version 之外的所有已装版本，保留 keep_version。

    assume_yes：批量升级时用。`wave upgrade --all -X` 已经把「删旧版本」这件事
    对每个包都说了，再逐个包弹一次问题既啰嗦又容易答错对象；所以批量模式下
    直接按用户写下的意图执行。
    """
    old = [version for version in find_installed_versions(bin_name)
           if version_key(version) < version_key(keep_version)]
    if not old:
        silent.say(f"🌊 No old versions of {bin_name} to remove.")
        return

    # 批量模式：-X 是对每个包说的，不必再逐个确认
    if assume_yes:
        silent.say(f"🌊 Removing {len(old)} old version(s) of {bin_name}...")
        uninstall_versions(bin_name, old)
        return

    # 只有一个旧版本：不必再问选哪个，「移除旧版本」已经表达得很清楚
    if len(old) == 1:
        silent.say(f"🌊 Removing the old version {bin_name}@{old[0]}...")
        uninstall_versions(bin_name, old)
        return

    silent.say(f"🌊 {len(old)} old versions of {bin_name} are installed: {', '.join(old)}")
    answer = ask_yes_no("🌊 Remove all of them? [Y/n] ")
    if answer is None:
        # 非交互（CI、管道）：没有人能替用户回答，保留旧版本比误删安全
        print(f"{YELLOW}🌊 Cannot ask without a terminal; no old version was removed.{RESET}")
        return

    if answer:
        uninstall_versions(bin_name, old)
        return

    silent.say("🌊 Choose which old versions to remove, one or more.")
    try:
        selected = select_versions(bin_name, old)
    except SystemExit:
        # 选择过程本身被取消（Ctrl+C 或读不到输入）不该让已经完成的升级失败
        print(f"{YELLOW}🌊 No old version was removed.{RESET}")
        return
    uninstall_versions(bin_name, selected)


# -------------------- 主流程 --------------------

def upgrade_everything(words, remove_old):
    """把每个已装包都带到最新版本。

    批量不是「一把梭」：某个包在索引里没了、下载失败、校验不过，都不该让排在
    后面的包白等 —— 逐个跑、逐个收结果，最后一次性报总账。单个包的成败本来就
    由 handle_upgrade 打在终端上，这里只补汇总与退出码。
    """
    import common
    from latest import fetch_names, installed_bin_names, resolve_package_name

    # 下面这一次取名字清单也走 HTTPS，所以 --skip-ssl 必须先有结论 ——
    # 否则用户答应了跳过校验，第一个请求照样失败。批量模式只问一次。
    accepted_flags = parse_flags("wave install placeholder " + " ".join(words),
                                 command="upgrade")
    confirm_skip_ssl(accepted_flags)

    targets = installed_bin_names()
    if not targets:
        # 什么也没装不是错误（退出码 0），静默时连这句都不该出现
        silent.say("🌊 No packages installed yet.")
        return

    # bin/ 里是 bin_name，索引里是包名，两者不一定相同（choma -> ChOma）。
    # 复用 latest 的对照逻辑，这样 `wave latest -a` 报的集合与这里逐个升级的集合一致。
    # 三档超时也要作用在这一步：它同样是请求。
    index_names = fetch_names(detect_arch(), common.parse(words).timeouts)
    packages = [resolve_package_name(bin_name, index_names) for bin_name in targets]

    # 其余旗标原样带下去（--proxy / --max-time / -v…）。-X 被 split_input 剥掉了，
    # 这里补回去：批量模式下它是对每一个包都生效，而不是只对某一个。
    tail = " ".join(words)
    if remove_old:
        tail = (tail + " -X").strip()

    upgraded, unchanged, failed = [], [], []
    for bin_name, package_name in zip(targets, packages):
        before = set(find_installed_versions(bin_name))
        try:
            handle_upgrade(f"wave upgrade {package_name} {tail}".strip(), assume_yes=True)
        except SystemExit as status:
            # 单个包失败（索引里没有、下载/校验失败）只记账，继续下一个
            if status.code not in (0, None):
                failed.append(package_name)
                continue
        after = set(find_installed_versions(bin_name))
        (upgraded if after - before else unchanged).append(package_name)

    if len(targets) > 1:
        silent.say(f"🌊 {len(upgraded)} upgraded, {len(unchanged)} already at the latest, "
                  f"{len(failed)} failed.")
    if failed:
        print(f"{RED_BOLD}🌊 Error: could not upgrade {', '.join(failed)}.{RESET}")
        print(f"{YELLOW}🌊 The other packages were handled; fix the cause and run it again.{RESET}")
        sys.exit(1)


def handle_upgrade(input_string, assume_yes=False):
    words, remove_old, upgrade_all = split_input(input_string)

    if upgrade_all:
        if first_package_token("wave upgrade " + " ".join(words)):
            print(f"{RED_BOLD}🌊 Error: --all upgrades every installed package; "
                  f"drop the package name.{RESET}")
            print(f"{YELLOW}🌊 Either 'wave upgrade <package>' or 'wave upgrade --all'.{RESET}")
            sys.exit(1)
        upgrade_everything(words, remove_old)
        return

    raw_package = first_package_token("wave upgrade " + " ".join(words))
    if not raw_package:
        print(f"{RED_BOLD}🌊 Error: Missing package name.{RESET}")
        print(f"{YELLOW}🌊 Use 'wave upgrade <package>', "
              f"or 'wave upgrade --all' for every installed package.{RESET}")
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
    # 报错要说 `wave upgrade` 并回显用户真正敲的那一行，而不是内部那条探针
    accepted_flags = parse_flags(probe, command="upgrade", shown=input_string)
    for flag, hint in REJECTED_FLAGS.items():
        if flag in accepted_flags:
            renamed = (f" (now called {flags_module.ALIASES[flag]})"
                       if flag in flags_module.ALIASES else "")
            print(f"{RED_BOLD}🌊 Error: {flag}{renamed} is not accepted by upgrade.{RESET}")
            print(f"{YELLOW}🌊 {hint}.{RESET}")
            sys.exit(1)

    # 先定好超时，后面取索引与 @common 都按它来
    apply_timeout(rest)

    arch = detect_arch()
    silent.say(f"🌊 Checking the latest version of {package_name}...")
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
            silent.say(f"🌊 Upgrading {bin_name}: {installed[0]} -> {latest}")
        else:
            silent.say(f"🌊 {bin_name} is not installed; installing {latest}.")
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
                silent.say(f"🌊 Linked {bin_name} -> {bin_name}@{linked}")
        except Exception as error:
            print(f"{YELLOW}🌊 Warning: could not re-point the unversioned link ({error}).{RESET}")

    if remove_old:
        remove_old_versions(bin_name, keep, assume_yes=assume_yes)


if __name__ == "__main__":
    try:
        handle_upgrade(" ".join(sys.argv[1:]))
    except KeyboardInterrupt:
        silent.say("🌊 Operation cancelled by user.")
        sys.exit(130)
