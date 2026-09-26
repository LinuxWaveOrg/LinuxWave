#!/bin/bash

# pkgunzip.sh - 负责解压预编译软件包（压缩包）
# 用法: bash pkgunzip.sh <压缩包路径> <解压目录>

set -e

# 颜色定义
RED_BOLD='\033[1;31m'
RESET='\033[0m'

ARCHIVE_PATH="$1"
EXTRACT_DIR="$2"

if [[ -z "$ARCHIVE_PATH" || -z "$EXTRACT_DIR" ]]; then
    echo -e "${RED_BOLD}🌊 Error: Missing archive path or extract directory.${RESET}"
    exit 1
fi

if [[ ! -f "$ARCHIVE_PATH" ]]; then
    echo -e "${RED_BOLD}🌊 Error: Archive file not found: $ARCHIVE_PATH${RESET}"
    exit 1
fi

# 确保解压目录存在
mkdir -p "$EXTRACT_DIR"

# 根据文件后缀选择解压命令
case "$ARCHIVE_PATH" in
    *.zip)
        unzip -q "$ARCHIVE_PATH" -d "$EXTRACT_DIR"
        ;;
    *.tar.gz|*.tgz)
        tar -xzf "$ARCHIVE_PATH" -C "$EXTRACT_DIR"
        ;;
    *.tar.bz2|*.tbz2)
        tar -xjf "$ARCHIVE_PATH" -C "$EXTRACT_DIR"
        ;;
    *.tar.xz|*.txz)
        tar -xJf "$ARCHIVE_PATH" -C "$EXTRACT_DIR"
        ;;
    *.tar)
        tar -xf "$ARCHIVE_PATH" -C "$EXTRACT_DIR"
        ;;
    *.gz)
        gzip -dk "$ARCHIVE_PATH" -c > "$EXTRACT_DIR/$(basename "${ARCHIVE_PATH%.gz}")"
        ;;
    *.bz2)
        bzip2 -dk "$ARCHIVE_PATH" -c > "$EXTRACT_DIR/$(basename "${ARCHIVE_PATH%.bz2}")"
        ;;
    *.xz)
        # macOS 不自带 xz 命令，改用 Python 标准库 lzma（裸 .xz，非 .tar.xz）
        python3 - "$ARCHIVE_PATH" "$EXTRACT_DIR/$(basename "${ARCHIVE_PATH%.xz}")" << 'PYEOF'
import lzma
import shutil
import sys

with lzma.open(sys.argv[1], 'rb') as source, open(sys.argv[2], 'wb') as target:
    shutil.copyfileobj(source, target)
PYEOF
        ;;
    *)
        echo -e "${RED_BOLD}🌊 Error: Unsupported archive format: $ARCHIVE_PATH${RESET}"
        exit 1
        ;;
esac

echo "🌊 Extraction successful!"
exit 0
