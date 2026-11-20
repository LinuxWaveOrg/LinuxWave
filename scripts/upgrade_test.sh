#!/bin/bash

# upgrade_test.sh
# `wave upgrade` 的回归（离线，不联网、不装包）：
#   1. 「同时移除旧版本」的四种写法完全等价，且 `-Xv` 这种短旗标簇也能认；
#   2. `--ver` / `--unlink` 被明确拒绝，并指向替代做法（不是静默忽略）；
#   3. `包名@版本` 被拒绝——upgrade 永远对着索引里的最新版；
#   4. **帮助里只宣传一种写法**，但代码认四种（3.2.0 发布过单数形式，已写进别人的脚本）。
#
# 真正的安装/清理需要真机与网络，由 CI 的端到端作业覆盖。

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

# 段 1/2 只跑纯函数，但 import upgrader 会读配置：给一个隔离的假根，
# 免得测试因为在开发机上找不到真实安装而崩在 import 上。
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; rm -f "$OUT_FILE"' EXIT
mkdir -p "$WORK/root/etc/linuxwave_config" "$WORK/tree"
printf '{"base_dir": "%s"}\n' "$WORK/tree" > "$WORK/root/etc/linuxwave_config/config.json"
export LINUXWAVE_TEST="$WORK/root"

collect() {
    local verdict text before=$PASSED
    while IFS='|' read -r verdict text; do
        case "$verdict" in
            PASS) pass "$text" ;;
            FAIL) fail "$text" ;;
        esac
    done
    # 生产者（python）自己崩了的话，一行 `PASS|` 都不会有 —— 那种「安静地少测」
    # 比失败更危险，因为它看起来是绿的。
    if [[ "$PASSED" -eq "$before" ]]; then
        fail "该段的检查没有产生任何结果（被测代码可能直接崩了）"
    fi
}

echo "========== 1. 四种写法与短旗标簇 =========="

collect < <(python3 - "$REPO_DIR" <<'PY'
import contextlib
import io
import sys

repo = sys.argv[1]
sys.path.insert(0, f"{repo}/scripts")
import components
components.add_to_sys_path(repo)

import upgrader


def report(ok, text):
    print(("PASS|" if ok else "FAIL|") + text)


def quiet(func, *args):
    buffer = io.StringIO()
    with contextlib.redirect_stdout(buffer), contextlib.redirect_stderr(buffer):
        return func(*args)


CANONICAL = ["-X", "--remove-old-versions"]
deprecated = ["--remove-old-version", "--rov"]

for flag in CANONICAL + deprecated:
    words, remove_old, upgrade_all = quiet(upgrader.split_input, f"wave upgrade jq {flag}")
    report(remove_old and words == ["jq"], f"{flag} 等价于移除旧版本")

# 短旗标簇：-Xv = -X -v，剩下的字母要原样留下
words, remove_old, upgrade_all = quiet(upgrader.split_input, "wave upgrade jq -Xv")
report(remove_old and words == ["jq", "-v"], "-Xv 等于 -X -v（-v 保留）")

words, remove_old, upgrade_all = quiet(upgrader.split_input, "wave upgrade jq -vX")
report(remove_old and words == ["jq", "-v"], "-vX 等于 -v -X（-v 保留）")

# 不带 -X 时不该误判
words, remove_old, upgrade_all = quiet(upgrader.split_input, "wave upgrade jq --max-time=2min")
report((not remove_old) and words == ["jq", "--max-time=2min"],
       "普通旗标原样保留，不会被当成 -X")

# --all：批量升级也要在 split_input 里剥掉，否则它会被当成包名带下去
for flag in ("--all", "-a"):
    words, remove_old, upgrade_all = quiet(upgrader.split_input, f"wave upgrade {flag}")
    report(upgrade_all and words == [] and not remove_old, f"{flag} 等价于升级全部")

# 批量与 -X 互不干扰：两个旗标都剥干净，且能同时出现（含短旗标簇）
for text, expect_words, expect_old in (
    ("wave upgrade --all -X", [], True),
    ("wave upgrade -aX", [], True),
    ("wave upgrade -Xav", ["-v"], True),
    ("wave upgrade --all -v", ["-v"], False),
):
    words, remove_old, upgrade_all = quiet(upgrader.split_input, text)
    report(upgrade_all and remove_old == expect_old and words == expect_words,
           f"{text} 剥出 remove_old={expect_old}、剩下 {expect_words or '空'}")

# 单纯带 d 的词不是 --all：只看旗标，不看子串
words, remove_old, upgrade_all = quiet(upgrader.split_input, "wave upgrade jq --max-time=2min")
report(not upgrade_all, "普通旗标不会触发批量模式")

# 被拒绝的两个旗标要有替代做法，而不是静默忽略
report(set(upgrader.REJECTED_FLAGS) == {"--ver", "--no-link", "--unlink"},
       "--ver / --no-link / --unlink 在拒绝名单里")
report("wave install" in upgrader.REJECTED_FLAGS["--ver"],
       "--ver 的提示指向 wave install")
report("wave link" in upgrader.REJECTED_FLAGS["--unlink"],
       "--unlink 的提示指向 wave link")
report("wave link" in upgrader.REJECTED_FLAGS["--no-link"],
       "--no-link 的提示也指向 wave link")
PY
)

echo ""
echo "========== 2. 帮助只宣传一种写法 =========="

