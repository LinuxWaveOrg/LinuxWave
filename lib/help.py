#!/usr/bin/env python3
"""
MacWave Help Module
负责展示命令行帮助信息（简版和详细版）。
"""

import json
from pathlib import Path

# 颜色定义
RED = '\033[31m'
GREEN = '\033[32m'
YELLOW = '\033[33m'
CYAN = '\033[36m'
RESET = '\033[0m'
BOLD = '\033[1m'
PURPLE = '\033[35m'
ORANGE = '\033[38;5;197m'

VERSION_FILE = Path("/opt/macwave_config/VERSION.json")

def get_project_version():
    """从 VERSION.json 获取主程序版本号"""
    if VERSION_FILE.exists():
        try:
            with open(VERSION_FILE, 'r') as f:
                data = json.load(f)
                return data.get("version", "unknown")
        except Exception:
            pass
    return "unknown"


def print_custom_help():
    """简版帮助：与 README 的 Command Reference 保持一致"""
    version = get_project_version()
    print(f"{PURPLE}usage: {ORANGE}wave <command> [package] [flags]{RESET}")
    print()
    print(f"MacWave {version} 🌊")
    print("A package manager for macOS software developers.")
    print()
    print(f"{PURPLE}Commands:{RESET}")
    print(f"  {GREEN}install{RESET}               Install a package (latest version)")
    print(f"  {GREEN}uninstall{RESET}             Uninstall a package")
    print(f"  {GREEN}list{RESET}                  List installed packages")
    print(f"  {GREEN}search{RESET}                Search for a package in the index")
    print(f"  {GREEN}info{RESET}                  Display detailed information about a package")
    print(f"  {GREEN}selfupdate{RESET}            Update MacWave itself to the latest version")
    print(f"  {GREEN}link{RESET}                  Link installed packages without a version number")
    print(f"  {GREEN}unlink{RESET}                Remove those unversioned links")
    print(f"  {GREEN}linkquery{RESET}             Show which version an unversioned link points to")
    print()
    print(f"{PURPLE}Flags:{RESET}")
    print(f"  {GREEN}-h, --help{RESET}            Show help for any command")
    print(f"  {GREEN}-V, --version{RESET}         Print version information")
    print(f"  {GREEN}-v, --verbose{RESET}         Enable verbose output (show detailed logs)")
    print()
    print(f"{PURPLE}Global Flags (can be used with any command):{RESET}")
    print(f"  {GREEN}-C, --continue{RESET}        Resume interrupted downloads (like curl -C -)")
    print(f"  {CYAN}--proxy{RESET} {YELLOW}string{RESET}        Specify an HTTP/HTTPS proxy (e.g., http://127.0.0.1:8080)")
    print(f"  {CYAN}--skip-ssl{RESET}            Skip SSL certificate verification (insecure)")
    print(f"  {CYAN}--limit-rate{RESET} {YELLOW}string{RESET}   Limit download speed (e.g., 200K, 1M, 5M)")
    print(f"  {CYAN}--ver{RESET} {YELLOW}string{RESET}          Install a specific version of the package")
    print()
    print(f"{PURPLE}Special Flags:{RESET}")
    print(f"  {GREEN}wave install <pkgname>@<version>{RESET}   Download certain version(s) of a package")
    print(f"  {CYAN}--unlink{RESET}                         Skip the unversioned link when installing or uninstalling")
    print(f"  {CYAN}--all, -a{RESET}                        Apply to every installed package (link / unlink / linkquery)")
    print()
    print(f"{PURPLE}Unversioned Links:{RESET}")
    print(f"  {GREEN}wave link <name>{RESET}                 Link a package to its highest installed version")
    print(f"  {GREEN}wave linkquery <name>{RESET}            Show what <name> is linked to (e.g. 🌊 ffmpeg@9.0)")
    print(f"  {GREEN}wave unlink <name>{RESET}               Remove that link")
    print()
    print("For more details, visit: https://macwave.org")


# -------------------- 版本与错误提示 --------------------

def print_version():
    """输出当前 MacWave 的版本号"""
    version = get_project_version()
    print(f"🌊 MacWave {version}")


def print_error_help():
    """未知命令或参数时：先报错，再输出完整帮助"""
    print(f"{BOLD}{RED}🌊 Error: Unknown command or argument.{RESET}")
    print()
    print_custom_help()


def main():
    """直接运行 python3 help.py 时，预览帮助信息"""
    print_custom_help()


if __name__ == "__main__":
    main()
