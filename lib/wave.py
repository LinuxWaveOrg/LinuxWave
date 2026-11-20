#!/usr/bin/env python3

# wave.py

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from configerror import check_environment, check_dependencies
check_environment()
check_dependencies()


# -------------------- 配置与模块路径 --------------------

from configpaths import load_base_dir

BASE_DIR = load_base_dir()
CLI_DIR = BASE_DIR / "cli"
CONFIG_DIR = BASE_DIR / "config"
LIB_DIR = BASE_DIR / "lib"
NET_DIR = BASE_DIR / "net"
PKG_DIR = BASE_DIR / "pkg"
SURFBOARD_DIR = BASE_DIR / "surfboard"

# 逆序 insert 才会得到下面这个顺序：每次 insert(0) 都插在最前面，所以最后插入的
# 排在首位。cli/ 与 config/ 因此压在 lib/ 之上 —— 从旧版本升级上来的树里可能还
# 留着 lib/help.py 之类的旧副本，不能让它们盖住新模块。
for _component in (SURFBOARD_DIR, PKG_DIR, NET_DIR, LIB_DIR, CONFIG_DIR, CLI_DIR):
    sys.path.insert(0, str(_component))
del _component

import silent


# -------------------- 字典定义 --------------------

COMMANDS = {
    "install":    "pkginstaller",
    "upgrade":    "upgrader",
    "uninstall":  "uninstaller",
    "list":       "pkginfohelper",
    "search":     "pkginfohelper",
    "info":       "pkginfohelper",
    "version":    "help",
    "selfupdate": "selfupdate",
    "mirror":     "mirrorinfo",
    "link":       "linker",
    "unlink":     "linker",
    "linkquery":  "linker",
    "shellenv":   "shellenv",
}

ARGUMENTS = {
    "-h":        "help",
    "--help":    "help",
    "-V":        "help",
    "--version": "help",
}


# -------------------- 主调度逻辑 --------------------

def main():
    words = sys.argv[1:]

    # 1. 无任何输入
    if not words:
        from help import print_custom_help
        print_custom_help()
        sys.exit(0)

    # 先算一次静默状态：下面「命令不存在」的分支也要用它，
    # 而 words 的正式剥离发生在 COMMANDS 分支内（那里的 words 才是给 handler 的）。
    #
    # 取首词也从剥离后的副本里取：`wave -s update jq` 里的 -s 是全局旗标，
    # 不该被当成命令名报「unknown command: -s」。
    lead, is_silent, _show_error = silent.strip(words)
    FirstWord = lead[0] if lead else words[0]

    # 2. 参数优先
    if FirstWord in ARGUMENTS:
        if FirstWord in ("-h", "--help"):
            from help import print_custom_help
            print_custom_help()
        elif FirstWord in ("-V", "--version"):
            from help import print_version
            print_version()
        sys.exit(0)

    # 3. 命令分发
    if FirstWord in COMMANDS:
        # `--proxy` 必须对这条命令的**所有**请求生效，不只是下载包体那一步。
        # 做法是把值写进进程环境（HTTPS_PROXY 等），因为 requests（trust_env 默认开）、
        # urllib 与 bash 子脚本里的 curl 都读环境变量 —— 一处生效，全部覆盖。
        # 这一步放在分发之前：任何 handler 及其子进程都继承这份环境。
        from configpaths import apply_proxy_from_command_line
        apply_proxy_from_command_line(words)

        # `-s / --silent`（含 `-sS`）与 `--raw`：剥掉旗标并落到运行期开关。
        # 为什么必须在分发之前、且必须**从 argv 里拿掉**：各 handler 的旗标白名单
        # 里没有它们，留着的话 `wave install jq -s` 会报「illegal option -s」。
        # 哪些命令能用、用错时怎么报，全部由 cli/silent.py 一处决定。
        words = silent.apply(words, FirstWord)

        # `wave <command> -h|--help`：打印该命令自己的用法后退出。
        # 必须在这里拦下：各 handler 的旗标白名单里没有 --help，
        # 否则它会被当作未知旗标忽略（selfupdate 甚至直接开始自更新）。
        if any(word in ("-h", "--help") for word in words[1:]):
            from help import print_command_help
            print_command_help(FirstWord)
            sys.exit(0)

        module_name = COMMANDS[FirstWord]
        full_input = "wave " + " ".join(words)

        if module_name == "pkginstaller":
            from pkginstaller import handle_install
            handle_install(full_input)

        elif module_name == "upgrader":
            from upgrader import handle_upgrade
            handle_upgrade(full_input)

        elif module_name == "uninstaller":
            from uninstaller import handle_uninstall
            handle_uninstall(full_input)

        elif module_name == "pkginfohelper":
            from pkginfohelper import handle_info_command
            handle_info_command(full_input)

        elif module_name == "help":
            from help import print_version
            print_version()

        elif module_name == "selfupdate":
            from selfupdate import handle_selfupdate
            handle_selfupdate(full_input)

        elif module_name == "shellenv":
            # 输出会被 eval，所以只准打 shell 语句：任何提示语都会变成命令
            from shellenv import handle_shellenv
            sys.exit(handle_shellenv())

        elif module_name == "linker":
            from linker import handle_link_command, handle_linkquery_command, handle_unlink_command
            if FirstWord == "link":
                handle_link_command(full_input)
            elif FirstWord == "linkquery":
                handle_linkquery_command(full_input)
            else:
                handle_unlink_command(full_input)

        elif module_name == "mirrorinfo":
            from mirrorinfo import handle_mirror
            handle_mirror(full_input)

        # 预留：query

        sys.exit(0)

    # 4. 未知输入
    from help import print_error_help
    print_error_help()
    sys.exit(1)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        # 下载卡住时用户多半会按 Ctrl-C。默认行为是把整个调用栈打出来，
        # 那对用户毫无用处，也不像一次「正常中止」。
        print("", file=sys.stderr)
        print("🌊 Interrupted. Nothing was installed.", file=sys.stderr)
        sys.exit(130)
    except BrokenPipeError:
        # 例如 `wave list | head`：下游提前关掉管道时安静退出
        sys.exit(0)