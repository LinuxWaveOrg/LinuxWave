#!/usr/bin/env python3

# configpaths.py
# 解析 MacWave 的配置目录。
#
# 安装目录决定配置写在哪：
#   - 系统级（/opt/macwave、/usr/local/macwave 等需要 sudo 的目录）
#     → /opt/macwave_config
#   - 用户级（~/.local/macwave 等无需 sudo 的目录）
#     → ~/.config/macwave_config
#
# 读取时系统级优先：只要 /opt/macwave_config/config.json 存在就用它，
# 否则才回落到 ~/.config/macwave_config —— 也就是优先跑系统级的 MacWave。

import json
import sys
from pathlib import Path


# -------------------- 颜色定义 --------------------

RED_BOLD = '\033[1;31m'
RESET = '\033[0m'


# -------------------- 配置目录候选 --------------------

CONFIG_FILE_NAME = "config.json"
VERSION_FILE_NAME = "VERSION.json"

SYSTEM_CONFIG_DIR = Path("/opt/macwave_config")
USER_CONFIG_DIR = Path.home() / ".config" / "macwave_config"


def config_dir_candidates():
    # 系统级优先，其次用户级
    return [SYSTEM_CONFIG_DIR, USER_CONFIG_DIR]


# -------------------- 配置读取 --------------------

def _read_base_dir(config_file):
    # 读得到合法 base_dir 就返回 Path，否则返回 None
    try:
        with open(config_file, 'r') as handle:
            base_dir = json.load(handle).get("base_dir")
        return Path(base_dir) if base_dir else None
    except Exception:
        return None


def find_config_dir():
    # 第一个装了 MacWave 的配置目录（config.json 合法且含 base_dir）；都没装时返回 None
    for directory in config_dir_candidates():
        if _read_base_dir(directory / CONFIG_FILE_NAME) is not None:
            return directory
    return None


def load_base_dir():
    # 按系统级 → 用户级的顺序读取 base_dir，读到就返回
    for directory in config_dir_candidates():
        base_dir = _read_base_dir(directory / CONFIG_FILE_NAME)
        if base_dir is not None:
            return base_dir

    print(f"{RED_BOLD}🌊 Error: Configuration file not found or invalid.{RESET}")
    print(f"{RED_BOLD}🌊 Please run the install script again to reinstall MacWave.{RESET}")
    sys.exit(1)


# -------------------- 当前生效的配置 --------------------

CONFIG_DIR = find_config_dir() or SYSTEM_CONFIG_DIR
CONFIG_FILE = CONFIG_DIR / CONFIG_FILE_NAME
VERSION_FILE = CONFIG_DIR / VERSION_FILE_NAME


if __name__ == "__main__":
    print("🌊 This module is not meant to be run directly.")
    print("🌊 It is used internally by the other MacWave modules.")
    sys.exit(1)
