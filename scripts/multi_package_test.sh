#!/bin/bash

# multi_package_test.sh
# 一次给多个包：install 与 uninstall 都按逗号（或空格）收多个条目。
#
# 为什么需要它：旧行为是把第一个之后的词**静默丢掉** —— 用户以为装上了，
# `wave list` 里却没有；卸载时同理，剩下的包以为卸了其实还在。规范只有一条：
# 逗号分隔，空格也当分隔；每个条目单独走一遍，一个失败不拖垮其余。
#
# 全程离线：假索引 + 假产物用 python3 -m http.server 起在 localhost，
# 假安装目录用临时 HOME，不碰真实安装、不发外网请求。

set -u

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/components.sh"

FAILED=0
PASSED=0

pass() { echo -e "${GREEN}🌊 PASS: $1${RESET}"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED_BOLD}🌊 FAIL: $1${RESET}"; FAILED=$((FAILED + 1)); }
ok()     { if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1 — 输出里没有「$3」：$(printf "%s" "$2")"; fi; }
not_ok() { if [[ "$2" != *"$3"* ]]; then pass "$1"; else fail "$1 — 输出里不该出现「$3」"; fi; }

strip_ansi() { printf '%s\n' "$1" | sed $'s/\033\\[[0-9;]*m//g'; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/multi_package_test.XXXXXX")
HTTP_PID=""
cleanup() {
    [[ -n "$HTTP_PID" ]] && kill "$HTTP_PID" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

HOME_DIR="$WORK/home"
BASE="$WORK/base"
TEST_ROOT="$WORK/root"
MIRROR="$WORK/mirror"

export LINUXWAVE_TEST="$TEST_ROOT"
mkdir -p "$TEST_ROOT/etc/linuxwave_config" "$HOME_DIR/.config/linuxwave_config" "$BASE"
copy_components "$BASE/"
printf '{"version": "4.5.2"}\n' > "$BASE/VERSION.json"
printf '{"base_dir": "%s"}\n' "$BASE" > "$TEST_ROOT/etc/linuxwave_config/config.json"
printf '{"base_dir": "%s"}\n' "$BASE" > "$HOME_DIR/.config/linuxwave_config/config.json"

USER_SITE=$(python3 -c 'import site; print(site.getusersitepackages())')
if [[ -d "$USER_SITE" ]]; then
    export PYTHONPATH="${PYTHONPATH:+$PYTHONPATH:}$USER_SITE"
fi

ARCH=$(python3 -c 'import platform; m=platform.machine().lower(); print("arm64" if m in ("arm64","aarch64") else "amd64")')
INDEX="$MIRROR/pkg/pkginfo_$ARCH"
mkdir -p "$INDEX"

# 三个包：alpha / beta 正常，broken 故意缺版本记录（走「装不上」的分支）
make_package() {
    local name="$1"
    mkdir -p "$INDEX/$name" "$MIRROR/$name"
    printf 'bin_name: "%s"\n' "$name" > "$INDEX/$name/_${name}@common"

    local payload="$WORK/payload-$name"
    mkdir -p "$payload"
    printf '#!/bin/sh\necho %s\n' "$name" > "$payload/$name"
    chmod +x "$payload/$name"
    tar -czf "$MIRROR/$name/${name}@1.0.${ARCH}.tar.gz" -C "$payload" "$name"

    local sha
    sha=$(shasum -a 256 "$MIRROR/$name/${name}@1.0.${ARCH}.tar.gz" | awk '{print $1}')
    cat > "$INDEX/$name/_${name}@1.0" <<EOF
sha256: "$sha"
file: "${name}-1.0-${ARCH}.tar.gz"
url: "http://127.0.0.1:PORT/${name}/${name}@1.0.${ARCH}.tar.gz"
aut: "LinuxWave Team"
des: "Fixture package for the multiple-package regression"
EOF
    printf '%s@1.0\n%s@common\n' "$name" "$name" > "$INDEX/$name/versions"
}

make_package alpha
make_package beta
mkdir -p "$INDEX/broken"
printf 'broken@1.0\nbroken@common\n' > "$INDEX/broken/versions"
# broken 没有 _broken@1.0 记录 → 取版本记录时失败
printf 'alpha\nbeta\nbroken\n' > "$INDEX/versions"

PORT=$(python3 - <<'PY'
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()
PY
)
# 产物地址里的 PORT 占位换成真实端口
sed -i.bak "s/:PORT/:$PORT/" "$INDEX"/alpha/_alpha@1.0 "$INDEX"/beta/_beta@1.0
rm -f "$INDEX"/alpha/_alpha@1.0.bak "$INDEX"/beta/_beta@1.0.bak

( cd "$MIRROR" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1 ) &
HTTP_PID=$!
for _ in $(seq 1 40); do
    curl -sf -o /dev/null "http://127.0.0.1:$PORT/pkg/pkginfo_$ARCH/versions" && break
    sleep 0.1
done

wave() {
    env -u LINUXWAVE_DEPS_DOMAIN -u LINUXWAVE_CORE_DOMAIN -u LINUXWAVE_SELFUPDATE_DOMAIN \
        HOME="$HOME_DIR" \
        LINUXWAVE_TEST="$TEST_ROOT" \
        LINUXWAVE_API_DOMAIN="http://127.0.0.1:$PORT" \
        LINUXWAVE_BOTTLE_DOMAIN="http://127.0.0.1:$PORT" \
        python3 "$BASE/lib/wave.py" "$@"
}

aged() {  # aged <路径> <天数>
    touch "$1"
    if [[ "$(uname)" == "Darwin" ]]; then
        touch -t "$(date -v-"$2"d +%Y%m%d%H%M)" "$1"
    else
        touch -d "$2 days ago" "$1"
    fi
}

echo "========== 0. install 顺手清掉放太久的 .partial，并说出来 =========="

mkdir -p "$BASE/downloads/tmp"
aged "$BASE/downloads/tmp/old-${ARCH}.tar.gz.partial" 9
aged "$BASE/downloads/tmp/fresh-${ARCH}.tar.gz.partial" 2

out=$(wave install alpha 2>&1); RC=$?
[[ "$RC" -eq 0 ]] && pass "装包本身照常成功" \
    || fail "装包失败（rc=${RC}）：$(printf '%.300s' "$out")"
[[ ! -e "$BASE/downloads/tmp/old-${ARCH}.tar.gz.partial" ]] \
    && pass "9 天前的 .partial 被顺手清掉" || fail "9 天前的 .partial 还在"
[[ -e "$BASE/downloads/tmp/fresh-${ARCH}.tar.gz.partial" ]] \
    && pass "2 天前的 .partial 留着（还能续传）" || fail "2 天前的 .partial 被误删"
ok "输出里告诉用户清掉了陈旧下载" "$(strip_ansi "$out")" "Cleaned up 1 stale partial download(s)"
ok "说清判据是 7 天" "$(strip_ansi "$out")" "untouched for 7+ days"
ok "点名删掉的文件" "$(strip_ansi "$out")" "old-${ARCH}.tar.gz.partial"
rm -f "$BASE/downloads/tmp/fresh-${ARCH}.tar.gz.partial"
wave uninstall alpha >/dev/null 2>&1

echo "========== 1. install：逗号带空格 / 不带空格 / 空格分隔 =========="

out=$(wave install "alpha, beta" 2>&1); RC=$?
[[ "$RC" -eq 0 ]] && pass "install alpha, beta 成功" \
    || fail "install alpha, beta 失败（rc=${RC}）：$(printf '%.300s' "$out")"
[[ -x "$BASE/bin/alpha@1.0/alpha" ]] && pass "第一个包装上了" || fail "第一个包没装上"
[[ -x "$BASE/bin/beta@1.0/beta" ]] && pass "第二个包装上了" || fail "第二个包没装上"
ok "逐个报告进度" "$(strip_ansi "$out")" "[1/2] alpha"

wave uninstall alpha, beta >/dev/null 2>&1

out=$(wave install alpha,beta 2>&1); RC=$?
[[ "$RC" -eq 0 && -x "$BASE/bin/beta@1.0/beta" ]] && pass "逗号后不带空格也认" \
    || fail "alpha,beta 没装上两个（rc=${RC}）：$(printf '%.300s' "$out")"

wave uninstall alpha, beta >/dev/null 2>&1

out=$(wave install alpha beta 2>&1); RC=$?
[[ "$RC" -eq 0 && -x "$BASE/bin/alpha@1.0/alpha" && -x "$BASE/bin/beta@1.0/beta" ]] \
    && pass "空格分隔也认（以前第二个被静默丢掉）" \
    || fail "空格式安装失败（rc=${RC}）：$(printf '%.300s' "$out")"

echo
echo "========== 2. install：一个失败不拖垮其余 =========="

wave uninstall alpha, beta >/dev/null 2>&1
out=$(wave install alpha, broken 2>&1); RC=$?
[[ "$RC" -ne 0 ]] && pass "有失败时退出码非 0" || fail "有失败却返回 0"
[[ -x "$BASE/bin/alpha@1.0/alpha" ]] && pass "失败的那个不影响成功的那个" \
    || fail "alpha 没装上（一个失败拖垮了其余）"
ok "汇总里点名失败的那个" "$(strip_ansi "$out")" "failed broken"
ok "汇总里给出计数" "$(strip_ansi "$out")" "Installed 1 of 2"

echo
echo "========== 3. install：--ver 与多包互斥 =========="

out=$(wave install alpha, beta --ver 1.0 2>&1); RC=$?
[[ "$RC" -ne 0 ]] && pass "--ver 配多个包被拒绝" || fail "--ver 配多个包被放过了"
ok "拒绝时说明怎么改" "$(strip_ansi "$out")" "wave install jq@1.8.2"

out=$(wave install alpha --ver 1.0 2>&1); RC=$?
[[ "$RC" -eq 0 ]] && pass "单包 + --ver 照旧可用" \
    || fail "单包 + --ver 坏了（rc=${RC}）：$(printf '%.300s' "$out")"

echo
echo "========== 4. 单包老写法不变 =========="

out=$(wave install alpha 2>&1); RC=$?
[[ "$RC" -eq 0 ]] && pass "wave install alpha 仍然可用" || fail "单包装不上了"
not_ok "单包时不打 [1/1] 进度行" "$(strip_ansi "$out")" "[1/1]"

echo
echo "========== 5. 全角逗号：解析之前就拦下 =========="

out=$(wave install "alpha，beta" 2>&1); RC=$?
[[ "$RC" -ne 0 ]] && pass "全角逗号被拒绝" || fail "全角逗号被放过了"
ok "指出是全角逗号" "$(strip_ansi "$out")" "full-width comma"
ok "给出半角写法" "$(strip_ansi "$out")" "wave install alpha,beta"

out=$(wave uninstall "alpha，beta" 2>&1); RC=$?
[[ "$RC" -ne 0 ]] && pass "uninstall 也拦全角逗号" || fail "uninstall 放过了全角逗号"

echo
echo "========== 6. uninstall：多个包、多个版本、@all、-a =========="

wave uninstall alpha, beta -a >/dev/null 2>&1
wave install alpha >/dev/null 2>&1
# 造第二个版本：直接把 1.0 复制成 2.0（卸载只看目录名与链接）
cp -R "$BASE/bin/alpha@1.0" "$BASE/bin/alpha@2.0"
cp -R "$BASE/bin/alpha@1.0" "$BASE/bin/beta@1.0" 2>/dev/null

out=$(wave uninstall "alpha@2.0@1.0" 2>&1); RC=$?
[[ "$RC" -eq 0 ]] && pass "同一个包连写多个版本能卸" \
    || fail "连写版本卸载失败（rc=${RC}）：$(printf '%.300s' "$out")"
[[ -d "$BASE/bin/alpha@1.0" || -d "$BASE/bin/alpha@2.0" ]] \
    && fail "连写版本没卸干净：$(ls "$BASE/bin")" || pass "两个版本都卸掉了"

wave install alpha >/dev/null 2>&1
cp -R "$BASE/bin/alpha@1.0" "$BASE/bin/alpha@2.0"

out=$(wave uninstall alpha@all 2>&1); RC=$?
[[ "$RC" -eq 0 ]] && pass "alpha@all 卸掉全部版本" || fail "alpha@all 失败（rc=${RC}）"
[[ -d "$BASE/bin/alpha@1.0" || -d "$BASE/bin/alpha@2.0" ]] \
    && fail "@all 之后还有版本："$(ls "$BASE/bin") || pass "@all 之后一个版本不剩"

wave install alpha >/dev/null 2>&1
cp -R "$BASE/bin/alpha@1.0" "$BASE/bin/alpha@2.0"

out=$(wave uninstall alpha -a 2>&1); RC=$?
[[ "$RC" -eq 0 ]] && pass "-a 等价于 @all" || fail "-a 失败（rc=${RC}）"
[[ -d "$BASE/bin/alpha@1.0" ]] && fail "-a 之后还有版本" || pass "-a 之后一个版本不剩"

wave install alpha >/dev/null 2>&1
cp -R "$BASE/bin/alpha@1.0" "$BASE/bin/alpha@2.0"
out=$(wave uninstall alpha -a --ver 1 2>&1); RC=$?
[[ "$RC" -ne 0 ]] && pass "-a 配别的旗标仍按白名单报错" \
    || fail "-a 配 --ver 被放过了"

out=$(wave uninstall alpha@1.0 -a 2>&1); RC=$?
[[ "$RC" -ne 0 ]] && pass "-a 与显式版本互斥，直接拒绝" || fail "-a 与显式版本没互斥"
ok "互斥时说明两种写法" "$(strip_ansi "$out")" "for every version"

echo
echo "========== 7. uninstall：一个失败不拖垮其余 =========="

wave uninstall alpha -a >/dev/null 2>&1
wave install alpha >/dev/null 2>&1
out=$(wave uninstall alpha, nosuchpkg 2>&1); RC=$?
[[ "$RC" -ne 0 ]] && pass "有失败时退出码非 0" || fail "有失败却返回 0"
[[ -d "$BASE/bin/alpha@1.0" ]] && fail "成功的那个没卸掉" || pass "成功的那个照旧卸掉了"
ok "汇总里给出计数" "$(strip_ansi "$out")" "Uninstalled 1 of 2"
ok "汇总里点名失败的" "$(strip_ansi "$out")" "failed nosuchpkg"

echo
echo "========== 8. uninstall：单个条目的退出码不被汇总层吃掉 =========="

out=$(wave uninstall alpha --ver 1 2>&1); RC=$?
[[ "$RC" -ne 0 ]] && pass "单条目旗标越界 → 退出码 1（曾经是 0）" \
    || fail "单条目失败却返回 0：$(printf '%.200s' "$out")"

echo
echo "=========================================="
echo -e "🌊 Passed: $PASSED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="

[[ "$FAILED" -eq 0 ]] || exit 1
