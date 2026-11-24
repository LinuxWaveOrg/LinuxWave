#!/bin/bash

# reinstall_test.sh
# `wave reinstall`：把**已经装着的版本**再装一遍，而不是升级。
#
# 为什么需要它：reinstall 的语义只有一句「同一个包、同一个版本，重来一遍」，而它
# 最容易写错的地方全在「选哪个版本」和「错的时候说什么」：
#   - 没装过 → 该提示 wave install，不是「重装成功」；
#   - 指定的版本没装 → 该点名已装的版本，不是静默换成别的；
#   - -a 与包名混用 → 说不清谁说了算，该拒绝；
#   - --ver → reinstall 不接受（版本来自磁盘），该指向「包名@版本」的写法；
#   - 多个包时一个失败不拖垮其余，末尾汇总。
#
# 真装一遍要联网，所以这里用「假索引 + 假产物 + 本地 http」造一个最小仓库，
# 只验证选版本、汇总、退出码与「确实重新落盘了」（比对文件的 mtime）。
#
# 全程离线。

set -u
set +e

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/components.sh"
PYTHON=${PYTHON:-python3}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/reinstall_test.XXXXXX")
WORK=$(cd "$WORK" && pwd -P)
HTTP_PID=""

# 收尾：停掉假镜像。
# 用 python 的 os.kill 而不是 shell 的 kill —— 端口是随机的，pid 记在变量里，
# 这里只终止本脚本自己起的那个进程。
cleanup() {
    if [[ -n "$HTTP_PID" ]]; then
        "$PYTHON" -c 'import os, signal, sys; os.kill(int(sys.argv[1]), signal.SIGTERM)' \
            "$HTTP_PID" 2>/dev/null
        wait "$HTTP_PID" 2>/dev/null
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

PASSED=0
FAILED=0
pass() { echo -e "${GREEN}🌊 PASS: $1${RESET}"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED_BOLD}🌊 FAIL: $1${RESET}"; FAILED=$((FAILED + 1)); }
ok() { [[ "$2" == *"$3"* ]] && pass "$1" || fail "$1 — 输出里没有「$3」：$(printf '%.200s' "$2")"; }

HOME_DIR="$WORK/home"
BASE="$WORK/base"
TEST_ROOT="$WORK/root"
MIRROR="$WORK/mirror"
export LINUXWAVE_TEST="$TEST_ROOT"
mkdir -p "$TEST_ROOT/etc/linuxwave_config" "$HOME_DIR/.config/linuxwave_config" "$BASE"
copy_components "$BASE/"
printf '{"version": "4.6.0"}\n' > "$BASE/VERSION.json"
printf '{"base_dir": "%s"}\n' "$BASE" > "$TEST_ROOT/etc/linuxwave_config/config.json"
printf '{"base_dir": "%s"}\n' "$BASE" > "$HOME_DIR/.config/linuxwave_config/config.json"

USER_SITE=$(python3 -c 'import site; print(site.getusersitepackages())')
if [[ -d "$USER_SITE" ]]; then
    export PYTHONPATH="${PYTHONPATH:+$PYTHONPATH:}$USER_SITE"
fi

ARCH=$(python3 -c 'import platform; m=platform.machine().lower(); print("arm64" if m in ("arm64","aarch64") else "amd64")')
INDEX="$MIRROR/pkg/pkginfo_$ARCH"
mkdir -p "$INDEX"

# 造一个包的一个版本：产物里只有一个可执行文件
make_package() {
    local name="$1" version="$2"
    mkdir -p "$INDEX/$name" "$MIRROR/$name" "$WORK/payload-$name-$version"
    printf 'bin_name: "%s"\n' "$name" > "$INDEX/$name/_${name}@common"

    printf '#!/bin/sh\necho %s-%s\n' "$name" "$version" > "$WORK/payload-$name-$version/$name"
    chmod +x "$WORK/payload-$name-$version/$name"
    tar -czf "$MIRROR/$name/${name}@${version}.${ARCH}.tar.gz" \
        -C "$WORK/payload-$name-$version" "$name"
    local sha
    sha=$(shasum -a 256 "$MIRROR/$name/${name}@${version}.${ARCH}.tar.gz" | awk '{print $1}')
    cat > "$INDEX/$name/_${name}@${version}" <<EOF
sha256: "$sha"
file: "${name}-${version}-${ARCH}.tar.gz"
url: "http://127.0.0.1:PORT/${name}/${name}@${version}.${ARCH}.tar.gz"
aut: "LinuxWave Team"
des: "Fixture package for the reinstall regression"
EOF
}

make_package demo 1.0
make_package demo 2.0
make_package other 1.0
printf 'demo@2.0\ndemo@1.0\ndemo@common\n' > "$INDEX/demo/versions"
printf 'other@1.0\nother@common\n' > "$INDEX/other/versions"
printf 'demo\nother\n' > "$INDEX/versions"

PORT=$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)
sed -i.bak "s/:PORT/:$PORT/" "$INDEX"/demo/_demo@1.0 "$INDEX"/demo/_demo@2.0 "$INDEX"/other/_other@1.0
rm -f "$INDEX"/demo/_demo@1.0.bak "$INDEX"/demo/_demo@2.0.bak "$INDEX"/other/_other@1.0.bak

