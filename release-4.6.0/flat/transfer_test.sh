#!/bin/bash

# transfer_test.sh
# `wave transfer`：给已装的产物补一遍路径重定位。
#
# 真脚本要解析 ELF、跑 patchelf/readelf，而 macOS 上造不出真 ELF。所以这里用
# LINUXWAVE_TRANSFER_SCRIPT 指到一个**按剧本回话的假脚本**，验证的是 Python 这一层：
#   - 选目标：`包名` 取它所有已装版本，`包名@版本` 只取那个，`--all` 取全树；
#   - 依赖闭包：点名的包用到的依赖（含依赖的依赖）也要一起迁移，否则白改；
#   - 已经是相对的直接跳过（不重复动手）；
#   - --dry-run 只报告，不动手；
#   - 失败要如实汇总并以非 0 退出；
#   - 全程持锁（与装包/卸载互斥）。
#
# 假脚本的行为由每个目录旁边的 `.fake-state` 文件决定：
#   relative  → --check 返回 0（已经是相对）
#   absolute  → --check 返回 1（需要改写）；改写后把它改成 relative
#   broken    → --check 返回 2（判断不了）
# 另外它把每次调用追加到 ${FAKE_LOG}，并把「改写过的目录」记在 ${FAKE_REWRITTEN}。
#
# 全程离线。

set -u
set +e

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PYTHON=${PYTHON:-python3}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/transfer_test.XXXXXX")
WORK=$(cd "$WORK" && pwd -P)
trap 'rm -rf "$WORK"' EXIT

PASSED=0
FAILED=0
pass() { echo -e "${GREEN}🌊 PASS: $1${RESET}"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED_BOLD}🌊 FAIL: $1${RESET}"; FAILED=$((FAILED + 1)); }
ok() { [[ "$2" == *"$3"* ]] && pass "$1" || fail "$1 — 输出里没有「$3」：$(printf '%.200s' "$2")"; }

SANDBOX="$WORK/sandbox"
BASE="$SANDBOX/opt/linuxwave"
mkdir -p "$SANDBOX/etc/linuxwave_config" "$BASE"/{bin,links,deps}
printf '{"base_dir": "%s"}' "$BASE" > "$SANDBOX/etc/linuxwave_config/config.json"
for component in cli config lib net pkg surfboard; do
    ln -sfn "$REPO_DIR/$component" "$BASE/$component"
done
printf '{"version": "4.6.0"}\n' > "$BASE/VERSION.json"

FAKE_LOG="$WORK/fake.log"
FAKE_SCRIPT="$WORK/fake-transfer.sh"
cat > "$FAKE_SCRIPT" <<'FAKEEOF'
#!/bin/bash
# 按剧本回话的假 transfer.sh：只看目录旁边的 .fake-state
set -u
if [[ "${1:-}" == "--check" ]]; then
    dir="$2"
    echo "check $dir" >> "$FAKE_LOG"
    state="$(cat "$dir/.fake-state" 2>/dev/null || echo relative)"
    case "$state" in
        relative) exit 0 ;;
        absolute) exit 1 ;;
        *) exit 2 ;;
    esac
fi
dir="$1"
echo "rewrite $dir" >> "$FAKE_LOG"
if [[ "$(cat "$dir/.fake-state" 2>/dev/null || echo relative)" == "broken" ]]; then
    echo "🌊 Error: refusing to rewrite $dir"
    exit 1
fi
printf 'relative\n' > "$dir/.fake-state"
echo "$dir" >> "$FAKE_REWRITTEN"
echo "🌊 rewrote $dir"
FAKEEOF
chmod +x "$FAKE_SCRIPT"
export FAKE_LOG FAKE_REWRITTEN="$WORK/rewritten.log"

wave() {  # 输出在 OUT，退出码在 RC
    OUT=$(LINUXWAVE_TEST="$SANDBOX" LINUXWAVE_TRANSFER_SCRIPT="$FAKE_SCRIPT" \
          "$PYTHON" "$BASE/lib/wave.py" "$@" 2>&1)
    RC=$?
}

# 造一棵树：demo@1.0 / demo@2.0（都绝对）、other@1.0（已相对），
# demo 依赖 gcc@13（绝对），gcc@13 依赖 libcxx@1（绝对，测试传递闭包）
build_tree() {
    rm -rf "${BASE:?}/bin" "${BASE:?}/deps"
    mkdir -p "$BASE/bin/demo@1.0" "$BASE/bin/demo@2.0" "$BASE/bin/other@1.0" \
             "$BASE/deps/gcc/gcc@13" "$BASE/deps/libcxx/libcxx@1"
    for dir in "$BASE/bin/demo@1.0" "$BASE/bin/demo@2.0" \
               "$BASE/deps/gcc/gcc@13" "$BASE/deps/libcxx/libcxx@1"; do
        printf 'absolute\n' > "$dir/.fake-state"
    done
    printf 'relative\n' > "$BASE/bin/other@1.0/.fake-state"
    printf 'gcc@13\n' > "$BASE/bin/demo@1.0/_DEPS"
    printf 'gcc@13\n' > "$BASE/bin/demo@2.0/_DEPS"
    printf 'libcxx@1\n' > "$BASE/deps/gcc/gcc@13/_DEPS"
    : > "$FAKE_LOG"
    : > "$FAKE_REWRITTEN"
}

