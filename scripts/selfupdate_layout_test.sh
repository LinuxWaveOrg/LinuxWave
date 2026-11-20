#!/bin/bash

# selfupdate_layout_test.sh
# 4.0 自更新布局的回归，离线：
#
#   1. `latest.toml` 的解析：真 TOML 写法（`key = "value"`、`#` 注释）要能读，
#      半行残缺或值不带引号要**当作不存在**——否则残缺的半行会被当成版本号；
#   2. 地址：两个函数拼出来必须是 `linuxwavedata/…` 那套；
#   3. 生成器：清单内联进脚本（want / FULL_FILES / delta），过滤掉不该装的文件，
#      可重复（同输入逐字节相同），产物过 `bash -n` 并带可执行位；
#   4. 模板：拿真产物对一份 `file://` 镜像跑一遍 —— 落地、可执行位、增量/全量
#      的判断与「树不完整就补全」，以及缺必需环境变量时立刻失败。

set -u

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

PASSED=0
FAILED=0

pass() {
    echo -e "${GREEN}🌊 PASS: $1${RESET}"
    PASSED=$((PASSED + 1))
}

fail() {
    echo -e "${RED_BOLD}🌊 FAIL: $1${RESET}"
    FAILED=$((FAILED + 1))
}

collect() {
    local verdict text before=$PASSED
    while IFS='|' read -r verdict text; do
        case "$verdict" in
            PASS) pass "$text" ;;
            FAIL) fail "$text" ;;
        esac
    done
    if [[ "$PASSED" -eq "$before" ]]; then
        fail "该段的检查没有产生任何结果（被测代码可能直接崩了）"
    fi
}

echo "========== 1. latest.toml 解析与地址 =========="

collect < <(python3 - "$REPO_DIR" <<'PY'
import sys

repo = sys.argv[1]
sys.path.insert(0, f"{repo}/scripts")
import components
components.add_to_sys_path(repo)

import domains
import selfupdate


def report(ok, text):
    print(("PASS|" if ok else "FAIL|") + text)


SAMPLE = '''# 注释行不该被当成字段
version = "4.0.0"
release_date = "2026-11-20"

build_number = "324A1200"
branch = "4.0"
broken_line_without_equals
unquoted = 4.0.1
'''
data = selfupdate.parse_toml(SAMPLE)
report(data.get("version") == "4.0.0", "读出 version")
report(data.get("branch") == "4.0", "读出 branch")
report(data.get("build_number") == "324A1200", "读出 build_number（中间隔着空行）")
report("broken_line_without_equals" not in data, "没有等号的行被忽略")
report("unquoted" not in data, "值不带引号的字段被忽略（残缺半行不能当版本号）")
report("# 注释行不该被当成字段" not in data, "注释行被忽略")

# 地址必须落在 linuxwavedata/ 下
latest = domains.selfupdate_latest_url()
report(latest.endswith("/linuxwavedata/latest.toml"), "latest.toml 的地址")
commands = domains.selfupdate_commands_url("4.0.0")
report(commands.endswith("/linuxwavedata/4.0.0/update_commands.sh"), "按版本的 update_commands.sh 地址")
PY
)

echo ""
echo "========== 2. 生成器：清单内联 =========="

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 清单从 components.txt + assets.txt 取 —— 与生成器同一个来源，加了组件不必改这里
FILES="$(python3 - "$REPO_DIR" <<'PY'
import pathlib
import sys

repo = pathlib.Path(sys.argv[1])
sys.path.insert(0, str(repo / "scripts"))
import assets
import components

for name in components.names() + assets.names():
    for path in sorted((repo / name).rglob("*")):
        if not path.is_file():
            continue
        if "__pycache__" in path.parts or path.suffix == ".pyc":
            continue
        print(f"{name}/{path.relative_to(repo / name)}")
PY
)"

mapfile -t FILE_LIST <<< "$FILES"

generate() {
    local out="$1"; shift
    python3 "$REPO_DIR/scripts/build_update_commands.py" \
        --version 9.9.9 --branch 9.9 --files "${FILE_LIST[@]}" "$@" --out "$out"
}

OUT="$WORK/linuxwavedata/9.9.9/update_commands.sh"
if generate "$OUT" > "$WORK/gen.log" 2>&1; then
    pass "生成成功"
else
    fail "生成失败（$(tail -1 "$WORK/gen.log")）"
fi