( cd "$MIRROR" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1 ) &
HTTP_PID=$!
for _ in $(seq 1 40); do
    curl -sf -o /dev/null "http://127.0.0.1:$PORT/pkg/pkginfo_$ARCH/versions" && break
    sleep 0.1
done

wave() {
    env -u LINUXWAVE_DEPS_DOMAIN -u LINUXWAVE_CORE_DOMAIN -u LINUXWAVE_SELFUPDATE_DOMAIN \
        HOME="$HOME_DIR" LINUXWAVE_TEST="$TEST_ROOT" \
        LINUXWAVE_API_DOMAIN="http://127.0.0.1:$PORT" \
        LINUXWAVE_BOTTLE_DOMAIN="http://127.0.0.1:$PORT" \
        python3 "$BASE/lib/wave.py" "$@"
}

echo "========== 1. 装两个版本，再按「已装的最新版」重装 =========="

wave install demo@1.0 >/dev/null 2>&1
wave install demo@2.0 >/dev/null 2>&1
[[ -x "$BASE/bin/demo@2.0/demo" ]] && pass "前置：两个版本都装上了" \
    || fail "前置安装失败：$(ls "$BASE/bin" 2>/dev/null | tr '\n' ' ')"

# 判据是**内容**，不是 mtime：产物从 tar 里 mv 出来，tar 保留原始 mtime，
# 重装前后那个时间戳本来就不会变。所以先把装好的二进制改坏，再看重装能不能救回来
# —— 这也正是 wave doctor 报「版本目录里没有可执行文件」时建议的那条修复路径。
printf 'corrupted\n' > "$BASE/bin/demo@2.0/demo"
out=$(wave reinstall demo 2>&1); RC=$?
[[ "$RC" -eq 0 ]] && pass "重装成功" || fail "重装失败（rc=${RC}）：$(printf '%.300s' "$out")"
[[ "$("$BASE/bin/demo@2.0/demo")" == "demo-2.0" ]] \
    && pass "被改坏的二进制被还原了（内容回来了）" \
    || fail "重装没有还原文件内容：$("$BASE/bin/demo@2.0/demo" 2>&1)"
[[ -d "$BASE/bin/demo@1.0" ]] && pass "不带版本号时只碰最新版，1.0 不动" \
    || fail "把 1.0 也删了/改了"
[[ "$(readlink "$BASE/links/demo")" == "../bin/demo@2.0/demo" ]] \
    && pass "不带版本号的链接仍指向 2.0" || fail "链接被改到别处：$(readlink "$BASE/links/demo")"

echo
echo "========== 2. 指定版本：装着的才认 =========="

out=$(wave reinstall demo@1.0 2>&1); RC=$?
[[ "$RC" -eq 0 ]] && pass "重装指定版本 demo@1.0 成功" || fail "重装 demo@1.0 失败（rc=${RC}）"
# 与 `wave install demo@1.0` 同一语义：装哪个版本，不带版本号的链接就指向哪个版本。
# 想让它回到最新版就再跑一次 `wave link demo`。
[[ "$(readlink "$BASE/links/demo")" == "../bin/demo@1.0/demo" ]] \
    && pass "重装 @1.0 后链接指向 1.0（与 install 同语义）" \
    || fail "链接指向不对：$(readlink "$BASE/links/demo")"
