#!/bin/bash

# lock_test.sh
# 安装树的互斥锁（lib/lock.py）：同一时刻只允许一个会改动安装树的 wave 在跑。
#
# 为什么需要：同时跑两个 wave 会撞在 bin/<名>@<版本>/ 的 rm -rf+mv、links/、
# .depped_* 引用计数（读-改-写）与 downloads/tmp 的同名 .partial 上。症状都是
# 「另一个命令装出来的东西不对」，而报错指向的却是别的地方。锁一旦退化成「永远能拿到」，
# 这条防线就没有了，而且不会有别的测试发现。
#
# 全程离线：拿真正会改树的命令（uninstall 一个假装的已装包）当试验对象，
# 不联网、不碰真实安装树。

set -u
set +e

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PYTHON=${PYTHON:-python3}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/lock_test.XXXXXX")
WORK=$(cd "$WORK" && pwd -P)
trap 'rm -rf "$WORK"' EXIT

PASSED=0
FAILED=0

pass() { echo -e "${GREEN}🌊 PASS: $1${RESET}"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED_BOLD}🌊 FAIL: $1${RESET}"; FAILED=$((FAILED + 1)); }

SANDBOX="$WORK/sandbox"
BASE="$SANDBOX/opt/linuxwave"
mkdir -p "$SANDBOX/etc/linuxwave_config" "$BASE"/{bin,links,deps,downloads/tmp}
printf '{"base_dir": "%s"}' "$BASE" > "$SANDBOX/etc/linuxwave_config/config.json"
for component in cli config lib net pkg surfboard; do
    ln -sfn "$REPO_DIR/$component" "$BASE/$component"
done
printf '{"version": "4.6.0"}\n' > "$BASE/VERSION.json"

LOCK_FILE="$BASE/var/lock/wave.lock"

# 每次都先造一个「已装」的包，让卸载有东西可删（卸载会真的动树）
fake_installed() {
    rm -rf "${BASE:?}/bin" "$BASE/links"
    mkdir -p "$BASE/bin/demo@1.0" "$BASE/links" "$BASE/deps/probe"
    printf '#!/bin/sh\necho demo\n' > "$BASE/bin/demo@1.0/demo"
    chmod +x "$BASE/bin/demo@1.0/demo"
}

wave() {
    OUT=$(LINUXWAVE_TEST="$SANDBOX" "$PYTHON" "$BASE/lib/wave.py" "$@" < /dev/null 2>&1)
    RC=$?
}

echo "========== 1. 没有别的 wave 时照常工作，退出后不留锁 =========="

fake_installed
wave uninstall demo@1.0
[[ "$RC" -eq 0 ]] && pass "没有竞争时命令正常完成" \
    || fail "正常路径失败（rc=${RC}）：$(printf '%.200s' "$OUT")"
[[ -f "$LOCK_FILE" ]] && pass "锁文件已创建（${LOCK_FILE}）" \
    || fail "锁文件没有创建"
[[ -d "$BASE/bin/demo@1.0" ]] && fail "卸载其实没生效（后面的断言就不作数了）" \
    || pass "卸载真的动过树"

fake_installed
wave uninstall demo@1.0
[[ "$RC" -eq 0 ]] && pass "上一次退出后锁已释放（可以再次获取）" \
    || fail "锁没有释放（rc=${RC}）：$(printf '%.200s' "$OUT")"

echo
echo "========== 2. 别人持有锁时立即失败，并说明是谁 =========="

LINUXWAVE_TEST="$SANDBOX" "$PYTHON" - "$REPO_DIR" <<'PY' &
import sys, time
repo = sys.argv[1]
sys.path[:0] = [repo + "/lib", repo + "/config", repo + "/cli", repo + "/net",
                repo + "/pkg", repo + "/surfboard"]
from lock import tree_lock
with tree_lock("install jq"):
    print("HOLDING", flush=True)
    time.sleep(8)
PY
HOLDER=$!

for _ in $(seq 1 100); do
    if [ -f "$LOCK_FILE" ] && grep -q "install jq" "$LOCK_FILE" 2> /dev/null; then
        break
    fi
    sleep 0.1
done
grep -q "install jq" "$LOCK_FILE" 2> /dev/null \
    && pass "持有者已拿到锁并写下自己的动作" \
    || fail "持有者没能拿到锁（$(cat "$LOCK_FILE" 2> /dev/null)）"

fake_installed
wave uninstall demo@1.0
[[ "$RC" -ne 0 ]] && pass "竞争时命令失败" || fail "竞争时仍然成功（rc=${RC}）"
[[ "$OUT" == *"another wave is running"* ]] \
    && pass "报错说清了是「另一个 wave」" || fail "报错没有说明原因：$(printf '%.200s' "$OUT")"