[[ -x "$OUT" ]] && pass "产物带可执行位" || fail "产物没有可执行位"
bash -n "$OUT" 2>/dev/null && pass "产物通过 bash -n" || fail "产物有语法错误"

grep -q 'VERSION="9.9.9"' "$OUT" && pass "注入了版本号" || fail "没注入版本号"
grep -q 'BRANCH="9.9"' "$OUT" && pass "注入了分支" || fail "没注入分支"

if grep -q "@@FULL@@\|@@DELTA@@\|@@FULL_FILES@@" "$OUT"; then
    fail "占位符没有被替换"
else
    pass "占位符全部被替换"
fi

# install_fresh / install_delta 各自一段，取前者比较全量
fresh_paths() {
    sed -n '/^install_fresh() {/,/^}$/p' "$1" | grep '^    want ' | awk '{print $2}'
}

FRESH_PATHS="$(fresh_paths "$OUT")"
WANT_COUNT="$(grep -c . <<< "$FRESH_PATHS")"
# 生成器会丢掉「不该进安装树」的几类：安装器/卸载器不装自己，说明文件给人看
EXPECTED_COUNT="$(printf '%s\n' "${FILE_LIST[@]}" | grep -cvE '^(lib/(install|uninstall)\.sh)$|/(README|description)\.md$')"
if [[ "$WANT_COUNT" -eq "$EXPECTED_COUNT" ]]; then
    pass "全量清单逐文件内联（$WANT_COUNT 条 want）"
else
    fail "want 条数不对（$WANT_COUNT，期望 $EXPECTED_COUNT）"
fi

# 落盘清单与 want 必须同源：各写一份就会漂移成「自检说完整、实际缺文件」
FULL_BLOCK="$(sed -n '/^FULL_FILES="$/,/^"$/p' "$OUT" | grep -v '^FULL_FILES="' | grep -v '^"$')"
if [[ "$FULL_BLOCK" == "$FRESH_PATHS" ]]; then
    pass "FULL_FILES 与 want 列表同源"
else
    fail "FULL_FILES 与 want 列表不一致"
fi

# 每行都带 sha256（实验性签名的第三列），否则那一行退化成「只靠 TLS」
MISSING_DIGEST="$(grep '^    want ' "$OUT" | awk 'NF < 4' | wc -l | tr -d ' ')"
if [[ "$MISSING_DIGEST" == "0" ]]; then
    pass "每行都带 sha256"
else
    fail "有 $MISSING_DIGEST 行没有 sha256"
fi

DIGEST_LINE="$(grep -m1 '^    want lib/wave.py' "$OUT" | awk '{print $4}')"
EXPECTED_DIGEST="$(python3 -c "import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$REPO_DIR/lib/wave.py")"
[[ "$DIGEST_LINE" == "$EXPECTED_DIGEST" ]] && pass "哈希与文件内容一致" \
    || fail "哈希对不上（$DIGEST_LINE != $EXPECTED_DIGEST）"

for forbidden in 'lib/install.sh' 'lib/uninstall.sh' 'lib/wave ' 'Keys/description.md' '__pycache__'; do
    if grep -q "want $forbidden" "$OUT"; then
        fail "不该装的文件进了清单：$forbidden"
    else
        pass "清单里没有 $forbidden"
    fi
done

# 打印出来的哈希必须就是产物的哈希（latest.toml 里记的是它）
PRINTED="$(sed -n 's/^   update_commands_sha256 = //p' "$WORK/gen.log")"
ACTUAL="$(python3 -c "import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$OUT")"
[[ -n "$PRINTED" && "$PRINTED" == "$ACTUAL" ]] && pass "打印的 update_commands_sha256 与产物一致" \
    || fail "打印的哈希与产物不一致"

cp "$OUT" "$WORK/first.sh"
generate "$WORK/linuxwavedata/9.9.9/again.sh" > /dev/null 2>&1
cmp -s "$WORK/first.sh" "$WORK/linuxwavedata/9.9.9/again.sh" && pass "生成可重复（逐字节相同）" \
    || fail "两次生成不一致"

