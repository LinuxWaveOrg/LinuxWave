#!/bin/bash

# doctor_test.sh
# `wave doctor` 的体检：找得出该找的，不误报不该报的，退出码 = 问题数，且**只读**。
#
# 为什么需要它：doctor 的价值全在「报得准」。报错了会让人去删好好的东西；漏报了
# 等于没做。两条都要钉住：造坏树 → 必须报出那一条并给出修复命令；造好树 → 必须全绿。
# 另外钉住「只读」：跑完 doctor，整棵树的 mtime 与内容一个字节都不能变。
#
# 位置无关性那一项要看 ELF 的 RPATH/RUNPATH。真实的 ELF 在 macOS 上造不出来，
# 所以这里塞一个假 patchelf 到 PATH 最前面：它只实现 --print-rpath，答案从同名
# .rpath 文件里读。这样不依赖 patchelf/readelf 装没装，两边平台都能跑。
#
# 全程离线：只摆目录、软链接和带 ELF 魔数的假文件，不下载、不碰真实安装树。

set -u
set +e

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PYTHON=${PYTHON:-python3}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/doctor_test.XXXXXX")
WORK=$(cd "$WORK" && pwd -P)
trap 'rm -rf "$WORK"' EXIT

PASSED=0
FAILED=0
pass() { echo -e "${GREEN}🌊 PASS: $1${RESET}"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED_BOLD}🌊 FAIL: $1${RESET}"; FAILED=$((FAILED + 1)); }

SANDBOX="$WORK/sandbox"
BASE="$SANDBOX/opt/linuxwave"
mkdir -p "$SANDBOX/etc/linuxwave_config" "$BASE"/{bin,links,deps,downloads/tmp}
printf '{"base_dir": "%s"}' "$BASE" > "$SANDBOX/etc/linuxwave_config/config.json"
for component in cli config lib net pkg surfboard; do
    ln -sfn "$REPO_DIR/$component" "$BASE/$component"
done

# 假 patchelf：只回答 --print-rpath，内容取同目录的 .rpath 文件
STUB="$WORK/stub"
mkdir -p "$STUB"
cat > "$STUB/patchelf" <<'STUBEOF'
#!/bin/bash
if [[ "${1:-}" == "--print-rpath" ]]; then
    cat "$2.rpath" 2>/dev/null && exit 0
    exit 1
fi
exit 1
STUBEOF
chmod +x "$STUB/patchelf"

doctor() {  # 输出在 OUT，退出码在 RC
    OUT=$(PATH="$STUB:$PATH" LINUXWAVE_TEST="$SANDBOX" "$PYTHON" "$BASE/lib/wave.py" \
          doctor "$@" 2>&1)
    RC=$?
}

# 造一棵树：healthy / broken 两种形态
build_tree() {  # build_tree healthy|broken
    rm -rf "${BASE:?}/bin" "$BASE/links" "$BASE/deps"
    mkdir -p "$BASE/bin/jq@1.8.2" "$BASE/bin/yq@2.0" "$BASE/links" "$BASE/deps/gcc/gcc@13"
    printf '#!/bin/sh\ntrue\n' > "$BASE/bin/jq@1.8.2/jq"
    printf '#!/bin/sh\ntrue\n' > "$BASE/bin/yq@2.0/yq"
    chmod +x "$BASE/bin/jq@1.8.2/jq" "$BASE/bin/yq@2.0/yq"
    : > "$BASE/deps/gcc/gcc@13/.depped_pkg_jq@1.8.2"
    ln -s ../bin/jq@1.8.2/jq "$BASE/links/jq"
    ln -s ../bin/yq@2.0/yq "$BASE/links/yq"

    # 一个已经是 $ORIGIN 相对的 ELF（假 patchelf 说它是相对的）
    printf '\177ELFfake-relative' > "$BASE/bin/jq@1.8.2/jq.elf"
    printf '$ORIGIN/../lib' > "$BASE/bin/jq@1.8.2/jq.elf.rpath"

    if [ "${1:-healthy}" = "broken" ]; then
        rm -f "$BASE/bin/jq@1.8.2/jq"           # 版本目录里没有可执行文件
        rm -f "$BASE/links/yq"                  # yq 装了但没链接
        ln -s ../bin/gone@9/gone "$BASE/links/gone"   # 悬空链接
        mkdir -p "$BASE/deps/old/old@1"         # 没人引用的依赖树
        mkdir -p "$BASE/bin/broken@1.0.bak"     # 中断留下的备份目录
        printf 'x' > "$BASE/downloads/tmp/a.partial"
        # 还写着绝对路径的 ELF
        printf '\177ELFfake-absolute' > "$BASE/bin/yq@2.0/yq.elf"
        printf '/opt/linuxwave/lib:/usr/lib' > "$BASE/bin/yq@2.0/yq.elf.rpath"
    fi
}

