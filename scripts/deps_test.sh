#!/bin/bash

# deps_test.sh
# 端到端依赖回归：对每一个声明了 deps 的包，各自跑一遍
#   安装（拉下整条依赖链）→ 运行二进制 → 确认没有未解析的库引用
#   → 依赖边审计 → 检查引用计数标记 → 卸载 → 确认依赖目录与软链接被级联清理
#
# 不给包参数时自动发现：扫 infosource 数据里所有声明了 deps 的包，各取最高版本，
# 测试夹具（test_*）除外。所以新增一个带依赖的包，这里自动就覆盖了 —— 不必再
# 手工往清单里加名字（这是它以前只测 wget 的原因）。
#
# 用法:
#   bash scripts/deps_test.sh                     # 全部带依赖的包
#   bash scripts/deps_test.sh wget@1.25.0         # 只测一个
#   bash scripts/deps_test.sh --data-dir DIR      # 指定 infosource 检出目录

set -e

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
WAVE_BIN="$REPO_DIR/lib/wave.py"

DATA_DIR=""
REQUESTED=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --data-dir)
            DATA_DIR="${2:-}"
            shift 2
            ;;
        --data-dir=*)
            DATA_DIR="${1#*=}"
            shift
            ;;
        -h|--help)
            echo "Usage: bash scripts/deps_test.sh [--data-dir DIR] [package[@version] ...]"
            exit 0
            ;;
        *)
            REQUESTED+=("$1")
            shift
            ;;
    esac
done

if [[ ! -f "$WAVE_BIN" ]]; then
    echo -e "${RED_BOLD}🌊 Error: wave.py not found at $WAVE_BIN${RESET}"
    exit 1
fi

# 数据目录：显式参数 > 仓库根的 infosource-data > 上一层的 infosource-data
# （CI 把 infosource 检出到仓库根的 infosource-data；本机开发克隆常放在上一层）
if [[ -z "$DATA_DIR" ]]; then
    for candidate in "$REPO_DIR/infosource-data" "$REPO_DIR/../infosource-data"; do
        if [[ -d "$candidate/pkg" ]]; then
            DATA_DIR="$candidate"
            break
        fi
    done
fi

ARCH="$(python3 -c 'import platform; m = platform.machine().lower(); print("arm64" if m in ("arm64", "aarch64") else "amd64")')"

# 配置目录：系统级优先，其次用户级
if [[ -f /etc/linuxwave_config/config.json ]]; then
    CONFIG_FILE="/etc/linuxwave_config/config.json"
elif [[ -f "$HOME/.config/linuxwave_config/config.json" ]]; then
    CONFIG_FILE="$HOME/.config/linuxwave_config/config.json"
else
    echo -e "${RED_BOLD}🌊 Error: LinuxWave not installed (config not found).${RESET}"
    exit 1
fi

BASE_DIR=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE'))['base_dir'])")
BIN_DIR="$BASE_DIR/bin"
LINKS_DIR="$BASE_DIR/links"
DEPS_DIR="$BASE_DIR/deps"

FAILED=0
CHECKED=0

# ==========================================
# 要测哪些包
# ==========================================

