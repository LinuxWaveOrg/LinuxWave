#!/usr/bin/env python3

# linker.py

# 软件包的“不带版本号软链接”管理：links/{名称} -> ../bin/{名称}@{版本号}/{名称}
# 只处理软件包（bin/ 下的目录），不碰依赖（deps/ 下的整棵树）。
# 装完软件包后会自动改指到最高版本；早期装的包可以用 `wave link` 补上，
# 用 `wave unlink` 撤掉。

import json
import os
import sys
from pathlib import Path


# -------------------- 颜色定义 --------------------

RED_BOLD = '\033[1;31m'
GREEN = '\033[32m'
YELLOW = '\033[33m'
RESET = '\033[0m'


# -------------------- 配置加载 --------------------

CONFIG_FILE = Path("/opt/macwave_config/config.json")


def load_config():
    if CONFIG_FILE.exists():
        try:
            with open(CONFIG_FILE, 'r') as f:
                base_dir = json.load(f).get("base_dir")
                if base_dir:
                    return Path(base_dir)
        except Exception:
            pass
    print(f"{RED_BOLD}🌊 Error: Configuration file not found or invalid.{RESET}")
    print(f"{RED_BOLD}🌊 Please run the install script again to reinstall MacWave.{RESET}")
    sys.exit(1)


BASE_DIR = load_config()
BIN_DIR = BASE_DIR / "bin"
LINKS_DIR = BASE_DIR / "links"


# -------------------- 版本库 --------------------

try:
    from pkgversionparser import get_max_version
except ImportError:
    print(f"{RED_BOLD}🌊 Error: 'pkgversionparser' module is not available.{RESET}")
    sys.exit(1)


# -------------------- 安装状态查询 --------------------

def installed_versions(name):
    # bin/{名称}@{版本号}/ 里的版本号列表（名称即 `wave list` 显示的那个）
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


def linked_version(name):
    # links/{名称} 当前指向哪个版本；没链接、或指向别的名字时返回 None
    link = LINKS_DIR / name
    if not link.is_symlink():
        return None

    target = os.readlink(link)
    target_name = os.path.basename(target)
    directory = os.path.basename(os.path.dirname(target))
    if target_name != name or "@" not in directory:
        return None

    dir_name, _, version = directory.partition("@")
    return version if dir_name == name else None


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

def create_link(name, version):
    # 建立或重指 links/{名称}；已存在（含悬空链接）先删掉再建
    LINKS_DIR.mkdir(parents=True, exist_ok=True)

    link = LINKS_DIR / name
    if link.is_symlink() or link.exists():
        link.unlink()

    link.symlink_to(f"../bin/{name}@{version}/{name}")
    return link


def remove_link(name):
    link = LINKS_DIR / name
    if link.is_symlink() or link.exists():
        link.unlink()
        return True
    return False


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
            print(f"🌊 {name} is already linked to {chosen}")
        elif previous:
            print(f"🌊 {name}: re-linked from {previous} to {chosen}")
        else:
            print(f"🌊 {name}: linked to {chosen}")
        linked += 1

    if linked:
        print(f"{GREEN}🌊 Linked {linked} package(s).{RESET}")
    else:
        print(f"{YELLOW}🌊 Nothing was linked.{RESET}")
    sys.exit(0)


# -------------------- wave unlink --------------------

def handle_unlink_command(input_string=""):
    everything, targets = parse_targets(input_string)

    if everything:
        targets = unversioned_links()
        if not targets:
            print(f"{YELLOW}🌊 No unversioned links found, nothing to unlink.{RESET}")
            sys.exit(0)

    if not targets:
        print(f"{RED_BOLD}🌊 Error: Nothing to unlink. Use 'wave unlink <name>' or 'wave unlink --all'.{RESET}")
        sys.exit(1)

    unlinked = 0
    for target in targets:
        name = target.partition("@")[0]
        if remove_link(name):
            print(f"🌊 {name}: unlinked")
            unlinked += 1
        else:
            print(f"{YELLOW}🌊 Warning: {name} has no unversioned link, skipping.{RESET}")

    if unlinked:
        print(f"{GREEN}🌊 Unlinked {unlinked} package(s).{RESET}")
    else:
        print(f"{YELLOW}🌊 Nothing was unlinked.{RESET}")
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
        if version:
            print(f"🌊 {name}@{version}")
        else:
            print(f"{YELLOW}🌊 {name} is not linked.{RESET}")
            missing += 1

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