echo "========== 1. 健康的树：全绿、退出码 0 =========="

build_tree healthy
doctor
[[ "$RC" -eq 0 ]] && pass "健康树退出码 0" || fail "健康树退出码是 ${RC}：$(printf '%.300s' "$OUT")"
[[ "$OUT" == *"No problems found"* ]] && pass "说了一句全绿" \
    || fail "没有全绿提示：$(printf '%.300s' "$OUT")"
[[ "$OUT" != *"problem(s) found"* ]] && pass "健康树里没有假问题" \
    || fail "健康树被报出了问题：$(printf '%.400s' "$OUT")"

echo
echo "========== 2. 坏树：每一条都要报出来 =========="

build_tree broken
doctor
[[ "$RC" -gt 0 ]] && pass "有问题时退出码非 0（当前 ${RC}）" || fail "有问题却返回 0"
[[ "$OUT" == *"jq@1.8.2 has no jq"* ]] && pass "报出「版本目录里没有可执行文件」" \
    || fail "漏了缺可执行文件：$(printf '%.400s' "$OUT")"
[[ "$OUT" == *"wave reinstall jq@1.8.2"* ]] && pass "并给出 wave reinstall" \
    || fail "缺可执行文件没给修复命令"
[[ "$OUT" == *"links/gone points at something that is gone"* ]] && pass "报出悬空链接" \
    || fail "漏了悬空链接"
[[ "$OUT" == *"yq is installed but has no unversioned link"* ]] && pass "报出「装了没链接」" \
    || fail "漏了「装了没链接」"
[[ "$OUT" == *"wave link yq"* ]] && pass "并给出 wave link yq" || fail "没给 wave link"
[[ "$OUT" == *"deps/old/old@1 is not referenced"* ]] && pass "报出孤儿依赖树" \
    || fail "漏了孤儿依赖树"
[[ "$OUT" == *"leftover backup directory bin/broken@1.0.bak"* ]] && pass "报出中断留下的 .bak" \
    || fail "漏了 .bak 目录"
[[ "$OUT" == *"unfinished download(s)"* ]] && pass "提醒了没下完的 .partial" \
    || fail "没提 .partial"
[[ "$OUT" == *"bin/yq@2.0 still names an absolute library path"* ]] \
    && pass "报出 RPATH 里还写着绝对路径的 ELF" || fail "漏了绝对 RPATH"
[[ "$OUT" == *"wave transfer yq"* ]] && pass "并给出 wave transfer" || fail "没给 wave transfer"

echo
echo "========== 3. note 不计入退出码 =========="

build_tree healthy
printf 'x' > "$BASE/downloads/tmp/b.partial"
doctor
[[ "$RC" -eq 0 ]] && pass "只有 note 时退出码 0" || fail "note 被算成了问题（rc=${RC}）"
[[ "$OUT" == *"unfinished download(s)"* ]] && pass "但仍然打出来" || fail "note 没打出来"
[[ "$OUT" == *"note(s)"* ]] && pass "汇总里说明了有几条 note" || fail "汇总没提 note"
rm -f "$BASE/downloads/tmp/b.partial"

echo
echo "========== 4. 判断不了的时候记 note，不把包报成坏的 =========="

# 把 patchelf / readelf / objdump 全藏起来：transfer.sh --check 会返回 2
EMPTY="$WORK/empty-bin"
mkdir -p "$EMPTY"
# python3 必须留着（wave 自己就是它跑的）；PATH 里只藏 ELF 检查用的那三个工具
for tool in bash cat find head od tr awk sed mktemp rm dirname basename env; do
    target="$(command -v "$tool" 2>/dev/null)" && ln -sf "$target" "$EMPTY/$tool"