# 增量：只有列出的文件进 install_delta，新文件排最前
DELTA_OUT="$WORK/delta.sh"
if generate "$DELTA_OUT" --delta lib/wave.py cli/help.py --new cli/help.py > /dev/null 2>&1; then
    DELTA_PATHS="$(sed -n '/^install_delta() {/,/^}$/p' "$DELTA_OUT" | grep '^    want ' | awk '{print $2}' | tr '\n' ' ')"
    [[ "$DELTA_PATHS" == "cli/help.py lib/wave.py " ]] && pass "--new 里的文件排在增量最前" \
        || fail "增量顺序不对（$DELTA_PATHS）"
else
    fail "带 --delta/--new 的生成失败"
fi

# 空的 delta 不能放行：那会让「版本号前进、文件一个没换」
if generate "$WORK/empty-delta.sh" --delta __pycache__/x.pyc > /dev/null 2>&1; then
    fail "delta 被过滤空之后仍然生成了脚本"
else
    pass "delta 被过滤空时拒绝生成"
fi

if generate "$WORK/unknown.sh" --delta no/such/file.py > /dev/null 2>&1; then
    fail "delta 里有全量清单之外的文件时仍然生成"
else
    pass "delta 指向不存在的文件时拒绝生成"
fi

echo ""
echo "========== 3. 模板：对 file:// 镜像真跑一遍 =========="

