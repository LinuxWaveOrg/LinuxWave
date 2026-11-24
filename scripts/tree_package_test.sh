#!/bin/bash

# tree_package_test.sh
# 整树软件包（索引里 install: "tree"）的安装、链接、卸载与兼容性。
#
# 为什么需要它：binary 形态只取一个可执行文件，整树形态保留整个解压目录，
# 并把 bin/ 下的命令各链一条。三条路径都容易悄悄坏掉：
#   1. 安装：sh 层要认第 9 行、要写 .is_a_tree、要链**每个**命令，
#      声明的 tree 拿不出主命令时必须失败而不是留个空目录；
#   2. 链接：links/x -> ../bin/x@1/bin/x 比 binary 多一层 bin/，只看
#      目录名的老代码会把所有整树包判成「没链接」；
#   3. 卸载：附属命令的链接名不是包名（git-upload-pack 这种），
#      只按包名删会留下 residue。
#
# 全程离线：假产物自己造，假安装树自己铺。

set -u
set +e

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PYTHON=${PYTHON:-python3}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASSED=0
FAILED=0

pass() { echo -e "${GREEN}🌊 PASS: $1${RESET}"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED_BOLD}🌊 FAIL: $1${RESET}"; FAILED=$((FAILED + 1)); }

# 铺一份只含代码的假安装树：组件目录用软链接指回仓库，安装目录落在假家目录里，
# 于是所有命令都在 LINUXWAVE_TEST 的根下跑，绝不碰真实安装目录。
make_base() {
    local root="$1"
    rm -rf "$root"
    BASE="$root$HOME/.local/linuxwave"
    mkdir -p "$BASE"/{bin,links,deps,downloads/tmp}
    mkdir -p "$root$HOME/.config/linuxwave_config"
    source "$SCRIPT_DIR/components.sh"
    local dir
    for dir in $(components); do
        [[ -d "$REPO_DIR/$dir" ]] || continue
        ln -sfn "$REPO_DIR/$dir" "$BASE/$dir"
    done
    printf '{"base_dir": "%s"}\n' "$BASE" > "$root$HOME/.config/linuxwave_config/config.json"
}

run_wave() { LINUXWAVE_TEST="$ROOT" "$PYTHON" "$BASE/lib/wave.py" "$@"; }

# 造一个整树产物：demo 主命令 + demo-helper 附属命令
make_tree_artifact() {
    local base="$1"
    local craft="$WORK/craft-$RANDOM"
    mkdir -p "$craft/bin" "$craft/share/demo"
    printf '#!/bin/sh\necho demo\n' > "$craft/bin/demo"
    printf '#!/bin/sh\necho helper\n' > "$craft/bin/demo-helper"
    chmod +x "$craft/bin/demo" "$craft/bin/demo-helper"
    printf 'data\n' > "$craft/share/demo/data.txt"
    tar -czf "$base/downloads/tmp/demo-1.0.tar.gz" -C "$craft" . 2>/dev/null
    shasum -a 256 "$base/downloads/tmp/demo-1.0.tar.gz" | awk '{print $1}'
}

