#!/bin/bash

# timeout_test.sh
# `--max-time` 的回归（离线）。三件事：
#   1. 时长解析：`40` / `40s` / `1min20s` / `2h` 都认；写错了必须**报错**，
#      不能静默退回默认值——那样用户会以为参数生效了，其实还在用 30 秒；
#   2. 命令行：旗标被解析器接受、它的值不会被当成包名、缺值与畸形值给出用法提示；
#   3. 传导：值写进 LINUXWAVE_MAX_TIME，依赖安装与 selfupdate.sh 读同一个数。

set -u

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
LIB_DIR="$REPO_DIR/lib"
OUT_FILE="$(mktemp)"
trap 'rm -f "$OUT_FILE"' EXIT

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

# python 侧只输出 `PASS|说明` / `FAIL|说明`，计数交给 shell，避免两套计数器打架
collect() {
    local verdict text
    while IFS='|' read -r verdict text; do
        case "$verdict" in
            PASS) pass "$text" ;;
            FAIL) fail "$text" ;;
        esac
    done
}

echo "========== 1. 时长解析 =========="

collect < <(python3 - "$LIB_DIR" <<'PY'
import os
import sys

sys.path.insert(0, sys.argv[1])
import domains


def report(ok, text):
    print(("PASS|" if ok else "FAIL|") + text)


ACCEPT = {
    "40": 40, "40s": 40, "2m": 120, "1min": 60, "1min20s": 80,
    "2h": 7200, "1.5h": 5400, "2d": 172800, "40S": 40, "1MIN": 60, "90 min": 5400,
    "1min20": 80,
}
for text, expect in ACCEPT.items():
    try:
        got = domains.parse_duration(text)
    except ValueError as error:
        got = f"ValueError({error})"
    report(got == expect, f"接受 {text!r} -> {expect}s" + ("" if got == expect else f"（实际 {got!r}）"))

for text in ["", "abc", "10minn", "1min 20", "-5", "0", "1x", "1m2x"]:
    try:
        value = domains.parse_duration(text)
    except ValueError:
        report(True, f"拒绝 {text!r}")
    else:
        report(False, f"拒绝 {text!r}（却得到 {value!r}）")

for raw, expect in (("90", 90), ("2min", 120), ("", domains.DEFAULT_TIMEOUT),
                    ("junk", domains.DEFAULT_TIMEOUT)):
    os.environ["LINUXWAVE_MAX_TIME"] = raw
    got = domains.timeout_from_env()
    report(got == expect, f"LINUXWAVE_MAX_TIME={raw!r} -> {expect}s" +
           ("" if got == expect else f"（实际 {got!r}）"))
os.environ.pop("LINUXWAVE_MAX_TIME", None)
PY
)

echo ""
echo "========== 2. 命令行解析与传导 =========="

collect < <(python3 - "$REPO_DIR" <<'PY'
import os
import sys

for sub in ("lib", "pkg", "surfboard"):
    sys.path.insert(0, f"{sys.argv[1]}/{sub}")

import pkginstaller


def report(ok, text):
    print(("PASS|" if ok else "FAIL|") + text)


report("--max-time" in pkginstaller.ALLOWED_FLAGS, "--max-time 在 install 的白名单里")
report(pkginstaller.parse_flags("wave install jq --max-time=2min") == ["--max-time"],
       "parse_flags 接受 --max-time=2min")
report(pkginstaller.parse_flags("wave install jq --max-time 2min") == ["--max-time"],
       "parse_flags 接受 --max-time 2min")

report(pkginstaller.first_package_token("wave install --max-time=2min jq") == "jq",
       "--max-time=2min 的值不会被当作包名")
report(pkginstaller.first_package_token("wave install --max-time 2min jq") == "jq",
       "--max-time 2min 的值不会被当作包名")

os.environ.pop("LINUXWAVE_MAX_TIME", None)
config = pkginstaller.handle_download_args("wave install jq --max-time=1min20s")
report(config["max_time"] == 80, "--max-time=1min20s 解析为 80 秒")
report(os.environ.get("LINUXWAVE_MAX_TIME") == "80", "同时写进 LINUXWAVE_MAX_TIME")

os.environ.pop("LINUXWAVE_MAX_TIME", None)
config = pkginstaller.handle_download_args("wave install jq")
report(config["max_time"] == 30, "没写时用默认 30 秒")
PY
)

echo ""
echo "========== 3. 错误路径（不联网，解析阶段就该退出） =========="

# 直接跑 lib/wave.py 会加载**已安装**的那份代码（wave.py 把配置里的 lib/ 插到
# sys.path 最前），测的就不是当前工作树了。这里把两个配置目录指向一个临时目录，
# 里面只有 base_dir=<本仓库>，于是加载的是这份源码。
FAKE_CFG="$(mktemp -d)"
printf '{"base_dir": "%s"}\n' "$REPO_DIR" > "$FAKE_CFG/config.json"
trap 'rm -f "$OUT_FILE"; rm -rf "$FAKE_CFG"' EXIT

run_wave() {
    ( cd "$REPO_DIR" && LW_REPO="$REPO_DIR" LW_CFG="$FAKE_CFG" timeout 60 python3 -c '
import os, pathlib, sys
sys.path.insert(0, os.path.join(os.environ["LW_REPO"], "lib"))
import configpaths
fake = pathlib.Path(os.environ["LW_CFG"])
configpaths.SYSTEM_CONFIG_DIR = fake
configpaths.USER_CONFIG_DIR = fake
sys.argv = ["wave"] + sys.argv[1:]
# wave.py 的分发在 `if __name__ == "__main__"` 里，直接 import 什么都不会做；
# runpy 以 __main__ 身份执行同一个文件，才等价于命令行调用。
import runpy
runpy.run_path(os.path.join(os.environ["LW_REPO"], "lib", "wave.py"), run_name="__main__")
' "$@" ) > "$OUT_FILE" 2>&1
    echo $?
}

code=$(run_wave install jq --max-time=abc)
if [[ "$code" != "0" ]] && grep -q 'Cannot parse --max-time' "$OUT_FILE"; then
    pass "畸形时长被拒绝（退出码 $code）"
else
    fail "畸形时长没有被正确拒绝（退出码 $code）"
fi

if grep -q 'Use seconds or a unit' "$OUT_FILE"; then
    pass "报错信息给出可用写法"
else
    fail "报错信息没给出可用写法"
fi

code=$(run_wave install jq --max-time)
if [[ "$code" != "0" ]] && grep -q 'Missing time after --max-time' "$OUT_FILE"; then
    pass "缺值被拒绝（退出码 $code）"
else
    fail "缺值没有被正确拒绝（退出码 $code）"
fi

echo ""
echo "=========================================="
if [[ "$FAILED" -gt 0 ]]; then
    echo -e "${RED_BOLD}🌊 timeout tests failed: $FAILED${RESET}"
    echo "=========================================="
    exit 1
fi
echo -e "${GREEN}🌊 All timeout tests passed (${PASSED} checks).${RESET}"
echo "=========================================="