[[ "$OUT" == *"install jq"* ]] \
    && pass "报错里带上了持有者正在做的事" || fail "报错没有持有者信息：$(printf '%.200s' "$OUT")"
[[ "$OUT" == *"do not delete"* ]] \
    && pass "提示不要手删锁文件" || fail "缺少「别删锁文件」的提示"
[[ -d "$BASE/bin/demo@1.0" ]] \
    && pass "抢不到锁时一个字节都没动（安装目录还在）" \
    || fail "抢不到锁却动了树：$(ls "$BASE/bin" 2>/dev/null | tr '\n' ' ')"

# 持有者到时自己退出（脚本不给它发信号），等它结束再往下走
wait "$HOLDER" 2> /dev/null

echo
echo "========== 3. 持有者被强制终止（SIGKILL 等价）之后锁自动释放 =========="

# 拿到锁之后直接 os._exit：既不走 tree_lock.__exit__，也不做任何清理 —— 从 flock
# 的角度看与 SIGKILL 完全一样（fd 由内核在进程结束时关掉）。只有以「不干净」的方式
# 结束，才能证明锁不是靠代码里的 __exit__ 释放的。
LINUXWAVE_TEST="$SANDBOX" "$PYTHON" - "$REPO_DIR" <<'PY'
import os, sys
repo = sys.argv[1]
sys.path[:0] = [repo + "/lib", repo + "/config", repo + "/cli", repo + "/net",
                repo + "/pkg", repo + "/surfboard"]
from lock import tree_lock
with tree_lock("uninstall yq"):
    print("HOLDING", flush=True)
    sys.stdout.flush()
    os._exit(137)
PY

fake_installed
wave uninstall demo@1.0
[[ "$RC" -eq 0 ]] && pass "持有者异常结束后锁可立即重新获取（flock 由内核释放）" \
    || fail "异常结束之后仍然拿不到锁（rc=${RC}）：$(printf '%.200s' "$OUT")"

echo
echo "========== 4. 同一进程内可重入（不自己锁死） =========="

Out=$(LINUXWAVE_TEST="$SANDBOX" "$PYTHON" - "$REPO_DIR" <<'PY' 2>&1
import sys
repo = sys.argv[1]
sys.path[:0] = [repo + "/lib", repo + "/config", repo + "/cli", repo + "/net",
                repo + "/pkg", repo + "/surfboard"]
from lock import tree_lock
with tree_lock("outer"):
    with tree_lock("inner"):
        with tree_lock("inner2"):
            print("NESTED-OK")
print("RELEASED")
PY
)
RC=$?
[[ "$RC" -eq 0 && "$Out" == *"NESTED-OK"*"RELEASED"* ]] \
    && pass "嵌套三层不死锁，退出后释放" \
    || fail "嵌套锁把进程锁死了（rc=${RC}）：$(printf '%.300s' "$Out")"

echo
echo "========== 5. 该上锁的命令都上了 =========="

for spec in "pkg/pkginstaller.py:install" "pkg/uninstaller.py:uninstall" \
            "lib/selfupdate.py:selfupdate"; do
    file="${spec%%:*}"
    label="${spec##*:}"
    if grep -q "tree_lock" "$REPO_DIR/$file"; then
        pass "$label 会获取安装锁"
    else
        fail "$file 没有获取安装锁（改树的命令必须互斥）"
    fi
done

# upgrade 复用 install 的流水线，锁由那边拿；这里确认它真的走 handle_install
grep -q "handle_install" "$REPO_DIR/pkg/upgrader.py" \
    && pass "upgrade 复用 install 的流水线（因此也受同一把锁）" \
    || fail "upgrade 没有走 handle_install，锁就漏了"

echo
echo "========== 6. 建不了锁不至于让工具用不了 =========="

# 把 var/ 换成普通文件 → makedirs 必然失败；此时只能警告后继续
rm -rf "$BASE/var"
printf 'not a directory' > "$BASE/var"
fake_installed
wave uninstall demo@1.0
[[ "$RC" -eq 0 ]] && pass "建不了锁时仍然继续执行（只是没有互斥）" \
    || fail "建不了锁就把命令挡下了（rc=${RC}）：$(printf '%.200s' "$OUT")"
[[ "$OUT" == *"cannot create the install lock"* ]] \
    && pass "并且如实说了一句没有互斥" || fail "没有说明「这次没有互斥」"
rm -f "$BASE/var"

echo
echo "=========================================="
echo -e "🌊 Passed: $PASSED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="

[[ "$FAILED" -eq 0 ]] || exit 1
echo -e "${GREEN}🌊 All lock tests passed${RESET}"