wave link demo >/dev/null 2>&1
[[ "$(readlink "$BASE/links/demo")" == "../bin/demo@2.0/demo" ]] \
    && pass "wave link 能把它指回最高版本" || fail "wave link 没能指回 2.0"

out=$(wave reinstall demo@9.9 2>&1); RC=$?
[[ "$RC" -ne 0 ]] && pass "没装的版本被拒绝" || fail "demo@9.9 竟然「重装」成功了"
ok "点名已装的版本" "$out" "installed: 2.0, 1.0"

echo
echo "========== 3. 没装过的包：提示用 install =========="

out=$(wave reinstall nosuchpkg 2>&1); RC=$?
[[ "$RC" -ne 0 ]] && pass "没装过的包被拒绝" || fail "没装过的包返回 0"
ok "提示改用 wave install" "$out" "wave install nosuchpkg"

echo
echo "========== 4. --ver / -a 的用法边界 =========="

out=$(wave reinstall demo --ver 2.0 2>&1); RC=$?
[[ "$RC" -ne 0 ]] && pass "--ver 被拒绝" || fail "--ver 被接受了"
ok "指向包名带版本的写法" "$out" "wave reinstall jq@1.8.2"

out=$(wave reinstall demo -a 2>&1); RC=$?
[[ "$RC" -ne 0 ]] && pass "-a 与包名混用被拒绝" || fail "-a 与包名混用被接受了"

out=$(wave reinstall 2>&1); RC=$?
[[ "$RC" -ne 0 ]] && pass "不给包名时被拒绝" || fail "不给包名也返回了 0"
ok "给出两种写法" "$out" "wave reinstall --all"

echo
echo "========== 5. --all：每个已装版本都重装一遍 =========="

wave install other@1.0 >/dev/null 2>&1
out=$(wave reinstall --all 2>&1); RC=$?
[[ "$RC" -eq 0 ]] && pass "--all 成功" || fail "--all 失败（rc=${RC}）：$(printf '%.300s' "$out")"
ok "汇总里给出计数" "$out" "Reinstalled"
[[ -x "$BASE/bin/other@1.0/other" ]] && pass "另一个包还在" || fail "other 被弄丢了"

echo
echo "========== 6. 多包：一个失败不拖垮其余 =========="

# 多包先整体校验再动手：有一条「根本没装」就整批拒绝并点名 —— 与 MacWave 一致。
# 好处是不会装到一半才发现第三个包压根不存在；代价是一个坏名字挡住其余。
out=$(wave reinstall demo, nosuchpkg 2>&1); RC=$?
[[ "$RC" -ne 0 ]] && pass "有失败时退出码非 0" || fail "有失败却返回 0"
ok "点名没装的那个" "$out" "not installed, so there is nothing to reinstall: nosuchpkg"
ok "给出改用 install 的提示" "$out" "wave install nosuchpkg"
[[ -x "$BASE/bin/demo@2.0/demo" ]] && pass "已装的那个原封不动（整批没动手）" \
    || fail "demo 被弄丢了"

echo
echo "========== 7. --raw：装一遍的输出与 install --raw 同族 =========="

out=$(wave reinstall demo --raw 2>&1); RC=$?
[[ "$RC" -eq 0 ]] && pass "--raw 重装成功" || fail "--raw 失败（rc=${RC}）：$(printf '%.300s' "$out")"
[[ "$out" != *"🌊"* ]] && pass "--raw 里没有 🌊" || fail "--raw 里还有 🌊"

echo
echo "========== 8. -s：一句话都不说，只留退出码 =========="

out=$(wave reinstall demo -s 2>&1); RC=$?
[[ "$RC" -eq 0 ]] && pass "-s 重装成功" || fail "-s 失败（rc=${RC}）"
[[ -z "$out" ]] && pass "-s 没有任何输出" || fail "-s 还有输出：$(printf '%.200s' "$out")"

echo
echo "=========================================="
echo -e "🌊 Passed: $PASSED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="

[[ "$FAILED" -eq 0 ]] || exit 1
