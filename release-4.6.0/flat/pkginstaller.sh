#!/bin/bash

# pkginstaller.sh
# 软件包安装入口：接收 pkginstaller.py 传来的长字符串与依赖列表，
# 把软件包安装到 BASE_DIR/bin/{可执行文件名}@{版本号}/，
# 创建软链接、写入 _DEPS。已装记录不另存文件，见下面第 4 段。
# 具体安装动作复用 surfboard/depsmanager.sh（与依赖安装共用同一套逻辑）。

set -e

# -------------------- 颜色定义 --------------------

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'

# -------------------- 引入通用安装核心 --------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPSMANAGER_SCRIPT="$(dirname "$SCRIPT_DIR")/surfboard/depsmanager.sh"

if [[ ! -f "$DEPSMANAGER_SCRIPT" ]]; then
    echo -e "${RED_BOLD}🌊 Error: depsmanager.sh not found.${RESET}"
    exit 1
fi

source "$DEPSMANAGER_SCRIPT"

# -------------------- 拆解参数 --------------------

INPUT_STR="$1"
DEPS_STR="$2"

# -------------------- 安装软件包本体 --------------------

# 安装形态由索引记录里的 install 字段决定（长字符串第 9 行），缺省 binary；
# 第 4 个参数说明"这是软件包"，整树时才会写 .is_a_tree 并只链 bin/ 下的命令。
# 依赖走 tree 模式，见 surfboard/depsinstaller.sh（那边不传 package）。
lw_install_artifact "$INPUT_STR" "$DEPS_STR" "" "package"

# 4.6 起不再写 pkg/installed.json：里面有哪条记录完全可以从 bin/<名>@<版本>/
# 推导出来，多存一份就多一处会与磁盘不一致的地方（读-改-写还要锁）。

# -------------------- 输出成功 --------------------

echo -e "${GREEN}🌊 Successfully installed ${LW_NAME}@${LW_VERSION}${RESET}"
DISPLAY_DIR="${LW_TARGET_DIR/$HOME/~}"
DISPLAY_LINK="${LW_LINK_PATH/$HOME/~}"
echo "🌊 Binary installed to: $DISPLAY_DIR/$LW_BIN_NAME"
echo "🌊 Link created at: $DISPLAY_LINK"
exit 0