install_tree() {  # install_tree <base> <sha> <目标目录> [形态] [kind] [主命令]
    local base="$1" sha="$2" target="$3"
    local mode="${4:-tree}" kind="${5:-package}" bin_name="${6:-demo}"
    ( cd "$base" && bash -c "
        source ./surfboard/depsmanager.sh
        lw_install_artifact \"$bin_name
1.0
$sha
$target
$base
$bin_name

demo-1.0.tar.gz
$mode\" '' '' '$kind'
    " 2>&1 )
}

echo "========== 1. 整树软件包：整棵树落地、每个命令都链 =========="

ROOT="$WORK/root1"
make_base "$ROOT"
SHA="$(make_tree_artifact "$BASE")"
OUT="$(install_tree "$BASE" "$SHA" "$BASE/bin/demo@1.0")"
RC=$?

if [[ "$RC" -eq 0 ]]; then
    pass "整树软件包安装成功"
else
    fail "整树软件包安装失败（rc=$RC）：$(printf '%.300s' "$OUT")"
fi
[[ -f "$BASE/bin/demo@1.0/.is_a_tree" ]] && pass "写下了 .is_a_tree 标记" \
    || fail "没有 .is_a_tree 标记（linker 会把整树包当单文件处理）"
[[ -f "$BASE/bin/demo@1.0/share/demo/data.txt" ]] && pass "整棵树都在（share/ 没被丢掉）" \
    || fail "只留下了可执行文件，树不完整"
# 装完那一刻建的是带版本号的链接（不带版本号的那条由 linker 在安装收尾时建）
[[ -L "$BASE/links/demo@1.0" ]] && pass "主命令有 links/demo@1.0" || fail "主命令没有链接"
[[ -L "$BASE/links/demo-helper@1.0" ]] && pass "附属命令也链了 links/demo-helper@1.0" \
    || fail "附属命令没链（整树包里必须一起用的命令就调不到了）"
TARGET="$(readlink "$BASE/links/demo@1.0")"
[[ "$TARGET" == "../bin/demo@1.0/bin/demo" ]] && pass "链接指向 bin/demo@1.0/bin/demo" \
    || fail "链接指向不对：$TARGET"
TARGET="$(readlink "$BASE/links/demo-helper@1.0")"
[[ "$TARGET" == "../bin/demo@1.0/bin/demo-helper" ]] && pass "附属命令指向 bin/demo@1.0/bin/demo-helper" \
    || fail "附属命令的指向不对：$TARGET"
[[ "$("$BASE/bin/demo@1.0/bin/demo")" == "demo" ]] && pass "装好的命令能跑" || fail "装好的命令跑不起来"

echo "========== 2. 声明的 tree 拿不出主命令 → 失败且不留目录 =========="

ROOT="$WORK/root2"
make_base "$ROOT"
SHA="$(make_tree_artifact "$BASE")"
OUT="$(install_tree "$BASE" "$SHA" "$BASE/bin/demo@1.0" tree package missing-cmd)"
RC=$?
if [[ "$RC" -ne 0 ]]; then
    pass "缺 bin/{主命令} 时安装失败"
else
    fail "缺 bin/{主命令} 居然装成功了"
fi
[[ -d "$BASE/bin/demo@1.0" ]] && fail "失败了却留下安装目录（半成品）" \
    || pass "失败后没有留下安装目录"
[[ -L "$BASE/links/demo" ]] && fail "失败了却建了链接" || pass "失败后没有建链接"
[[ "$OUT" == *"has no bin/missing-cmd"* ]] && pass "报错点出了缺哪个路径" \
    || fail "报错没说缺哪个路径：$(printf '%.200s' "$OUT")"

echo "========== 3. 兼容：老记录（没有第 9 行）仍然是 binary 形态 =========="

ROOT="$WORK/root3"
make_base "$ROOT"
printf 'payload' > "$BASE/downloads/tmp/solo-1.0"
SSHA="$(shasum -a 256 "$BASE/downloads/tmp/solo-1.0" | awk '{print $1}')"
OUT="$(cd "$BASE" && bash -c "
    source ./surfboard/depsmanager.sh
    lw_install_artifact \"solo
1.0
$SSHA
$BASE/bin/solo@1.0
$BASE
solo

solo-1.0\" '' '' 'package'
" 2>&1)"
RC=$?
if [[ "$RC" -eq 0 ]]; then
    pass "老记录（无第 9 行）按 binary 装成功"
else
    fail "老记录装不上（rc=$RC）：$(printf '%.300s' "$OUT")"
fi
[[ -f "$BASE/bin/solo@1.0/solo" && ! -f "$BASE/bin/solo@1.0/.is_a_tree" ]] \
    && pass "落成单文件、没有树标记" || fail "老记录的形态变了（$(ls -A "$BASE/bin/solo@1.0" | tr '\n' ' ')）"

echo "========== 4. 形态来自索引（第 9 行），非法值拒绝 =========="

ROOT="$WORK/root4"
make_base "$ROOT"
SHA="$(make_tree_artifact "$BASE")"
OUT="$(install_tree "$BASE" "$SHA" "$BASE/bin/demo@1.0" tree package)"
[[ -f "$BASE/bin/demo@1.0/.is_a_tree" ]] && pass "索引里的 install: tree 生效" \
    || fail "索引里的 install: tree 没生效（$(printf '%.200s' "$OUT")）"

ROOT="$WORK/root5"
make_base "$ROOT"
SHA="$(make_tree_artifact "$BASE")"
OUT="$(install_tree "$BASE" "$SHA" "$BASE/bin/demo@1.0" tar package)"
RC=$?
[[ "$RC" -ne 0 ]] && pass "未知形态直接拒绝" || fail "未知形态 install: tar 被当成 binary 装了"
[[ "$OUT" == *"Unknown install mode"* ]] && pass "报错说明了是形态问题" \
    || fail "报错没说清原因：$(printf '%.200s' "$OUT")"

echo "========== 5. linker：认得整树包的链接 =========="

ROOT="$WORK/root1"
OUT="$(LINUXWAVE_TEST="$ROOT" "$PYTHON" - "$BASE" <<'PY' 2>&1
import os
import sys

base = sys.argv[1]
sys.path[:0] = [os.path.join(base, d) for d in ("cli", "config", "lib", "net", "pkg", "surfboard")]
os.chdir(base)

import linker

base = linker.BASE_DIR
def report(label, got, want):
    print(("PASS|" if got == want else f"FAIL|{label}：{got!r} != {want!r}|") + label)

report("is_tree_package 认得标记", linker.is_tree_package("demo", "1.0"), True)
report("binary 包不算整树", linker.is_tree_package("solo", "1.0"), False)
report("link_target 多一层 bin/",
       linker.link_target("demo", "1.0"), "../bin/demo@1.0/bin/demo")
report("link_target 指定附属命令",
       linker.link_target("demo", "1.0", "demo-helper"),
       "../bin/demo@1.0/bin/demo-helper")
report("extra_bin_names 列出附属命令",
       linker.extra_bin_names("demo", "1.0"), ["demo-helper"])
report("extra_bin_names 对 binary 包为空",
       linker.extra_bin_names("solo", "1.0"), [])
report("没有不带版本号的链接时 linked_version 返回 None",
       linker.linked_version("demo"), None)
report("is_dangling 对整树包不误报", linker.is_dangling("demo"), False)

# 再装一个版本，`wave link` 的路径也要跟着整树形态走
linked = linker.link_package("demo")
report("link_package 认得整树包", linked, "1.0")
report("不带版本号的链接指向整树里的命令",
       os.readlink(base / "links" / "demo"), "../bin/demo@1.0/bin/demo")
report("不带版本号的附属命令链接也建了",
       os.readlink(base / "links" / "demo-helper"), "../bin/demo@1.0/bin/demo-helper")
report("linked_version 认得整树包", linker.linked_version("demo"), "1.0")
report("linked_version 认得附属命令的链接",
       linker.linked_version("demo-helper"), "1.0")
report("remove_link 连带摘掉附属命令的链接",
       (linker.remove_link("demo"), (base / "links" / "demo-helper").is_symlink()), (True, False))
report("remove_link 之后不带版本号的链接一条不剩",
       sorted(os.listdir(base / "links")), ["demo-helper@1.0", "demo@1.0"])

# 撤掉带版本号的链接（安装时建的），不带版本号的那条要留给人手 unlink
removed = sorted(linker.remove_versioned_links("demo", "1.0"))
report("remove_versioned_links 认领了所有版本化链接", removed,
       ["demo-helper@1.0", "demo@1.0"])
report("带版本号的链接一条不剩", sorted(os.listdir(base / "links")), [])
PY
)"
RC=$?