collect < <(python3 - "$REPO_DIR" <<'PY'
import contextlib
import io
import re
import sys

repo = sys.argv[1]
sys.path.insert(0, f"{repo}/scripts")
import components
components.add_to_sys_path(repo)
import help as h

ANSI = re.compile(r"\x1b\[[0-9;]*m")


def render(func, *args):
    buffer = io.StringIO()
    with contextlib.redirect_stdout(buffer):
        func(*args)
    return ANSI.sub("", buffer.getvalue())


def report(ok, text):
    print(("PASS|" if ok else "FAIL|") + text)


command_help = render(h.print_command_help, "upgrade")
overview = render(h.print_custom_help)

report("-X, --remove-old-versions" in command_help, "命令帮助里写了规范写法")
report("--remove-old-version " not in command_help and "单数的 --remove-old-version" not in command_help,
       "命令帮助里没有单数写法")
report("--rov" not in command_help and "--rov" not in overview,
       "帮助里完全不提 --rov")
report("-X, --remove-old-versions" in overview, "总帮助的 Special Flags 也写了规范写法")

# 但代码必须继续认四种：文档收敛不能变成行为收缩
import upgrader

accepted = []
for flag in ("-X", "--remove-old-version", "--remove-old-versions", "--rov"):
    words, remove_old, upgrade_all = upgrader.split_input(f"wave upgrade jq {flag}")
    accepted.append(bool(remove_old))
report(all(accepted), "代码仍接受全部四种写法（文档删了、行为没删）")
PY
)

echo ""
echo "========== 3. 拒绝路径（联网之前就退出） =========="

FAKE_CFG="$(mktemp -d)"
printf '{"base_dir": "%s"}\n' "$REPO_DIR" > "$FAKE_CFG/config.json"
trap 'rm -f "$OUT_FILE"; rm -rf "$FAKE_CFG"' EXIT

TIMEOUT_CMD=""
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_CMD="timeout 60"
fi

run_wave() {
    # macOS 自带没有 timeout（coreutils 才有）；没有就不设上限，测试本身很快
    ( cd "$REPO_DIR" && LW_REPO="$REPO_DIR" LW_CFG="$FAKE_CFG" ${TIMEOUT_CMD:-} python3 -c '
import os, pathlib, sys
sys.path.insert(0, os.path.join(os.environ["LW_REPO"], "scripts"))
import components
components.add_to_sys_path(os.environ["LW_REPO"])
import configpaths
fake = pathlib.Path(os.environ["LW_CFG"])
configpaths.SYSTEM_CONFIG_DIR = fake
configpaths.USER_CONFIG_DIR = fake
sys.argv = ["wave"] + sys.argv[1:]
import runpy
runpy.run_path(os.path.join(os.environ["LW_REPO"], "lib", "wave.py"), run_name="__main__")
' "$@" ) > "$OUT_FILE" 2>&1
    echo $?
}

code=$(run_wave upgrade jq@1.2.3)
if [[ "$code" != "0" ]] && grep -q 'upgrade always targets the latest version' "$OUT_FILE"; then
    pass "拒绝 包名@版本（退出码 ${code}）"
else
    fail "没有拒绝 包名@版本（退出码 ${code}）"
fi

if grep -q "wave install jq@1.2.3" "$OUT_FILE"; then
    pass "并指向 wave install <包名>@<版本>"
else
    fail "没给出 wave install 的替代做法"
fi

code=$(run_wave upgrade)
if [[ "$code" != "0" ]] && grep -q 'Missing package name' "$OUT_FILE"; then
    pass "缺包名时给出用法（退出码 ${code}）"
else
    fail "缺包名时没有正确拒绝（退出码 ${code}）"
fi

code=$(run_wave upgrade jq --ver=1.2.3)
if [[ "$code" != "0" ]] && grep -q 'not accepted by upgrade' "$OUT_FILE"; then
    pass "--ver 被 upgrade 拒绝（退出码 ${code}）"
else
    fail "--ver 没有被拒绝（退出码 ${code}）"
fi

# --no-link 与它的旧名 --unlink 都拒绝：替换掉不带版本号的链接是 `wave link` 的事
for flag in --no-link --unlink; do
    code=$(run_wave upgrade jq "$flag")
    if [[ "$code" != "0" ]] && grep -q 'not accepted by upgrade' "$OUT_FILE"; then
        pass "--upgrade 拒绝 ${flag}（退出码 ${code}）"
    else
        fail "upgrade 没有拒绝 ${flag}（退出码 ${code}）"
    fi
done

# --all 与包名互斥：批量是对所有已装包，给一个包名说明用户想表达的是另一件事
code=$(run_wave upgrade --all jq)
if [[ "$code" != "0" ]] && grep -q 'drop the package name' "$OUT_FILE"; then
    pass "--all 与包名同时出现时被拒绝（退出码 ${code}）"
else
    fail "--all 与包名同时出现时没有被拒绝（退出码 ${code}）"
fi

echo ""
echo "=========================================="
if [[ "$FAILED" -gt 0 ]]; then
    echo -e "${RED_BOLD}🌊 upgrade tests failed: $FAILED${RESET}"
    echo "=========================================="
    exit 1
fi
echo -e "${GREEN}🌊 All upgrade tests passed (${PASSED} checks).${RESET}"
echo "=========================================="
