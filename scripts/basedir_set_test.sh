#!/bin/bash

# basedir_set_test.sh
# `wave basedir --set` 的回归：预检、--dry-run 的零副作用、三段式确认、真搬之后的状态。
#
# 为什么需要它：这条命令会**复制整棵安装树并改写 config.json**。它坏掉的方式都很安静：
#   - 预检漏一条 → 把树搬进系统目录、或搬进自己的子目录（无限套娃）；
#   - 确认漏一段 → 手滑回车就换了安装根；
#   - --dry-run 真的动手 → 「预览」变成破坏性操作；
#   - 收尾漏了 venv / rc 的提示 → 搬完 wave 起不来，用户不知道下一步做什么。
# 所以每一段都钉死，包括「输错要中止」。
#
# 三段确认要 tty，这里用 pty 驱动（纯离线）。真搬那一组在临时目录里做完整一遍。

set -u
set +e

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PYTHON=${PYTHON:-python3}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/basedir_set_test.XXXXXX")
WORK=$(cd "$WORK" && pwd -P)
trap 'rm -rf "$WORK"' EXIT

PASSED=0
FAILED=0
pass() { echo -e "${GREEN}🌊 PASS: $1${RESET}"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED_BOLD}🌊 FAIL: $1${RESET}"; FAILED=$((FAILED + 1)); }

# -------------------- 沙箱 --------------------
#
# 配置走测试根里的系统级目录（/etc/linuxwave_config），组件目录用符号链接指回仓库：
# wave 能正常 import，又完全不碰真实安装（LINUXWAVE_TEST 会把 HOME 一起搬进来）。

setup_sandbox() {  # setup_sandbox <名字>：设好 SANDBOX / BASE / CONFIG
    SANDBOX="$WORK/$1"
    BASE="$SANDBOX/opt/linuxwave"
    CONFIG="$SANDBOX/etc/linuxwave_config/config.json"
    mkdir -p "$SANDBOX/etc/linuxwave_config" "$BASE"/{bin,links,deps}
    printf '{"base_dir": "%s"}' "$BASE" > "$CONFIG"
    local component
    for component in cli config lib net pkg surfboard; do
        ln -sfn "$REPO_DIR/$component" "$BASE/$component"
    done
    printf '{"version": "4.6.0"}\n' > "$BASE/VERSION.json"
}

wave() {  # wave <参数...>；OUT / RC 是结果
    OUT=$(LINUXWAVE_TEST="$SANDBOX" "$PYTHON" "$REPO_DIR/lib/wave.py" "$@" < /dev/null 2>&1)
    RC=$?
}

config_base_dir() {
    "$PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1]))["base_dir"])' "$CONFIG"
}

# -------------------- pty 驱动 --------------------

export REPO_DIR PYTHON

drive_set() {  # drive_set <模式>：在 pty 里跑一次 basedir --set，输出与退出码透传
    # 输出同时落盘：进程退出后终端的最后一段容易被丢掉，排错时要能看到完整日志。
    "$PYTHON" - "$SANDBOX" "$BASE" "$SANDBOX/newhome" "$1" "$WORK/pty-$1.log" <<'PY'
import os, pty, select, subprocess, sys, time

sandbox, old, new, mode, log_path = sys.argv[1:6]
repo = os.environ["REPO_DIR"]
python = os.environ.get("PYTHON", sys.executable)

line_yes = b"Yes\n"
line_path = (old + "\n").encode()
sentence = "Yes, I confirm switching basedir to " + new + "."
if mode == "typo-inside":
    # 在中间插一个错字符：实现上输错的位不前进，之后的正确字符仍然对得上 ——
    # 这一条同时证明「打错不会让句子错位」。
    mid = len(sentence) // 2
    line_sentence = (sentence[:mid] + "X" + sentence[mid:] + "\n").encode()
elif mode == "short-sentence":
    line_sentence = (sentence[:-5] + "\n").encode()
else:
    line_sentence = (sentence + "\n").encode()

if mode == "wrong-yes":
    line_yes = b"yes\n"
if mode == "wrong-path":
    line_path = b"/tmp/definitely-not-it\n"

master, slave = pty.openpty()
env = dict(os.environ, LINUXWAVE_TEST=sandbox)
proc = subprocess.Popen([python, repo + "/lib/wave.py", "basedir", "--set", new],
                        stdin=slave, stdout=slave, stderr=slave, env=env, close_fds=True)
os.close(slave)

buf = b""
sent = set()
deadline = time.time() + 90

def drain(timeout):
    global buf
    while select.select([master], [], [], timeout)[0]:
        try:
            data = os.read(master, 4096)
        except OSError:
            return
        if not data:
            return
        buf += data
        timeout = 0

while time.time() < deadline:
    drain(0.1)
    if b"Type Yes exactly" in buf and "yes" not in sent:
        os.write(master, line_yes)
        sent.add("yes")
    elif b"Path:" in buf and "path" not in sent:
        os.write(master, line_path)
        sent.add("path")
    elif b"full stop." in buf and "sentence" not in sent:
        os.write(master, line_sentence)
        sent.add("sentence")
    if proc.poll() is not None:
        break

# 退出后把剩下的读完：一次 drain 往往读不干净，最后一段错误信息就是这么丢的
for _ in range(30):
    drain(0.1)
os.close(master)
with open(log_path, "w", encoding="utf-8", errors="replace") as handle:
    handle.write(buf.decode("utf-8", "replace"))
try:
    proc.wait(timeout=30)
except subprocess.TimeoutExpired:
    proc.kill()
    proc.wait()
sys.stdout.write(buf.decode("utf-8", "replace"))
sys.exit(proc.returncode)
PY
}

