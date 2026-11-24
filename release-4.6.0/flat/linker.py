#!/usr/bin/env python3

# linker.py

# 软件包的“不带版本号软链接”管理：links/{名称} -> ../bin/{名称}@{版本号}/{名称}
# 只处理软件包（bin/ 下的目录），不碰依赖（deps/ 下的整棵树）。
# 装完软件包后会自动改指到最高版本；早期装的包可以用 `wave link` 补上，
# 用 `wave unlink` 撤掉。

import os
import sys


# -------------------- 颜色定义 --------------------

RED_BOLD = '\033[1;31m'
GREEN = '\033[32m'
YELLOW = '\033[33m'
RESET = '\033[0m'


# -------------------- 配置加载 --------------------

import silent
from configpaths import assert_inside, assert_inside_entry, load_base_dir, require_safe_token


BASE_DIR = load_base_dir()
BIN_DIR = BASE_DIR / "bin"
LINKS_DIR = BASE_DIR / "links"
TREE_MARKER = ".is_a_tree"


# -------------------- 版本库 --------------------

try:
    from versioncompare import get_max_version
except ImportError:
    print(f"{RED_BOLD}🌊 Error: 'versioncompare' module is not available.{RESET}")
    sys.exit(1)


# -------------------- 安装状态查询 --------------------

def installed_versions(name):
    # bin/{名称}@{版本号}/ 里的版本号列表（名称即 `wave list` 显示的那个）
    name = require_safe_token(name, "package name")
    versions = []
    if not BIN_DIR.is_dir():
        return versions

    prefix = f"{name}@"
    for entry in BIN_DIR.iterdir():
        if entry.is_dir() and entry.name.startswith(prefix):
            version = entry.name[len(prefix):]
            if version:
                versions.append(version)
    return versions


def installed_packages():
    # bin/ 下所有软件包的名称，去重并按字母序
    names = set()
    if not BIN_DIR.is_dir():
        return []

    for entry in BIN_DIR.iterdir():
        if not entry.is_dir() or "@" not in entry.name:
            continue
        name, _, version = entry.name.partition("@")
        if name and version:
            names.add(name)
    return sorted(names)


def _owner_from_target(link_name, target):
    # 从一个 links/ 软链接的指向里认出它属于哪个包的哪个版本。
    #
    # 整树包的附属命令（git-upload-pack、fdtget 这种）链接名**不是**包名，只看名字
    # 会把它们当成「一个没链接的包」；目标路径里那段 {包名}@{版本} 才是权威。
    # binary 是 links/x -> ../bin/x@1/x，整树是 links/x -> ../bin/x@1/bin/x，
    # 中间多一层 bin/ —— 从后往前找第一个带 @ 的段即可。
    if os.path.basename(target) != link_name:
        return None

    for part in reversed(os.path.dirname(target).split(os.sep)):
        if "@" not in part:
            continue
        owner_name, _, owner_version = part.partition("@")
        if owner_name and owner_version:
            return owner_name, owner_version
    return None


def linked_version(name):
    # links/{名称} 当前指向哪个版本；没链接、或指向别的名字时返回 None
    name = require_safe_token(name, "package name")
    link = LINKS_DIR / name
    if not link.is_symlink():
        return None

    # 这里**不**要求 owner 等于 name：链接名可以是一个附属命令
    # （links/git-upload-pack -> .../git@2.56.1/bin/git-upload-pack），
    # 版本照样指向一个真实装着的版本。名字对不对是 unlink/refresh 的事，
    # 不是「这个链接指向哪个版本」的问题。
    owner = _owner_from_target(name, os.readlink(link))
    if owner is None:
        return None
    return owner[1]


def is_dangling(name):
    # links/{名称} 是不是指向一个已经不存在的版本（已卸载，或目录被手动删掉）
    version = linked_version(name)
    return version is not None and version not in installed_versions(name)


def unversioned_links():
    # links/ 下所有不带版本号的软链接（带版本号的链接名里一定有 @）
    if not LINKS_DIR.is_dir():
        return []

    names = []
    for entry in LINKS_DIR.iterdir():
        if entry.is_symlink() and "@" not in entry.name:
            names.append(entry.name)
    return sorted(names)


# -------------------- 链接操作 --------------------

def is_tree_package(name, version):
    # 整树软件包的标记：安装时由 depsmanager.sh 写在 bin/{名称}@{版本}/.is_a_tree
    return (BIN_DIR / f"{name}@{version}" / TREE_MARKER).is_file()


