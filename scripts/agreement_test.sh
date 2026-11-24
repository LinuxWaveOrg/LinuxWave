#!/bin/bash

# agreement_test.sh
# 协议同意的判定（离线）：`wave selfupdate` 什么时候该再问一次。
#
# 三件事必须一直成立：
#   1. 记录里是当前 AGREEMENT_ID → 不问（否则每次自更新都拦一道）
#   2. 记录缺失/过期、且已装版本 ≤ 协议引入版 → 问
#   3. 全新安装（没有已装版本）不问 —— 那是 install.sh 的事
# 还有一条只影响「要不要问」的：跨大版本不问（那次更新反正要重装，问了也白问）。

set -u

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

PASSED=0
FAILED=0
pass() { echo -e "${GREEN}🌊 PASS: $1${RESET}"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED_BOLD}🌊 FAIL: $1${RESET}"; FAILED=$((FAILED + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 系统级配置目录：find_config_dir() 看到 config.json 就把它当成生效的那份
CONFIG_DIR="$WORK/root/etc/linuxwave_config"
TREE="$WORK/tree"
mkdir -p "$CONFIG_DIR" "$TREE"
printf '{"base_dir": "%s"}\n' "$TREE" > "$CONFIG_DIR/config.json"

export LINUXWAVE_TEST="$WORK/root"

check() {
    local title="$1" expected="$2" script="$3"
    local got
    got="$(python3 - "$REPO_DIR" "$CONFIG_DIR" <<PY
import sys

repo, config_dir = sys.argv[1], sys.argv[2]
sys.path.insert(0, f"{repo}/scripts")
import components
components.add_to_sys_path(repo)
import selfupdate

$script
PY
)" 2>&1
    if [[ "$got" == "$expected" ]]; then
        pass "$title"
    else
        fail "$title (expected $expected, got $got)"
    fi
}

write_agreement() {
    printf '{"agreement": "%s"}\n' "$1" > "$CONFIG_DIR/AGREEMENT.json"
}
clear_agreement() {
    rm -f "$CONFIG_DIR/AGREEMENT.json"
}

echo "========== 什么时候该再问一次协议 =========="

clear_agreement
check "记录缺失、已装 4.6.0（协议引入版）→ 问" "True" \
    'print(selfupdate.agreement_needs_consent("4.6.0"))'

clear_agreement
check "记录缺失、已装 4.6.1（晚于引入版）→ 不问" "False" \
    'print(selfupdate.agreement_needs_consent("4.6.1"))'

clear_agreement
check "全新安装（没有已装版本）→ 不问" "False" \
    'print(selfupdate.agreement_needs_consent(""))'

write_agreement "2026-11-24"
check "记录是当前 AGREEMENT_ID → 不问" "False" \
    'print(selfupdate.agreement_needs_consent("4.6.0"))'

write_agreement "2020-01-01"
check "记录是旧协议、已装 4.6.0 → 问" "True" \
    'print(selfupdate.agreement_needs_consent("4.6.0"))'

printf 'not json\n' > "$CONFIG_DIR/AGREEMENT.json"
check "记录文件坏了 → 当作没记录（问）" "True" \
    'print(selfupdate.agreement_needs_consent("4.6.0"))'

echo ""
echo "========== 跨大版本不谈协议 =========="

clear_agreement
check "3.2.1 → 4.0.2 是跨大版本" "True" \
    'print(selfupdate._is_cross_major("3.2.1", "4.0.2"))'
check "4.0.0 → 4.0.2 不是跨大版本" "False" \
    'print(selfupdate._is_cross_major("4.0.0", "4.0.2"))'
check "拿不到版本号时不当成跨大版本" "False" \
    'print(selfupdate._is_cross_major("", "4.0.2"))'

echo ""
echo "=========================================="
echo -e "🌊 Passed: $PASSED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="
[[ "$FAILED" -eq 0 ]] || exit 1
echo -e "${GREEN}🌊 Agreement consent rules hold${RESET}"