echo "========== 1. 预检：错误的目标一个都不落地 =========="

setup_sandbox rejects
wave basedir --set /usr/local
[[ "$RC" -ne 0 ]] && pass "系统目录被拒绝" || fail "/usr/local 被接受了"
[[ ! -e /usr/local/linuxwave ]] && pass "拒绝后什么都没建" || fail "拒绝却建了 /usr/local/linuxwave"

wave basedir --set "$BASE"
[[ "$RC" -ne 0 ]] && pass "搬到自己身上被拒绝" || fail "允许搬到同一路径"
wave basedir --set "$BASE/nested"
[[ "$RC" -ne 0 ]] && pass "搬进自己的子目录被拒绝" || fail "允许无限套娃"
[[ ! -e "$BASE/nested" ]] && pass "以上失败都没有留下目录" || fail "预检失败却建了目录"

mkdir -p "$SANDBOX/occupied" && printf 'x' > "$SANDBOX/occupied/keep"
wave basedir --set "$SANDBOX/occupied"
[[ "$RC" -ne 0 ]] && pass "非空目标被拒绝" || fail "非空目标被接受了"
[[ -f "$SANDBOX/occupied/keep" ]] && pass "目标里的文件没被动" || fail "目标被清空了"

echo
echo "========== 2. 还写着绝对路径的产物：先要求 wave transfer =========="

setup_sandbox absolute
mkdir -p "$BASE/bin/demo@1.0"
printf 'x' > "$BASE/bin/demo@1.0/demo"
# 假 transfer.sh：--check 一律回答「还有绝对路径」（退出码 1）。
# 用 LINUXWAVE_TRANSFER_SCRIPT 指过去，就不必指望真脚本能在 macOS 上解析 ELF。
STUB_CHECK="$WORK/fake-check.sh"
printf '#!/bin/bash\nif [[ "$1" == "--check" ]]; then exit 1; fi\nexit 0\n' > "$STUB_CHECK"
chmod +x "$STUB_CHECK"
OUT=$(LINUXWAVE_TEST="$SANDBOX" LINUXWAVE_TRANSFER_SCRIPT="$STUB_CHECK" \
      "$PYTHON" "$REPO_DIR/lib/wave.py" basedir --set "$SANDBOX/newhome" < /dev/null 2>&1)
RC=$?
[[ "$RC" -ne 0 ]] && pass "有绝对路径产物时拒绝搬家" || fail "带绝对路径也搬了"
[[ "$OUT" == *"wave transfer --all"* ]] && pass "给出了先跑 transfer 的指引" \
    || fail "没说该怎么办：$(printf '%.200s' "$OUT")"
[[ ! -e "$SANDBOX/newhome" ]] && pass "拒绝后没建目标" || fail "拒绝了却建了目标"

echo
echo "========== 3. --dry-run：报告但不动手，且不需要 tty =========="