def link_target(name, version, bin_name=None):
    # 链接应当指向哪个相对路径（相对 links/）。形态由安装目录里的标记决定，
    # 索引里的 install 字段只在安装那一刻用，这里不重新读索引。
    # bin_name 只在整树包链接「其余命令」时才与包名不同。
    bin_name = bin_name or name
    if is_tree_package(name, version):
        return f"../bin/{name}@{version}/bin/{bin_name}"
    return f"../bin/{name}@{version}/{bin_name}"


def extra_bin_names(name, version):
    # 整树包 bin/ 下除主命令之外的可执行文件名。与 surfboard/depsmanager.sh 装完
    # 那一刻做的事保持一致：那边是当场逐条 ln，这边给 `wave link` 补链用。
    if not is_tree_package(name, version):
        return []

    bin_dir = BIN_DIR / f"{name}@{version}" / "bin"
    if not bin_dir.is_dir():
        return []

    names = []
    for entry in sorted(bin_dir.iterdir()):
        if not entry.is_file() or not os.access(entry, os.X_OK):
            continue
        if entry.name == name:
            continue
        names.append(entry.name)
    return names


def create_link(name, version):
    # 建立或重指 links/{名称}；已存在（含悬空链接）先删掉再建
    name = require_safe_token(name, "package name")
    version = require_safe_token(version, "package version")
    LINKS_DIR.mkdir(parents=True, exist_ok=True)

    link = LINKS_DIR / name
    assert_inside_entry(link, LINKS_DIR, "link path")
    if link.is_symlink() or link.exists():
        link.unlink()

    link.symlink_to(link_target(name, version))

    # 整树包里必须一起用的命令（git-upload-pack、fdtget 这种）也各建一条，
    # 否则 `wave link` 之后只调得动主命令 —— 与安装时 depsmanager.sh 做的对齐。
    for extra in extra_bin_names(name, version):
        extra_link = LINKS_DIR / extra
        assert_inside_entry(extra_link, LINKS_DIR, "link path")
        if extra_link.is_symlink() or extra_link.exists():
            extra_link.unlink()
        extra_link.symlink_to(link_target(name, version, extra))

    return link


def remove_link(name):
    name = require_safe_token(name, "package name")
    removed = False

    # 附属命令的链接名不是包名（git-upload-pack 这种），只能靠目标路径认领；
    # 只删 links/{包名} 会把它们留在 links/ 里，指向已经不存在的版本。
    for entry in unversioned_links():
        owner = _owner_from_target(entry, os.readlink(LINKS_DIR / entry))
        if owner is not None and owner[0] == name:
            link = LINKS_DIR / entry
            assert_inside_entry(link, LINKS_DIR, "link path")
            link.unlink()
            removed = True

    return removed


def link_package(name, requested_version=None):
    # 把某个已安装的软件包链接到指定版本（默认最高版本），返回版本号；没装返回 None
    versions = installed_versions(name)
    if not versions:
        return None

    version = requested_version
    if not version or version == "latest":
        version = get_max_version(versions)
    elif version not in versions:
        return None

    create_link(name, version)
    return version


def remove_versioned_links(name, version):
    """摘掉 `links/{链接名}@{版本}` 这一类链接 —— 安装时由 depsmanager.sh 建的。

    整树包的每个可执行文件各有一条（`git-upload-pack@2.56.1`），链接名不等于包名，
    只能靠目标路径里的 `{包名}@{版本}` 段认领。卸载只删主命令那一条会留下这些，
    `random_test` 的「links/ 没有残留」就是这么红的。
    """
    name = require_safe_token(name, "package name")
    version = require_safe_token(version, "package version")

    removed = []
    if not LINKS_DIR.is_dir():
        return removed

    for entry in sorted(LINKS_DIR.iterdir()):
        if not entry.is_symlink():
            continue
        # 不带版本号的那一条归 refresh/unlink 管：还有旧版本时它要降指过去，
        # 一条不剩时才该消失。在这里删掉会把「卸载 2.0 后降到 1.0」变成「没链接」。
        if "@" not in entry.name:
            continue
        owner = _owner_from_target(entry.name.partition("@")[0], os.readlink(entry))
        if owner == (name, version):
            assert_inside_entry(entry, LINKS_DIR, "link path")
            entry.unlink()
            removed.append(entry.name)
    return removed


# -------------------- 命令解析 --------------------

def parse_targets(input_string):
    # 形如 "wave link ffmpeg@latest -a"；返回 (是否 --all, [目标...])
    words = input_string.split()[2:]

    everything = False
    targets = []
    for word in words:
        if word in ("-a", "--all"):
            everything = True
        elif not word.startswith("-"):
            targets.append(word)
    return everything, targets


