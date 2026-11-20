#!/bin/bash

# state_test.sh
# 状态文件与同意记录的回归。三件事：
#
#   A. read_toml_string —— 平铺 TOML 取字符串：带引号/空格/行尾注释、键不存在、键名互为前缀
#   B. agreement_id     —— 从 selfupdate.py 的 AGREEMENT_ID 取值；文件缺失时失败
#   C. record_agreement —— 写出 AGREEMENT.json，内容就是那个 id；读不到 id 时如实告知
#      并且**不写文件**；--dry-run 下什么都不写
#
# 用法: bash scripts/state_test.sh
# 本机需要 bash 4.4+（安装器本身的门槛）。

set -u

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
INSTALL_SH="$REPO_DIR/lib/install.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo -e "  ${GREEN}✅ $1${RESET}"; }
fail() { FAIL=$((FAIL + 1)); echo -e "  ${RED_BOLD}❌ $1${RESET}"; }
report() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1（期望 '$3'，得到 '$2'）"; fi; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 摘出被测函数与它们依赖的最小环境（输出层、run_cmd、写盘检查）
{
    echo 'RED_BOLD=""; GREEN=""; YELLOW=""; RESET=""'
    echo 'LW_LANG="en"'
    echo ': "${CLI_DRY_RUN:=false}"'
    echo ': "${CLI_SKIP_PROBE:=false}"'
    echo ': "${NEED_SUDO:=false}"'
    echo 'lw_say() { printf "%b\n" "$1"; }'
    echo 'lw_say_err() { printf "%b\n" "$1" >&2; }'
    echo 'run_cmd() { "$@"; }'
    awk '/^read_toml_string\(\) \{/{f=1} f{print} f&&/^\}$/{c++} c==1{exit}' "$INSTALL_SH"
    awk '/^LW_WRITE_ERROR=""$/{f=1} f{print} f&&/^lw_write_state\(\) \{/{g=1} g&&/^\}$/{exit}' "$INSTALL_SH"
    awk '/^agreement_id\(\) \{/{f=1} f{print} f&&/^\}$/{c++} c==1{exit}' "$INSTALL_SH"
    awk '/^record_agreement\(\) \{/{f=1} f{print} f&&/^\}$/{c++} c==1{exit}' "$INSTALL_SH"
} > "$WORK/lib.sh"

for fn in read_toml_string lw_can_write lw_write_state agreement_id record_agreement; do
    grep -q "^$fn() {" "$WORK/lib.sh" || { echo -e "${RED_BOLD}🌊 Error: 摘不出 $fn()（install.sh 结构变了？）${RESET}"; exit 1; }
done

echo "========== A. read_toml_string =========="
out="$(bash -c 'source "$1"; read_toml_string "version = \"4.0.0\"" version' _ "$WORK/lib.sh")"
report "取普通字符串值" "$out" "4.0.0"

out="$(bash -c 'source "$1"; read_toml_string "  version   =   \"4.0.0\"   # 注释" version' _ "$WORK/lib.sh")"
report "容忍缩进、等号两侧空格与行尾注释" "$out" "4.0.0"

out="$(bash -c 'source "$1"; read_toml_string "update_commands_sha256 = \"abc\"" update' _ "$WORK/lib.sh")"
report "键名不做前缀匹配（update ≠ update_commands_sha256）" "$out" ""

out="$(bash -c 'source "$1"; read_toml_string "build_number = \"323R1250\"" missing' _ "$WORK/lib.sh")"
report "键不存在时输出空" "$out" ""

echo "========== B. agreement_id =========="
mkdir -p "$WORK/lib"
printf 'AGREEMENT_ID = "2026-11-19"\n' > "$WORK/lib/selfupdate.py"
out="$(LIB_DIR="$WORK/lib" bash -c 'source "$1"; agreement_id' _ "$WORK/lib.sh")"
report "从 selfupdate.py 取到 id" "$out" "2026-11-19"

