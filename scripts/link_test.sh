#!/bin/bash

# link_test.sh
# 不带版本号软链接的回归测试：
#   装完自动链接 → 不带版本号能跑 → link / unlink / linkquery → link -a / unlink -a
#   → 卸载最高版自动降级 → uninstall --unlink 不降级 → install --unlink 不建链接
#   → 卸掉最后一个版本时删掉链接

set -e

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
WAVE_BIN="$REPO_DIR/lib/wave.py"

if [[ ! -f "$WAVE_BIN" ]]; then
    echo -e "${RED_BOLD}🌊 Error: wave.py not found at $WAVE_BIN${RESET}"
    exit 1
fi

CONFIG_FILE="/opt/macwave_config/config.json"
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${RED_BOLD}🌊 Error: MacWave not installed (config not found).${RESET}"
    exit 1
fi

BASE_DIR=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE'))['base_dir'])")
BIN_DIR="$BASE_DIR/bin"
LINKS_DIR="$BASE_DIR/links"

PKG="test_bin_no_ext"
VER="1.0"
UNV="$LINKS_DIR/$PKG"
ZIP_PKG="test_bin_zip"
ZIP_VER="1.0"

FAILED=0
PASSED=0

pass() {
    echo -e "${GREEN}🌊 PASS: $1${RESET}"
    PASSED=$((PASSED + 1))
}

fail() {
    echo -e "${RED_BOLD}🌊 FAIL: $1${RESET}"
    FAILED=$((FAILED + 1))
}

# check <描述> <实际> <期望>
check() {
    if [[ "$2" == "$3" ]]; then
        pass "$1"
    else
        fail "$1 (expected '$3', got '$2')"
    fi
}

link_state() {
    if [[ -L "$1" ]]; then echo yes; else echo no; fi
}

unversioned_count() {
    ls "$LINKS_DIR" 2>/dev/null | grep -v '@' | wc -l | tr -d ' '
}

cleanup() {
    python3 "$WAVE_BIN" uninstall "$PKG@2.0" >/dev/null 2>&1 || true
    python3 "$WAVE_BIN" uninstall "$PKG@$VER" >/dev/null 2>&1 || true
    python3 "$WAVE_BIN" uninstall "$ZIP_PKG@$ZIP_VER" >/dev/null 2>&1 || true
    rm -f "$UNV" "$LINKS_DIR/$PKG@2.0" "$LINKS_DIR/$ZIP_PKG"
    rm -rf "$BIN_DIR/$PKG@2.0"
}

trap cleanup EXIT
cleanup

echo ""
echo "========== 1. 装完自动建不带版本号的链接 =========="
python3 "$WAVE_BIN" install "$PKG@$VER" >/dev/null
check "install 后 $PKG 链接存在" "$(link_state "$UNV")" "yes"
check "linkquery 报告 $PKG@$VER" "$(python3 "$WAVE_BIN" linkquery "$PKG")" "🌊 $PKG@$VER"
RUN_OUTPUT=$("$UNV")
check "不带版本号也能跑" "$([[ "$RUN_OUTPUT" == *"Test Successful! (no-extension)"* ]] && echo yes || echo no)" "yes"

echo ""
echo "========== 2. unlink 与 link =========="
python3 "$WAVE_BIN" unlink "$PKG" >/dev/null
check "unlink 后链接消失" "$(link_state "$UNV")" "no"
python3 "$WAVE_BIN" link "$PKG" >/dev/null
check "link 后链接恢复" "$(link_state "$UNV")" "yes"
check "重复 link 不改指向" "$(python3 "$WAVE_BIN" linkquery "$PKG")" "🌊 $PKG@$VER"

echo ""
echo "========== 3. -a / --all =========="
VERSIONED_BEFORE=$(ls "$LINKS_DIR" | grep -c '@' || true)
python3 "$WAVE_BIN" unlink -a >/dev/null
check "unlink -a 清空无版本号链接" "$(unversioned_count)" "0"
check "unlink -a 不动带版本号的链接" "$(ls "$LINKS_DIR" | grep -c '@' || true)" "$VERSIONED_BEFORE"
python3 "$WAVE_BIN" link -a >/dev/null
check "link -a 后仍指向 $PKG@$VER" "$(python3 "$WAVE_BIN" linkquery "$PKG")" "🌊 $PKG@$VER"
check "link -a 不动带版本号的链接" "$(ls "$LINKS_DIR" | grep -c '@' || true)" "$VERSIONED_BEFORE"

# 造一个同包的更高版本：直接复制已装目录 + 补版本号软链接（避免依赖 infosource 里真有 2.0）
echo ""
echo "========== 4. 卸载最高版时自动降级 =========="
cp -R "$BIN_DIR/$PKG@$VER" "$BIN_DIR/$PKG@2.0"
ln -sfn "../bin/$PKG@2.0/$PKG" "$LINKS_DIR/$PKG@2.0"
python3 "$WAVE_BIN" link "$PKG@2.0" >/dev/null
check "已链到最高版 2.0" "$(python3 "$WAVE_BIN" linkquery "$PKG")" "🌊 $PKG@2.0"
python3 "$WAVE_BIN" uninstall "$PKG@2.0" >/dev/null
check "卸载 2.0 后降到 $VER" "$(python3 "$WAVE_BIN" linkquery "$PKG")" "🌊 $PKG@$VER"

echo ""
echo "========== 5. uninstall --unlink 不降级 =========="
cp -R "$BIN_DIR/$PKG@$VER" "$BIN_DIR/$PKG@2.0"
ln -sfn "../bin/$PKG@2.0/$PKG" "$LINKS_DIR/$PKG@2.0"
python3 "$WAVE_BIN" link "$PKG@2.0" >/dev/null
python3 "$WAVE_BIN" uninstall "$PKG@2.0" --unlink >/dev/null
check "--unlink 后仍指向 2.0（不降级）" "$(python3 "$WAVE_BIN" linkquery "$PKG")" "🌊 $PKG@2.0"

echo ""
echo "========== 6. install --unlink 不建链接 =========="
python3 "$WAVE_BIN" install "$ZIP_PKG@$ZIP_VER" --unlink >/dev/null
check "$ZIP_PKG 目录已装好" "$([[ -d "$BIN_DIR/$ZIP_PKG@$ZIP_VER" ]] && echo yes || echo no)" "yes"
check "install --unlink 未建无版本号链接" "$(link_state "$LINKS_DIR/$ZIP_PKG")" "no"

echo ""
echo "========== 7. 卸掉最后一个版本时删掉链接 =========="
python3 "$WAVE_BIN" uninstall "$PKG@$VER" >/dev/null
check "已无版本可指向，链接被删除" "$(link_state "$UNV")" "no"

set +e
python3 "$WAVE_BIN" linkquery "$PKG" >/dev/null 2>&1
QUERY_EXIT=$?
set -e
check "linkquery 未链接时退出码为 1" "$QUERY_EXIT" "1"

echo ""
echo "=========================================="
echo "🌊 Passed: $PASSED"
echo "🌊 Failed: $FAILED"
echo "=========================================="

if [[ "$FAILED" -gt 0 ]]; then
    exit 1
fi

exit 0