# -------------------- wave link --------------------

def handle_link_command(input_string=""):
    everything, targets = parse_targets(input_string)

    if everything:
        targets = installed_packages()
        if not targets:
            print(f"{YELLOW}🌊 No packages installed, nothing to link.{RESET}")
            sys.exit(0)

    if not targets:
        print(f"{RED_BOLD}🌊 Error: Nothing to link. Use 'wave link <name>@latest' or 'wave link --all'.{RESET}")
        sys.exit(1)

    linked = 0
    for target in targets:
        name, _, version = target.partition("@")

        versions = installed_versions(name)
        if not versions:
            print(f"{YELLOW}🌊 Warning: {name} is not installed, skipping.{RESET}")
            continue

        chosen = version
        if not chosen or chosen == "latest":
            chosen = get_max_version(versions)
        elif chosen not in versions:
            print(f"{YELLOW}🌊 Warning: {name}@{chosen} is not installed, skipping.{RESET}")
            continue

        previous = linked_version(name)
        create_link(name, chosen)

        if previous == chosen:
            silent.say(f"🌊 {name} is already linked to {chosen}")
        elif previous:
            silent.say(f"🌊 {name}: re-linked from {previous} to {chosen}")
        else:
            silent.say(f"🌊 {name}: linked to {chosen}")
        linked += 1

    if linked:
        silent.say(f"{GREEN}🌊 Linked {linked} package(s).{RESET}")
    else:
        silent.say(f"{YELLOW}🌊 Nothing was linked.{RESET}")
    sys.exit(0)


# -------------------- wave unlink --------------------

def handle_unlink_command(input_string=""):
    everything, targets = parse_targets(input_string)

    if everything:
        targets = unversioned_links()
        if not targets:
            silent.say(f"{YELLOW}🌊 No unversioned links found, nothing to unlink.{RESET}")
            sys.exit(0)

    if not targets:
        print(f"{RED_BOLD}🌊 Error: Nothing to unlink. Use 'wave unlink <name>' or 'wave unlink --all'.{RESET}")
        sys.exit(1)

    unlinked = 0
    for target in targets:
        name = target.partition("@")[0]
        if remove_link(name):
            silent.say(f"🌊 {name}: unlinked")
            unlinked += 1
        else:
            silent.say(f"{YELLOW}🌊 Warning: {name} has no unversioned link, skipping.{RESET}")

    if unlinked:
        silent.say(f"{GREEN}🌊 Unlinked {unlinked} package(s).{RESET}")
    else:
        silent.say(f"{YELLOW}🌊 Nothing was unlinked.{RESET}")
    sys.exit(0)


# -------------------- wave linkquery --------------------

def handle_linkquery_command(input_string=""):
    # 查询不带版本号的链接当前指向哪个版本：wave linkquery ffmpeg -> 🌊 ffmpeg@9.0
    everything, targets = parse_targets(input_string)

    if everything:
        targets = unversioned_links()
        if not targets:
            print(f"{YELLOW}🌊 No unversioned links found.{RESET}")
            sys.exit(0)

    if not targets:
        print(f"{RED_BOLD}🌊 Error: Missing package name. Use 'wave linkquery <name>' or 'wave linkquery --all'.{RESET}")
        sys.exit(1)

    missing = 0
    for target in targets:
        name = target.partition("@")[0]
        version = linked_version(name)
        if version is None:
            print(f"{YELLOW}🌊 {name} is not linked.{RESET}")
            missing += 1
        elif version not in installed_versions(name):
            print(f"{RED_BOLD}🌊 Error: {name} points to {name}@{version}, which is not installed.{RESET}")
            missing += 1
        else:
            print(f"🌊 {name}@{version}")

    sys.exit(1 if missing else 0)


# -------------------- 直接运行 --------------------

def main():
    words = sys.argv[1:]
    if words and words[0] == "link":
        handle_link_command("wave link " + " ".join(words[1:]))
    elif words and words[0] == "unlink":
        handle_unlink_command("wave unlink " + " ".join(words[1:]))
    elif words and words[0] == "linkquery":
        handle_linkquery_command("wave linkquery " + " ".join(words[1:]))

    print(f"{RED_BOLD}🌊 Error: Unknown argument.{RESET}")
    print("🌊 Usage: linker.py link <name>@latest | link --all | unlink <name> | unlink --all | linkquery <name>")
    sys.exit(1)


if __name__ == "__main__":
    main()