rm -f "$WORK/lib/selfupdate.py"
bash -c 'source "$1"; agreement_id' _ "$WORK/lib.sh" > /dev/null 2>&1
report "文件缺失时返回非零" "$?" "1"

echo "========== C. record_agreement =========="
mkdir -p "$WORK/lib" "$WORK/config"
printf 'AGREEMENT_ID = "2026-11-19"\n' > "$WORK/lib/selfupdate.py"

LIB_DIR="$WORK/lib" AGREEMENT_FILE="$WORK/config/AGREEMENT.json" \
    bash -c 'source "$1"; record_agreement' _ "$WORK/lib.sh" > /dev/null 2>&1
report "写出 AGREEMENT.json" "$([[ -f "$WORK/config/AGREEMENT.json" ]] && echo yes || echo no)" "yes"
report "内容是那个 id" "$(python3 -c "import json,sys;print(json.load(open('$WORK/config/AGREEMENT.json'))['agreement'])" 2>/dev/null)" "2026-11-19"

rm -f "$WORK/config/AGREEMENT.json"
rm -f "$WORK/lib/selfupdate.py"
out="$(LIB_DIR="$WORK/lib" AGREEMENT_FILE="$WORK/config/AGREEMENT.json" \
    bash -c 'source "$1"; record_agreement; echo rc=$?' _ "$WORK/lib.sh" 2>&1)"
case "$out" in
    *"cannot read AGREEMENT_ID"*) pass "读不到 id 时如实说明" ;;
    *) fail "读不到 id 时没有说明（${out}）" ;;
esac
case "$out" in
    *"rc=0"*) pass "读不到 id 不中断安装" ;;
    *) fail "读不到 id 不该中断（${out}）" ;;
esac
report "读不到 id 时不留下空文件" \
    "$([[ -e "$WORK/config/AGREEMENT.json" ]] && echo yes || echo no)" "no"

printf 'AGREEMENT_ID = "2026-11-19"\n' > "$WORK/lib/selfupdate.py"
LIB_DIR="$WORK/lib" AGREEMENT_FILE="$WORK/config/AGREEMENT.json" CLI_DRY_RUN=true \
    bash -c 'source "$1"; record_agreement' _ "$WORK/lib.sh" > /dev/null 2>&1
report "试运行时不写文件" \
    "$([[ -e "$WORK/config/AGREEMENT.json" ]] && echo yes || echo no)" "no"

echo "========== D. lw_can_write =========="
mkdir -p "$WORK/writable" "$WORK/locked"
chmod 500 "$WORK/locked"
bash -c 'source "$1"; lw_can_write "$2"' _ "$WORK/lib.sh" "$WORK/writable" > /dev/null 2>&1
report "可写目录返回 0" "$?" "0"

if [[ "$(id -u)" -ne 0 ]]; then
    bash -c 'source "$1"; lw_can_write "$2"' _ "$WORK/lib.sh" "$WORK/locked" > /dev/null 2>&1
    report "不可写目录返回 1（需要提权）" "$?" "1"
fi

# 试运行承诺「不写文件」，所以连写探针都不该留下
rm -f "$WORK"/writable/.linuxwave-write-probe.*
bash -c 'source "$1"; CLI_DRY_RUN=true; lw_can_write "$2"' _ "$WORK/lib.sh" "$WORK/writable" > /dev/null 2>&1
report "试运行时对可写目录仍返回 0" "$?" "0"
report "试运行不留下写探针" \
    "$(ls "$WORK"/writable/.linuxwave-write-probe.* 2>/dev/null | wc -l | tr -d ' ')" "0"

echo "------------------------------------------------------------"
if [[ "$FAIL" -ne 0 ]]; then
    echo -e "${RED_BOLD}🌊 $FAIL 项失败，$PASS 项通过${RESET}"
    exit 1
fi
echo -e "${GREEN}🌊 全部 $PASS 项通过${RESET}"