if [[ ${#REQUESTED[@]} -gt 0 ]]; then
    PKGS=("${REQUESTED[@]}")
else
    if [[ -z "$DATA_DIR" ]]; then
        echo -e "${RED_BOLD}🌊 Error: infosource data not found; pass --data-dir.${RESET}"
        exit 1
    fi

    mapfile -t PKGS < <(python3 - "$DATA_DIR" "$ARCH" <<'PY'
import pathlib
import re
import sys

data_dir, arch = sys.argv[1], sys.argv[2]

try:
    from packaging.version import parse as version_parse

    def newer(candidate, current):
        try:
            return version_parse(candidate) > version_parse(current)
        except Exception:
            return candidate > current
except ImportError:
    def _parts(value):
        return [int(p) if p.isdigit() else 0 for p in re.split(r'[._-]', value)]

    def newer(candidate, current):
        return _parts(candidate) > _parts(current)

root = pathlib.Path(data_dir) / "pkg" / f"pkginfo_{arch}"
if not root.is_dir():
    print(f"no package data at {root}", file=sys.stderr)
    sys.exit(1)

best = {}
for pkg_dir in sorted(root.iterdir()):
    if not pkg_dir.is_dir():
        continue
    name = pkg_dir.name
    # 测试夹具（test_001 / test_bin_* / test_no_sha256 …）不是真实软件包
    if name.startswith("test_"):
        continue
    for version_file in sorted(pkg_dir.glob(f"_{name}@[0-9]*")):
        version = version_file.name.split("@", 1)[1]
        try:
            text = version_file.read_text(errors="replace")
        except OSError:
            continue
        # deps 是多行续行字段，但字段名一定在行首，按行首匹配即可
        if not re.search(r'^deps:', text, re.M):
            continue
        if name not in best or newer(version, best[name]):
            best[name] = version

for name in sorted(best):
    print(f"{name}@{best[name]}")
PY
    )
fi

if [[ ${#PKGS[@]} -eq 0 ]]; then
    echo -e "${RED_BOLD}🌊 Error: no dependency-bearing package found.${RESET}"
    exit 1
fi

echo "🌊 Testing ${#PKGS[@]} dependency-bearing package(s) on $ARCH:"
for pkg in "${PKGS[@]}"; do
    echo "     $pkg"
done

# ==========================================
# 逐个跑完整循环
# ==========================================

for PKG in "${PKGS[@]}"; do
    echo ""
    echo "========== $PKG =========="
    CHECKED=$((CHECKED + 1))

    LOG_FILE="$(mktemp)"

    # 1. 安装（会把整条依赖链拉下来）
    echo "---------- install $PKG ----------"
    INSTALL_RC=0
    python3 "$WAVE_BIN" install "$PKG" > "$LOG_FILE" 2>&1 || INSTALL_RC=$?
    cat "$LOG_FILE"

    if [[ "$INSTALL_RC" -ne 0 ]]; then
        echo -e "${RED_BOLD}🌊 FAIL: install $PKG${RESET}"
        FAILED=$((FAILED + 1))
        rm -f "$LOG_FILE"
        continue
    fi

    # 2. 二进制要能真正跑起来（relink 漏改会在这里以 ld.so 报错暴露）
    echo "---------- run $PKG ----------"
    if "$LINKS_DIR/$PKG" --version > /dev/null 2>&1; then
        echo -e "${GREEN}🌊 OK: $PKG --version${RESET}"
    else
        echo -e "${RED_BOLD}🌊 FAIL: $PKG --version${RESET}"
        FAILED=$((FAILED + 1))
    fi

    # 3. 依赖里的动态库引用不能有未解析项
    if grep -qE 'could not be linked|not provided by any installed dependency' "$LOG_FILE"; then
        echo -e "${RED_BOLD}🌊 FAIL: unresolved library references${RESET}"
        grep -E 'could not be linked|not provided by any installed dependency' "$LOG_FILE"
        FAILED=$((FAILED + 1))
    fi

    # 4. 依赖边审计：拿数据里的声明与真实落盘的库对照，
    #    漏声明/多余声明都会在这里报出来（安装日志里查不到，因为 ld.so 会兜底到系统库）
    echo "---------- audit edges $PKG ----------"
    EDGE_OUT="$(python3 "$REPO_DIR/scripts/audit_deps.py" edges \
        --data-dir "$DATA_DIR" --base-dir "$BASE_DIR" --arch "$ARCH" 2>&1)" || EDGE_RC=$?
    EDGE_RC="${EDGE_RC:-0}"
    printf '%s\n' "$EDGE_OUT" | tail -20
    if [[ "$EDGE_RC" -ne 0 ]]; then
        echo -e "${RED_BOLD}🌊 FAIL: dependency edge audit${RESET}"
        FAILED=$((FAILED + 1))
    fi

    # 5. 引用计数标记必须写出来
    MARKERS=$(find "$DEPS_DIR" -name '.depped_*' 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$MARKERS" -eq 0 ]]; then
        echo -e "${RED_BOLD}🌊 FAIL: no .depped_* marker was written${RESET}"
        FAILED=$((FAILED + 1))
    else
        echo "🌊 Found $MARKERS marker(s)"
    fi

    # 6. 卸载，整条依赖链应被级联清理
    echo "---------- uninstall $PKG ----------"
    python3 "$WAVE_BIN" uninstall "$PKG" > /dev/null 2>&1 || true

    if [[ -e "$BIN_DIR/$PKG" || -e "$LINKS_DIR/$PKG" ]]; then
        echo -e "${RED_BOLD}🌊 FAIL: $PKG was left behind${RESET}"
        FAILED=$((FAILED + 1))
    fi

    REMAINING=$(find "$DEPS_DIR" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$REMAINING" -ne 0 ]]; then
        echo -e "${RED_BOLD}🌊 FAIL: $REMAINING dependency dir(s) left behind${RESET}"
        find "$DEPS_DIR" -mindepth 2 -maxdepth 2 -type d
        FAILED=$((FAILED + 1))
    fi

    rm -f "$LOG_FILE"
done

# ==========================================
# 结果
# ==========================================

echo ""
if [[ "$FAILED" -gt 0 ]]; then
    echo -e "${RED_BOLD}🌊 Dependency test failed: $FAILED check(s) across $CHECKED package(s)${RESET}"
    exit 1
fi

echo -e "${GREEN}🌊 Dependency test passed ($CHECKED package(s))${RESET}"
