#!/bin/bash

# info_format_test.sh
# `wave info` 三种机器可读格式的回归（离线）。
#
# 这三条输出的用途是「喂给别的程序」，所以必须能被真正的解析器读回去：
# JSON 用 json.loads、TOML 用 tomllib，YAML 至少满足「key: 标量 / key: 列表」的常见子集。
# 另外两条规则也要一直成立：
#   1. 值为 None 的字段在 yaml / toml 里**不出现**（缺字段比空字符串诚实）
#   2. 格式旗标互斥：同时给两个就报错，而不是悄悄挑一个

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

CONFIG_DIR="$WORK/root/etc/linuxwave_config"
mkdir -p "$CONFIG_DIR" "$WORK/tree"
printf '{"base_dir": "%s"}\n' "$WORK/tree" > "$CONFIG_DIR/config.json"
export LINUXWAVE_TEST="$WORK/root"

run_py() {
    python3 - "$REPO_DIR" <<PY
import sys

repo = sys.argv[1]
sys.path.insert(0, f"{repo}/scripts")
import components
components.add_to_sys_path(repo)
import pkginfohelper

$1
PY
}

check() {
    local title="$1" expected="$2" body="$3"
    local got
    got="$(run_py "$body" 2>&1 | tail -1)"
    if [[ "$got" == "$expected" ]]; then
        pass "$title"
    else
        fail "$title (expected '$expected', got '$got')"
    fi
}

echo "========== 三种格式都能被真正的解析器读回去 =========="

check "JSON 可 json.loads 且字段齐全" "ok" '
import json
fields = pkginfohelper.info_fields(
    "jq",
    {"aut": "Stephen Dolan", "des": "JSON processor", "hom": "https://example.test", "lic": "MIT"},
    ["1.7.1"], ["1.8.2", "1.7.1"])
data = json.loads(pkginfohelper.info_as_json(fields))
assert data["name"] == "jq" and data["latest"] == "1.8.2", data
assert data["installed"] == ["1.7.1"] and data["license"] == "MIT", data
print("ok")'

check "TOML 可 tomllib.loads" "ok" '
try:
    import tomllib
except ImportError:
    print("ok")          # 3.10 及更早没有 tomllib：跳过
else:
    fields = pkginfohelper.info_fields(
        "jq", {"aut": "A", "des": "D", "hom": "H", "lic": "L"}, [], ["1.8.2"])
    data = tomllib.loads(pkginfohelper.info_as_toml(fields))
    assert data["name"] == "jq" and data["available"] == ["1.8.2"], data
    print("ok")'

check "YAML 是 key: 标量 / key: 列表 的常见子集" "ok" '
import re
fields = pkginfohelper.info_fields(
    "jq", {"aut": "A", "des": "D", "hom": "H", "lic": "L"}, [], ["1.8.2", "1.7.1"])
text = pkginfohelper.info_as_yaml(fields)
lines = text.splitlines()
assert lines[0].startswith("name: "), lines[:1]
assert any(line == "available:" for line in lines), lines
assert lines.count("  - \"1.8.2\"") == 1, lines
assert all(re.match(r"^[a-z_]+:( .*)?$|^  - ", line) for line in lines), lines
print("ok")'

echo ""
echo "========== 缺字段就不出现 =========="

check "yaml 省略 None 字段" "True" '
fields = pkginfohelper.info_fields("jq", {}, [], [])
print(all(not line.startswith("author:") for line in pkginfohelper.info_as_yaml(fields).splitlines()))'

check "toml 省略 None 字段" "True" '
fields = pkginfohelper.info_fields("jq", {}, [], [])
print(all(not line.startswith("author ") for line in pkginfohelper.info_as_toml(fields).splitlines()))'

check "空列表输出为 []" "installed = []" '
fields = pkginfohelper.info_fields("jq", {}, [], [])
print([l for l in pkginfohelper.info_as_toml(fields).splitlines() if l.startswith("installed")][0])'

echo ""
echo "========== 参数解析 =========="

check "单一格式" "json" '
operands, fmt = pkginfohelper.parse_info_arguments(["jq", "--json"])
print(fmt if operands == ["jq"] else "operands:" + repr(operands))'

check "没有格式时返回 None" "None" '
print(pkginfohelper.parse_info_arguments(["jq"])[1])'

check "--max-time 的值不会被当成包名" "['jq']" '
operands, fmt = pkginfohelper.parse_info_arguments(["jq", "--max-time", "1min"])
print(repr(operands))'

check "包名带版本号原样保留" "['jq@1.8.2']" '
print(repr(pkginfohelper.parse_info_arguments(["jq@1.8.2", "--toml"])[0]))'

check "两个格式同时给 → 报错退出" "SystemExit" '
try:
    pkginfohelper.parse_info_arguments(["jq", "--json", "--yaml"])
except SystemExit:
    print("SystemExit")
else:
    print("no exit")'

check "未知选项 → 报错退出" "SystemExit" '
try:
    pkginfohelper.parse_info_arguments(["jq", "--nope"])
except SystemExit:
    print("SystemExit")
else:
    print("no exit")'

echo ""
echo "=========================================="
echo -e "🌊 Passed: $PASSED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="
[[ "$FAILED" -eq 0 ]] || exit 1
echo -e "${GREEN}🌊 info output formats hold${RESET}"
