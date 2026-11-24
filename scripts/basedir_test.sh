#!/bin/bash

# basedir_test.sh
# `wave basedir` 的三条不变量：
#
#   1. 默认输出带 🌊，家目录里的路径折成 ~（人看的那份要短）；
#   2. `--raw` 输出**原样**的绝对路径 —— 不折 ~，因为 `~` 只在词首、未加引号时
#      才展开，`cd "$(wave basedir --raw)"` 会把它当字面量；
#   3. 家目录之外不折。
#
# 另外钉住两条拒绝：未知旗标指向 --help；`-s/--silent` 不许用在 basedir 上
# （这条命令存在的意义就是输出，静默它等于把命令废掉）。
#
# 自带隔离：LINUXWAVE_TEST 临时根，全程不碰真实安装。

set -u

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PYTHON=${PYTHON:-python3}

PASSED=0
FAILED=0
pass() { echo -e "  ${GREEN}✅ $1${RESET}"; PASSED=$((PASSED + 1)); }
fail() { echo -e "  ${RED_BOLD}❌ $1${RESET}"; FAILED=$((FAILED + 1)); }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/basedir_test.XXXXXX")
WORK=$(cd "$WORK" && pwd -P)
trap 'rm -rf "$WORK"' EXIT

REAL_HOME="$HOME"
ROOT="$WORK/root"
HOME1="$ROOT$REAL_HOME"
BASE="$HOME1/.local/linuxwave"
mkdir -p "$HOME1/.config/linuxwave_config" "$BASE"
for component in cli config lib net pkg surfboard; do
    ln -sfn "$REPO_DIR/$component" "$BASE/$component"
done
printf '{"base_dir": "%s"}\n' "$BASE" > "$HOME1/.config/linuxwave_config/config.json"

run_wave() { LINUXWAVE_TEST="$ROOT" "$PYTHON" "$REPO_DIR/lib/wave.py" "$@"; }

echo "========== 1. 家目录里的安装：默认折成 ~ =========="

OUT="$(run_wave basedir 2>&1)"
case "$OUT" in
    *"~/"*) pass "默认输出把家目录折成 ~" ;;
    *) fail "默认输出没有折 ~：$(printf '%.160s' "$OUT")" ;;
esac
[[ "$OUT" == 🌊* ]] && pass "默认输出带 🌊" || fail "默认输出没有 🌊：$(printf '%.80s' "$OUT")"

echo "========== 2. --raw 打原样绝对路径 =========="

RAW="$(run_wave basedir --raw 2>&1)"
[[ "$RAW" == "$BASE" ]] && pass "--raw 输出绝对路径，不折 ~" \
    || fail "--raw 输出不对：$(printf '%.200s' "$RAW")"
[[ "$RAW" != *"🌊"* ]] && pass "--raw 不含 🌊" || fail "--raw 里还有 🌊"

echo "========== 3. 拒绝 =========="

OUT="$(run_wave basedir -s 2>&1)"; RC=$?
[[ "$RC" -ne 0 ]] && pass "-s 被拒绝" || fail "-s 被接受了（rc=$RC）"
OUT="$(run_wave basedir --bogus 2>&1)"; RC=$?
[[ "$RC" -ne 0 && "$OUT" == *"--help"* ]] \
    && pass "未知旗标被拒绝并指向 --help" || fail "未知旗标：rc=$RC $(printf '%.160s' "$OUT")"

echo
echo "=========================================="
echo -e "🌊 Passed: $PASSED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="
[[ "$FAILED" -eq 0 ]] || exit 1
echo -e "${GREEN}🌊 All basedir tests passed${RESET}"