done
# wave 自己要用解释器：把同一个 python 也链进去（否则 rc=127，测的就不是 doctor 了）
ln -sf "$(command -v "$PYTHON")" "$EMPTY/python3"
build_tree broken
rm -f "$BASE/bin/yq@2.0/yq.elf" "$BASE/bin/yq@2.0/yq.elf.rpath"
OUT=$(PATH="$EMPTY" LINUXWAVE_TEST="$SANDBOX" "$PYTHON" "$BASE/lib/wave.py" doctor position 2>&1)
RC=$?
[[ "$RC" -eq 0 ]] && pass "判断不了时退出码 0（不当成问题）" \
    || fail "判断不了被当成了问题（rc=${RC}）：$(printf '%.300s' "$OUT")"
[[ "$OUT" == *"cannot inspect"* ]] && pass "但如实说了一句判断不了" \
    || fail "没说明判断不了：$(printf '%.300s' "$OUT")"

echo
echo "========== 5. --raw：一行一条、可 grep、无 🌊 =========="

build_tree broken
doctor --raw
[[ "$RC" -gt 0 ]] && pass "--raw 的退出码同样非 0" || fail "--raw 退出码是 0"
[[ "$OUT" != *"🌊"* ]] && pass "--raw 里没有 🌊" || fail "--raw 里还有 🌊"
[[ "$OUT" == *"problem"$'\t'* ]] && pass "--raw 的第一列是严重程度（制表符分隔）" \
    || fail "--raw 的格式不对：$(printf '%.300s' "$OUT")"

echo
echo "========== 6. 单跑一个检查项 / --list-checks / 未知旗标 =========="

doctor links
[[ "$RC" -gt 0 ]] && pass "单跑 links 报出了问题" || fail "单跑 links 没报问题"
[[ "$OUT" != *"deps/old"* ]] && pass "没把别的检查项的结果带进来" \
    || fail "单跑 links 却报了依赖问题：$(printf '%.400s' "$OUT")"

doctor base-dir
[[ "$RC" -eq 0 ]] && pass "单跑 base-dir 全绿" || fail "base-dir 报了问题：$(printf '%.300s' "$OUT")"

doctor --list-checks
[[ "$RC" -eq 0 ]] && pass "--list-checks 退出码 0" || fail "--list-checks 返回 ${RC}"
for name in base-dir tree installed links dependencies downloads position; do
    [[ "$OUT" == *"$name"* ]] || fail "--list-checks 少了 ${name}"
done
pass "--list-checks 列出了全部七项"

doctor --bogus
[[ "$RC" -ne 0 ]] && pass "未知旗标被拒绝" || fail "未知旗标被放过了"
[[ "$OUT" == *"--list-checks"* ]] && pass "报错里指向正确用法" || fail "报错没给用法"

echo
echo "========== 7. 只读：跑完树一个字节都没变 =========="

build_tree broken
BEFORE=$(cd "$BASE" && find bin links deps downloads | sort | while read -r path; do
    printf '%s %s\n' "$path" "$(stat -f %m "$path" 2>/dev/null || stat -c %Y "$path")"
done)
doctor > /dev/null
AFTER=$(cd "$BASE" && find bin links deps downloads | sort | while read -r path; do
    printf '%s %s\n' "$path" "$(stat -f %m "$path" 2>/dev/null || stat -c %Y "$path")"
done)
[[ "$BEFORE" == "$AFTER" ]] && pass "doctor 没有改动安装树（含 mtime）" \
    || fail "doctor 改了东西：$(diff <(echo "$BEFORE") <(echo "$AFTER") | head -5)"

echo
echo "========== 8. 组件目录缺失 =========="

# 只拿 surfboard/ 开刀：它是纯 shell，wave.py 不 import 它，删掉之后 Python 还能跑起来，
# 体检才有机会报「组件目录缺失」。删 net/ 之类会让 wave 自己先 ImportError。
build_tree healthy
rm -rf "$BASE/surfboard"
doctor
[[ "$OUT" == *"component(s) missing"*"surfboard"* ]] && pass "报出组件目录缺失" \
    || fail "漏了组件目录缺失：$(printf '%.300s' "$OUT")"
[[ "$OUT" == *"wave selfupdate"* ]] && pass "并给出修复手段（重跑自更新）" \
    || fail "组件缺失没给修复命令"
ln -sfn "$REPO_DIR/surfboard" "$BASE/surfboard"

echo
echo "=========================================="
echo -e "🌊 Passed: $PASSED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="

[[ "$FAILED" -eq 0 ]] || exit 1
