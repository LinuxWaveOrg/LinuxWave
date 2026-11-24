#!/bin/bash

# shellenv_test.sh
# `wave shellenv` 的回归。三件事：
#
#   A. lib/shellenv.py 的输出形状 —— 三目录、case 守卫、不带任何提示语
#   B. lib/wave 启动器里的 shell 快路径必须与 Python 那份**逐字一致**
#      （那一行每次开终端都要跑，走 Python 上百毫秒，走 shell 是毫秒级；
#       两份一旦漂移，用户在不同时机 eval 会得到不同结果）
#   C. 幂等：连续 eval 两次，PATH 不变长
#
# 用法: bash scripts/shellenv_test.sh

set -u

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo -e "  ${GREEN}✅ $1${RESET}"; }
fail() { FAIL=$((FAIL + 1)); echo -e "  ${RED_BOLD}❌ $1${RESET}"; }
report() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1（期望 '$3'，得到 '$2'）"; fi; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

BASE="$WORK/tree"
mkdir -p "$BASE"/{bin,links,lib}

echo "========== A. Python 输出 =========="
py_out="$(PYTHONPATH="$REPO_DIR/lib:$REPO_DIR/pkg:$REPO_DIR/surfboard" \
    LINUXWAVE_CONFIG_DIR_OVERRIDE= \
    python3 - "$BASE" <<'PY' 2>&1
import sys, pathlib
sys.path.insert(0, "config")
sys.path.insert(0, "lib")
import shellenv
sys.stdout.write(shellenv.render(pathlib.Path(sys.argv[1])))
PY
)"
case "$py_out" in
    *"case \":\$PATH:\" in"*) pass "带 case 守卫（可重复 eval）" ;;
    *) fail "缺少 case 守卫（${py_out}）" ;;
esac
case "$py_out" in
    *"$BASE/bin:$BASE/links:$BASE/lib"*) pass "三个目录都在，顺序为 bin:links:lib" ;;
    *) fail "目录不全或顺序不对（${py_out}）" ;;
esac
case "$py_out" in
    *🌊*) fail "输出里混进了提示语（会被 eval 当命令执行）" ;;
    *) pass "输出里没有提示语" ;;
esac

echo "========== B. 启动器快路径与 Python 一致 =========="
# 从 install.sh 里把启动器模板整段拿出来，替换解释器占位后跑一遍
awk '/<<.LAUNCHER.$/{f=1;next} f&&/^LAUNCHER$/{exit} f{print}' \
    "$REPO_DIR/lib/install.sh" > "$WORK/launcher.tpl"
if [[ ! -s "$WORK/launcher.tpl" ]]; then
    fail "摘不出启动器模板（install.sh 结构变了？）"
else
    sed -e 's|^#__LINUXWAVE_PYTHON__$|LINUXWAVE_PYTHON=""|' "$WORK/launcher.tpl" > "$BASE/lib/wave"
    chmod +x "$BASE/lib/wave"
    sh_out="$("$BASE/lib/wave" shellenv 2>&1)"
    if [[ "$sh_out" == "$py_out" ]]; then
        pass "启动器快路径与 lib/shellenv.py 逐字一致"
    else
        fail "两份输出不一致"
        diff <(printf '%s\n' "$py_out") <(printf '%s\n' "$sh_out") | head -8 | sed 's/^/      /'
    fi
fi

echo "========== C. 幂等 =========="
first="$(PATH="/usr/bin:/bin" bash -c "eval \"\$1\"; printf '%s' \"\$PATH\"" _ "$py_out")"
second="$(PATH="/usr/bin:/bin" bash -c "eval \"\$1\"; eval \"\$1\"; printf '%s' \"\$PATH\"" _ "$py_out")"
report "eval 两次 PATH 不变长" "$second" "$first"
report "eval 一次后三个目录都在 PATH 前面" \
    "$([[ "$first" == "$BASE/bin:$BASE/links:$BASE/lib:"* ]] && echo yes || echo no)" "yes"

echo "------------------------------------------------------------"
if [[ "$FAIL" -ne 0 ]]; then
    echo -e "${RED_BOLD}🌊 $FAIL 项失败，$PASS 项通过${RESET}"
    exit 1
fi
echo -e "${GREEN}🌊 全部 $PASS 项通过${RESET}"
