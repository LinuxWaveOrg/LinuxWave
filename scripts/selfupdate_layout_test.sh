#!/bin/bash

# selfupdate_layout_test.sh
# 4.0 自更新布局（`linuxwavedata/latest.toml` + `<版本>/update_commands.sh`）的回归，离线。
#
#   1. `latest.toml` 的解析：真 TOML 写法（`key = "value"`、`#` 注释）要能读，
#      半行残缺或值不带引号要**当作不存在**——否则残缺的半行会被当成版本号；
#   2. 地址：两个函数拼出来必须是 `linuxwavedata/…` 那套；
#   3. 生成器：可重复（同输入逐字节相同）、产物过 `bash -n`、带可执行位、
#      缺必需环境变量时要立刻失败而不是静默跑空。

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
for sub in ("lib", "pkg", "surfboard"):
    sys.path.insert(0, f"{repo}/{sub}")

import domains
import selfupdate


def report(ok, text):
    print(("PASS|" if ok else "FAIL|") + text)


SAMPLE = '''# 注释行不该被当成字段
version = "3.2.0"
release_date = "2026-10-29"

build_number = "302D1838"
branch = "3.2"
broken_line_without_equals
unquoted = 3.2.1
'''
data = selfupdate.parse_toml(SAMPLE)
report(data.get("version") == "3.2.0", "读出 version")
report(data.get("branch") == "3.2", "读出 branch")
report(data.get("build_number") == "302D1838", "读出 build_number（中间隔着空行）")
report("broken_line_without_equals" not in data, "没有等号的行被忽略")
report("unquoted" not in data, "值不带引号的字段被忽略（残缺半行不能当版本号）")
report("# 注释行不该被当成字段" not in data, "注释行被忽略")

# 地址必须落在 linuxwavedata/ 下
latest = domains.selfupdate_latest_url()
report(latest.endswith("/linuxwavedata/latest.toml"), "latest.toml 的地址")
commands = domains.selfupdate_commands_url("3.2.0")
report(commands.endswith("/linuxwavedata/3.2.0/update_commands.sh"), "按版本的 update_commands.sh 地址")
PY
)

echo ""
echo "========== 2. 生成器 =========="

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

OUT="$WORK/linuxwavedata/9.9.9/update_commands.sh"
if python3 "$REPO_DIR/scripts/build_update_commands.py" \
       --version 9.9.9 --branch 9.9 --output "$OUT" > /dev/null 2>&1; then
    pass "生成成功"
else
    fail "生成失败"
fi

if [[ -x "$OUT" ]]; then
    pass "产物带可执行位"
else
    fail "产物没有可执行位"
fi

if bash -n "$OUT" 2>/dev/null; then
    pass "产物通过 bash -n"
else
    fail "产物有语法错误"
fi

grep -q 'TARGET_VERSION="9.9.9"' "$OUT" && pass "注入了版本号" || fail "没注入版本号"
grep -q 'LINUXWAVE_BRANCH' "$OUT" && pass "引用了分支变量" || fail "没引用分支变量"

# 合同：缺必需环境变量时必须立刻失败
if ( unset LINUXWAVE_INSTALL_DIR LINUXWAVE_CORE_URL LINUXWAVE_BRANCH; "$OUT" ) > /dev/null 2>&1; then
    fail "缺必需环境变量时仍然返回成功"
else
    pass "缺必需环境变量时立刻失败"
fi

# 先落临时文件再执行：curl 失败不能被 bash 的退出码掩盖
grep -q 'mktemp' "$OUT" && pass "先落临时文件再执行（不用 bash -c \"\$(curl …)\"）" \
    || fail "仍在用 bash -c \"\$(curl …)\" 的形式"

# 可重复：同样的输入必须产出逐字节相同的文件
cp "$OUT" "$WORK/first.sh"
python3 "$REPO_DIR/scripts/build_update_commands.py" \
    --version 9.9.9 --branch 9.9 --output "$OUT" > /dev/null 2>&1
if cmp -s "$WORK/first.sh" "$OUT"; then
    pass "生成可重复（逐字节相同）"
else
    fail "两次生成不一致"
fi

echo ""
echo "========== 3. 两种布局的优先级与回落 =========="

# fetch_url_text 的 urllib 分支直接认 file://，所以不用起服务器就能验真实取数与解析。
# 域名常量在 import 时求值，因此每个场景都要在**新进程**里设好环境变量。
run_resolve() {
    local root="$1"
    ( cd "$REPO_DIR" && LW_SELFUPDATE="file://$root" PYTHONPATH="$REPO_DIR/lib:$REPO_DIR/pkg:$REPO_DIR/surfboard"       python3 -c '
import os, sys
os.environ["LINUXWAVE_SELFUPDATE_DOMAIN"] = os.environ["LW_SELFUPDATE"]
import selfupdate
data, layout = selfupdate.resolve_release()
if data is None:
    print("none")
else:
    print(f"{layout}|{data.get("version")}|{data.get("branch")}")
' 2>/dev/null )
}

# 只放新布局
NEW="$WORK/new-only"
mkdir -p "$NEW/linuxwavedata/3.2.0"
printf 'version = "3.2.0"\nbranch = "3.2"\n' > "$NEW/linuxwavedata/latest.toml"
result="$(run_resolve "$NEW")"
[[ "$result" == "linuxwavedata|3.2.0|3.2" ]] && pass "有新布局时优先用它" || fail "新布局没被优先采用（拿到 $result）"

# 只放旧布局
OLD="$WORK/old-only"
mkdir -p "$OLD/versiondata"
printf 'version: "3.1.0"\nbranch: "3.1"\nupdate_command: <<< true >>>\n' > "$OLD/versiondata/latest_version"
result="$(run_resolve "$OLD")"
[[ "$result" == "legacy|3.1.0|3.1" ]] && pass "只有旧布局时回落（老镜像不会被打断）" || fail "旧布局回落失败（拿到 $result）"

# 两份都在：新布局优先
BOTH="$WORK/both"
mkdir -p "$BOTH/linuxwavedata" "$BOTH/versiondata"
printf 'version = "3.2.0"\nbranch = "3.2"\n' > "$BOTH/linuxwavedata/latest.toml"
printf 'version: "3.1.0"\nbranch: "3.1"\nupdate_command: <<< true >>>\n' > "$BOTH/versiondata/latest_version"
result="$(run_resolve "$BOTH")"
[[ "$result" == "linuxwavedata|3.2.0|3.2" ]] && pass "两份并存时新布局优先" || fail "并存时选择错误（拿到 $result）"

# 都没有
EMPTY="$WORK/empty"
mkdir -p "$EMPTY"
result="$(run_resolve "$EMPTY")"
[[ "$result" == "none" ]] && pass "都取不到时如实返回 none" || fail "都没有时不该返回 $result"

echo ""
echo "=========================================="
if [[ "$FAILED" -gt 0 ]]; then
    echo -e "${RED_BOLD}🌊 selfupdate layout tests failed: $FAILED${RESET}"
    echo "=========================================="
    exit 1
fi
echo -e "${GREEN}🌊 All selfupdate layout tests passed (${PASSED} checks).${RESET}"
echo "=========================================="