MIRROR="$WORK/mirror"
mkdir -p "$MIRROR/core/9.9"
copy_component() { cp -R "$REPO_DIR/$1" "$MIRROR/core/9.9/"; }
for name in $(python3 -c "
import sys; sys.path.insert(0, '$REPO_DIR/scripts'); import components, assets
print(' '.join(components.names() + assets.names()))"); do
    copy_component "$name"
done

TREE="$WORK/tree"
mkdir -p "$TREE"

run_script() {
    # run_script <脚本> [额外环境…]：把模板按合同跑一遍，输出直接给调用方看
    local script="$1"; shift
    env LINUXWAVE_INSTALL_DIR="$TREE" \
        LINUXWAVE_CORE_URL="file://$MIRROR/core" \
        LINUXWAVE_BRANCH=9.9 \
        LINUXWAVE_FILE_TIMEOUT=10 \
        "$@" \
        bash "$script" 2>&1
}

if ( unset LINUXWAVE_INSTALL_DIR LINUXWAVE_CORE_URL LINUXWAVE_BRANCH; bash "$OUT" ) > /dev/null 2>&1; then
    fail "缺必需环境变量时仍然返回成功"
else
    pass "缺必需环境变量时立刻失败"
fi

FIRST="$(run_script "$OUT")"
if [[ -f "$TREE/lib/wave.py" && -f "$TREE/cli/silent.py" && -f "$TREE/net/tls.py" ]]; then
    pass "全量安装落地（clob/config/net 都在）"
else
    fail "全量的文件没落地（$(tail -3 <<< "$FIRST")）"
fi

if [[ -x "$TREE/lib/selfupdate.sh" ]]; then
    pass "*.sh 带上可执行位"
else
    fail "*.sh 没有可执行位"
fi

SECOND="$(LINUXWAVE_CURRENT_VERSION=9.9.9 run_script "$OUT")"
grep -q "Already at 9.9.9" <<< "$SECOND" && pass "同版本且树完整时不下任何文件" \
    || fail "同版本的短路没生效（$(tail -2 <<< "$SECOND")）"

rm -f "$TREE/cli/silent.py"
THIRD="$(LINUXWAVE_CURRENT_VERSION=9.9.9 run_script "$OUT")"
if grep -q "installed tree is incomplete" <<< "$THIRD" && [[ -f "$TREE/cli/silent.py" ]]; then
    pass "树不完整时自动补齐（同版本也修）"
else
    fail "树不完整时没有补齐（$(tail -2 <<< "$THIRD")）"
fi

# 增量：只下声明的两个文件
rm -rf "$TREE"; mkdir -p "$TREE"
run_script "$OUT" > /dev/null
FOURTH="$(LINUXWAVE_CURRENT_VERSION=9.9.8 run_script "$DELTA_OUT")"
COUNT="$(grep -c '^🌊 Downloading ' <<< "$FOURTH")"
if [[ "$COUNT" == "2" ]]; then
    pass "增量只下变动过的 2 个文件"
else
    fail "增量下了 $COUNT 个文件（期望 2）"
fi

# 逐文件哈希：开启后不符即失败
BAD="$WORK/bad.sh"
generate "$BAD" > /dev/null 2>&1
python3 - "$BAD" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read().splitlines()
out = []
seen = 0
for line in text:
    if line.startswith("    want "):
        seen += 1
        if seen == 1:
            parts = line.split()
            parts[-1] = "0" * 64
            line = "    ".join(parts[:1]) + " " + " ".join(parts[1:])
    out.append(line)
open(path, "w", encoding="utf-8").write("\n".join(out) + "\n")
PY
rm -rf "$TREE"; mkdir -p "$TREE"
if run_script "$BAD" LINUXWAVE_WANT_HASHES=1 LINUXWAVE_STRICT_HASHES=1 > /dev/null 2>&1; then
    fail "哈希不符时严格模式没有失败"
else
    pass "哈希不符时严格模式失败"
fi

echo ""
echo "========== 4. 三档超时：环境变量与 curl 旗标 =========="

collect < <(python3 - "$REPO_DIR" <<'PY'
import sys

repo = sys.argv[1]
sys.path.insert(0, f"{repo}/scripts")
import components
components.add_to_sys_path(repo)

import common


def report(ok, text):
    print(("PASS|" if ok else "FAIL|") + text)


options = common.parse("wave selfupdate --max-time=2min --connect-timeout=10s --content-time=15s")
env = {}
common.export_timeouts(options, env)
report(env.get("LINUXWAVE_MAX_TIME") == "2min", "三条超时按原始文本交给脚本（--max-time）")
report(env.get("LINUXWAVE_CONNECT_TIMEOUT") == "10s", "按原始文本交给脚本（--connect-timeout）")
report(env.get("LINUXWAVE_CONTENT_TIME") == "15s", "按原始文本交给脚本（--content-time）")

args = common.curl_limit_args(options)
joined = " ".join(args)
report("--max-time 120" in joined, "curl 的 --max-time 是 120 秒（2min）")
report("--connect-timeout 10" in joined, "curl 的 --connect-timeout 是 10 秒")
report("--speed-limit 1 --speed-time 15" in joined, "「收不到数据」用 --speed-limit/--speed-time 表达")

# 没给的那一档不设：脚本按自己的默认值走，旧值不该残留
stale = {"LINUXWAVE_MAX_TIME": "stale"}
common.export_timeouts(common.parse("wave selfupdate"), stale)
report("LINUXWAVE_MAX_TIME" not in stale, "没给那一档时清掉旧值（由脚本用自己的默认）")
PY
)

# shell 侧 lw_seconds 与 Python 侧 parse_duration 必须同结论 —— 一份文本两处解析，
# 走散的症状是「命令行写了 1min，curl 拿到 60 或 1」这种没法一眼看出的偏差。
SHELL_SECONDS="$(sed -n '/^lw_seconds() {/,/^}$/p' "$REPO_DIR/lib/selfupdate.sh")"
if [[ -z "$SHELL_SECONDS" ]]; then
    fail "lib/selfupdate.sh 里找不到 lw_seconds()"
else
    MISMATCH="$(python3 - "$REPO_DIR" <<'PY'
import sys

repo = sys.argv[1]
sys.path.insert(0, f"{repo}/scripts")
import components
components.add_to_sys_path(repo)
import domains

for raw in ("40", "40s", "1min", "1min20s", "2h", "250ms", "1.5m"):
    print(f"{raw} {domains.parse_duration(raw)}")
PY
)"
    if [[ -z "$MISMATCH" ]]; then
        # 基线为空 = 被测的 Python 侧一段都没产出（崩了），不能当成「全部一致」
        fail "两侧换算的基准数据没生成（Python 侧崩了？）"
    else
        BAD=""
        while read -r raw expected; do
            got="$(printf '%s\n' "$SHELL_SECONDS" "lw_seconds '$raw'" | bash)"
            [[ "$got" == "$expected" ]] || BAD="${BAD}${raw}: shell=${got} python=${expected}; "
        done <<< "$MISMATCH"
        [[ -z "$BAD" ]] && pass "lw_seconds 与 parse_duration 同结论（7 组写法）" \
            || fail "两侧换算不一致：$BAD"
    fi
fi

echo ""
echo "=========================================="
if [[ "$FAILED" -gt 0 ]]; then
    echo -e "${RED_BOLD}🌊 selfupdate layout tests failed: $FAILED${RESET}"
    echo "=========================================="
    exit 1
fi
echo -e "${GREEN}🌊 All selfupdate layout tests passed (${PASSED} checks).${RESET}"
echo "=========================================="