setup_sandbox dryrun
BEFORE_CONFIG=$(config_base_dir)
wave basedir --set "$SANDBOX/newhome" --dry-run
[[ "$RC" -eq 0 ]] && pass "--dry-run 成功（无 tty 也能跑）" \
    || fail "--dry-run：rc=$RC $(printf '%.200s' "$OUT")"
[[ "$OUT" == *"Dry run"* && "$OUT" == *"config.json"* ]] \
    && pass "--dry-run 打出将要做的事" || fail "--dry-run 输出不完整"
[[ ! -e "$SANDBOX/newhome" ]] && pass "--dry-run 没有创建目标" || fail "--dry-run 创建了目标"
[[ "$(config_base_dir)" == "$BEFORE_CONFIG" ]] \
    && pass "--dry-run 没有改 config.json" || fail "--dry-run 改了 config.json"

echo
echo "========== 4. 三段确认：输错任何一段都中止 =========="

setup_sandbox wrong_yes
OUT=$(drive_set wrong-yes); RC=$?
[[ "$RC" -ne 0 ]] && pass "第一段输错（yes 小写）→ 中止" || fail "第一段输错却继续了"
[[ ! -e "$SANDBOX/newhome" ]] && pass "中止后没有复制任何东西" || fail "中止了却复制了"
[[ "$(config_base_dir)" == "$BASE" ]] && pass "配置没被改" || fail "配置被改了"

setup_sandbox wrong_path
OUT=$(drive_set wrong-path); RC=$?
[[ "$RC" -ne 0 ]] && pass "第二段旧路径打错 → 中止" || fail "旧路径打错却继续了"
[[ ! -e "$SANDBOX/newhome" ]] && pass "中止后没有复制任何东西" || fail "中止了却复制了"

setup_sandbox short_sentence
OUT=$(drive_set short-sentence); RC=$?
[[ "$RC" -ne 0 ]] && pass "第三段句子少几个字 → 不前进、最终中止" \
    || fail "句子没打完却成功了"
[[ ! -e "$SANDBOX/newhome" ]] && pass "中止后没有复制任何东西" || fail "中止了却复制了"

echo
echo "========== 5. 真搬一遍：配置改指新路径，旧树留着 =========="

setup_sandbox real_move
mkdir -p "$BASE/bin/demo@1.0"
printf '#!/bin/sh\necho demo\n' > "$BASE/bin/demo@1.0/demo"
chmod +x "$BASE/bin/demo@1.0/demo"
OUT=$(drive_set full); RC=$?
if [[ "$RC" -eq 0 ]]; then
    pass "完整三段确认后搬家成功"
else
    fail "搬家失败（rc=${RC}），pty 日志尾部："
    tail -25 "$WORK/pty-full.log" 2>/dev/null | sed -e 's/^/      /'
fi
[[ -d "$SANDBOX/newhome" ]] && pass "新路径建好了" || fail "新路径不存在"
[[ -x "$SANDBOX/newhome/bin/demo@1.0/demo" ]] && pass "包跟着搬过去了" \
    || fail "包没搬过去"
[[ "$(config_base_dir)" == "$SANDBOX/newhome" ]] && pass "config.json 指向新路径" \
    || fail "config.json 还指着 $(config_base_dir)"
[[ -d "$BASE" ]] && pass "旧树留着（可回退）" || fail "旧树被删了（回退路径没了）"
[[ "$OUT" == *"lib/wave shellenv"* ]] && pass "提示了 rc 该换的那一行" \
    || fail "没提示 rc 怎么改"
[[ "$OUT" == *"rm -rf"* ]] && pass "提示了确认无误后再删旧树" \
    || fail "没说旧树怎么清"

echo
echo "========== 6. 搬完 wave 仍然可用 =========="

OUT=$(LINUXWAVE_TEST="$SANDBOX" "$PYTHON" "$SANDBOX/newhome/lib/wave.py" basedir --raw 2>&1)
RC=$?
[[ "$RC" -eq 0 && "$OUT" == "$SANDBOX/newhome" ]] \
    && pass "新树里的 wave 认得新安装根" || fail "新树跑不起来：$(printf '%.200s' "$OUT")"

echo
echo "=========================================="
echo -e "🌊 Passed: $PASSED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="

[[ "$FAILED" -eq 0 ]] || exit 1