if [[ "$RC" -eq 0 ]]; then
    pass "linker 段跑完"
else
    fail "linker 段异常退出（rc=$RC）：$(printf '%.300s' "$OUT")"
fi
while IFS='|' read -r tag label detail; do
    [[ -n "$tag" ]] || continue
    if [[ "$tag" == "PASS" ]]; then pass "$label"; else fail "${detail:-$label}"; fi
done <<< "$OUT"

echo "========== 6. 卸载整树包：附属命令的链接不残留 =========="

ROOT="$WORK/root6"
make_base "$ROOT"
SHA="$(make_tree_artifact "$BASE")"
install_tree "$BASE" "$SHA" "$BASE/bin/demo@1.0" >/dev/null
# 安装收尾那一步：不带版本号的链接由 linker 建（这里用真实 CLI 走一遍）
OUT_LINK="$(run_wave link demo 2>&1)"
[[ -L "$BASE/links/demo" && -L "$BASE/links/demo-helper" ]] \
    && pass "wave link 建起了主命令与附属命令的链接" \
    || fail "wave link 没建全：$(ls -A "$BASE/links" | tr '\n' ' ') $(printf '%.200s' "$OUT_LINK")"
[[ "$(readlink "$BASE/links/demo-helper")" == "../bin/demo@1.0/bin/demo-helper" ]] \
    && pass "wave link 按整树形态指向 bin/ 里的命令" \
    || fail "wave link 的指向不对：$(readlink "$BASE/links/demo-helper")"

OUT="$(run_wave uninstall demo@1.0 2>&1)"
RC=$?
if [[ "$RC" -eq 0 ]]; then
    pass "整树包卸载成功"
else
    fail "整树包卸载失败（rc=$RC）：$(printf '%.300s' "$OUT")"
fi
[[ -d "$BASE/bin/demo@1.0" ]] && fail "安装目录还在" || pass "安装目录已删除"
LEFT="$(ls -A "$BASE/links" 2>/dev/null | tr '\n' ' ')"
[[ -z "${LEFT// /}" ]] && pass "links/ 没有残留" || fail "links/ 残留：$LEFT"

echo
echo "=========================================="
echo -e "🌊 Passed: $PASSED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="

[[ "$FAILED" -eq 0 ]] || exit 1