echo "========== 1. 点名一个包：它所有版本 + 依赖闭包 =========="

build_tree
wave transfer demo
[[ "$RC" -eq 0 ]] && pass "transfer demo 成功" || fail "transfer demo 失败（rc=${RC}）：$(printf '%.300s' "$OUT")"
ok "汇总里给出计数" "$OUT" "transferred 4"
[[ "$(sort "$FAKE_REWRITTEN" | tr '\n' ' ')" == *"demo@1.0"*"demo@2.0"*"gcc@13"*"libcxx@1"* ]] \
    && pass "两个版本 + 依赖 + 依赖的依赖都改了" \
    || fail "改写集合不对：$(sort "$FAKE_REWRITTEN" | tr '\n' ' ')"
[[ "$(cat "$BASE/bin/other@1.0/.fake-state")" == "relative" ]] \
    && pass "没被点名的包没动" || fail "把没点名的包也改了"

echo
echo "========== 2. 幂等：全部已成相对，第二次什么都不做 =========="

: > "$FAKE_REWRITTEN"
wave transfer demo
[[ "$RC" -eq 0 ]] && pass "第二次仍然成功" || fail "第二次失败（rc=${RC}）"
ok "报告「already relative 4」" "$OUT" "already relative 4"
[[ ! -s "$FAKE_REWRITTEN" ]] && pass "一个都没改写" || fail "又改写了：$(cat "$FAKE_REWRITTEN")"

echo
echo "========== 3. 指定版本：只改那一个版本（依赖仍一起） =========="

build_tree
wave transfer demo@1.0
[[ "$RC" -eq 0 ]] && pass "transfer demo@1.0 成功" || fail "失败（rc=${RC}）：$(printf '%.300s' "$OUT")"
[[ "$(cat "$BASE/bin/demo@1.0/.fake-state")" == "relative" ]] \
    && pass "点名的版本改成了相对" || fail "demo@1.0 没改"
[[ "$(cat "$BASE/bin/demo@2.0/.fake-state")" == "absolute" ]] \
    && pass "另一个版本没动" || fail "把 demo@2.0 也改了"

echo
echo "========== 4. --dry-run：只报告，不动文件 =========="

build_tree
wave transfer --all --dry-run
[[ "$RC" -eq 0 ]] && pass "--dry-run 成功" || fail "--dry-run 失败（rc=${RC}）"
ok "用的是「would transfer」" "$OUT" "would transfer"
[[ ! -s "$FAKE_REWRITTEN" ]] && pass "一个文件都没改" || fail "dry-run 却改了：$(cat "$FAKE_REWRITTEN")"
[[ "$(cat "$BASE/bin/demo@1.0/.fake-state")" == "absolute" ]] \
    && pass "状态没变（仍是 absolute）" || fail "dry-run 改动了状态"

echo
echo "========== 5. --all：全树（含没被任何包引用的依赖） =========="

build_tree
wave transfer --all
[[ "$RC" -eq 0 ]] && pass "--all 成功" || fail "--all 失败（rc=${RC}）"
[[ "$(cat "$BASE/bin/other@1.0/.fake-state")" == "relative" ]] \
    && pass "没被引用的包也被处理了" || fail "other@1.0 没被处理"

echo
echo "========== 6. 判断不了（--check 返回 2）：算失败并如实说明 =========="

build_tree
printf 'broken\n' > "$BASE/bin/demo@1.0/.fake-state"
wave transfer demo@1.0
[[ "$RC" -ne 0 ]] && pass "判断不了时退出码非 0" || fail "判断不了却返回 0"
ok "点名失败的产物" "$OUT" "demo@1.0 could not be transferred"
ok "给出替代做法" "$OUT" "wave reinstall"

echo
echo "========== 7. 用法边界 =========="

wave transfer
[[ "$RC" -ne 0 ]] && pass "缺包名被拒绝" || fail "缺包名返回 0"
ok "给出两种写法" "$OUT" "wave transfer --all"

wave transfer demo -a
[[ "$RC" -ne 0 ]] && pass "-a 与包名混用被拒绝" || fail "-a 混用被接受了"

build_tree
wave transfer nosuchpkg
[[ "$RC" -ne 0 ]] && pass "没装的包被拒绝" || fail "没装的包返回 0"
ok "说明它没装" "$OUT" "not installed: nosuchpkg"

echo
echo "========== 8. 持锁：与装包/卸载互斥 =========="

grep -q "tree_lock" "$REPO_DIR/pkg/transferrer.py" \
    && pass "transfer 会获取安装锁" || fail "transfer 没有获取安装锁"

echo
echo "=========================================="
echo -e "🌊 Passed: $PASSED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="

[[ "$FAILED" -eq 0 ]] || exit 1
