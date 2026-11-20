#!/bin/bash

# shell_lint.sh
# Shell 里的三件「本地看着好、CI 上才炸」的事。
#
# 为什么需要它：同一个错误已经发生过两次 ——
#   1. minos_test 的 SKIP 提示：变量后面直接跟了全角左括号
#      → CI 报 `BACKFILL?: unbound variable`
#   2. 更新脚本的「正在下载」提示：变量后面直接跟了省略号
#      → CI 报 `repo_path?: unbound variable`
# 两次都是**变量后面紧跟一个多字节字符**（全角括号、省略号、全角逗号）。在 UTF-8
# locale 下 bash 能正确断词，本地怎么跑都绿；到了 locale 不是 UTF-8 的环境，那个
# 多字节字符的首字节被读进了变量名，于是「变量不存在」。
#
# 单靠肉眼看不出区别，所以做成检查。修法永远是给变量加花括号：`${VAR}……`。
#
# 第二件事是 `bash -n`：所有脚本的语法检查。它本来就该有，只是以前没人跑。
#
# 第三件事是**不许再叫 `say`**。macOS 自带 `/usr/bin/say`（朗读命令），而我们
# 的双语输出函数以前正好也叫 `say`：把带 `say "…" "…"` 的一行粘进终端（从文档、
# 从源码、从聊天记录里）不会报「command not found」，而是让整台机器大声把参数念
# 出来。已统一改名 `mw_say` / `mw_say_err`，这里挡住回退。
#
# 一次调试时作者在会议室不小心粘贴到 bash 终端，他的 Mac 开始大声播报命令：
# “波浪执行下列命令将 LinuxWave 添加到 PATH，eval（还念成了 evil）…………（此处省略若干字）”
# 以后谁也不许把函数命名为 say！
#
# 第四件事是 `mktemp -t 前缀`。macOS 的 mktemp 会自动补随机后缀，GNU mktemp
# （Linux）要求模板里**至少三个 X**，同一句在那边直接报
# `too few X's in template`。install.sh 的写探针就踩过这个：Linux 上探针永远失败，
# 于是「可写目录」被判成「非权限问题」并中止安装。模板一律写成
# `mktemp "${TMPDIR:-/tmp}/前缀.XXXXXX"`。
#
# 全程离线，秒级。

set -u
set +e

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PYTHON=${PYTHON:-python3}

# 组件目录只有一份清单（scripts/components.txt）。这里手写「lib pkg surfboard」的
# 话就是第二份 —— structure_test 会盯着。
# shellcheck source=./components.sh
source "$SCRIPT_DIR/components.sh"

PASSED=0
FAILED=0

pass() { echo -e "${GREEN}🌊 PASS: $1${RESET}"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED_BOLD}🌊 FAIL: $1${RESET}"; FAILED=$((FAILED + 1)); }

echo "========== 1. 变量后面不许紧跟多字节字符 =========="

OUTPUT=$("$PYTHON" - "$REPO_DIR" <<'PYEOF'
import re
import sys
from pathlib import Path

repo = Path(sys.argv[1])
# $VAR 后面直接跟一个非 ASCII 字符。加花括号的写法（${VAR}…）不会命中，
# 因为变量名后面紧跟的是 `}`。
pattern = re.compile(r"\$([A-Za-z_][A-Za-z0-9_]*)([^\x00-\x7f])")

offenders = []
for path in sorted(repo.rglob("*.sh")):
    if ".git" in path.parts:
        continue
    text = path.read_text(encoding="utf-8", errors="replace")
    for lineno, line in enumerate(text.splitlines(), 1):
        for match in pattern.finditer(line):
            offenders.append(
                f"{path.relative_to(repo)}:{lineno}  "
                f"${match.group(1)} 后面紧跟 {match.group(2)!r}"
                f"  ← 改成 ${{{match.group(1)}}}{match.group(2)}")

for item in offenders:
    print(f"  {item}")
print(f"# {len(offenders)}")
PYEOF
)

COUNT=$(echo "$OUTPUT" | grep -c '^  ')
echo "$OUTPUT" | grep '^  '

if [[ "$COUNT" -eq 0 ]]; then
    pass "没有「变量紧跟多字节字符」的写法"
else
    fail "$COUNT 处写法会在非 UTF-8 locale 下变成 unbound variable（见上）"
fi

echo
echo "========== 2. 每个脚本都能通过 bash -n =========="

SYNTAX_BAD=0
while IFS= read -r script; do
    if ! /bin/bash -n "$script" 2>/dev/null; then
        SYNTAX_BAD=$((SYNTAX_BAD + 1))
        echo -e "${RED_BOLD}  语法错误：${script#"$REPO_DIR"/}${RESET}"
        /bin/bash -n "$script" 2>&1 | head -3 | sed 's/^/    /'
    fi
done < <(
    for _component in $(components); do
        find "$REPO_DIR/$_component" -name '*.sh' -type f 2>/dev/null
    done
    find "$REPO_DIR/scripts" -name '*.sh' -type f 2>/dev/null
)

if [[ "$SYNTAX_BAD" -eq 0 ]]; then
    pass "所有 .sh 都通过 bash -n"
else
    fail "$SYNTAX_BAD 个脚本有语法错误"
fi

echo
echo "========== 3. 不许再用 say / say_err 当函数名 =========="
# 与 macOS 的 /usr/bin/say 同名：粘贴一行就会让机器朗读。见文件头。

SAY_HITS=$("$PYTHON" - "$REPO_DIR" <<'PYEOF'
import re
import sys
from pathlib import Path

repo = Path(sys.argv[1])
# 只认「命令位置上的 say」—— 也就是粘贴到终端会真的被执行的那种：
#   行首（可带缩进）的 say / say_err，或跟在 ; | && ( { 之后的。
# 这样不会误报注释里提到的名字、`/usr/bin/say` 这个真实路径、
# 以及 "aliases mw_say to say" 这类说明文字。
pattern = re.compile(r"(?:^\s*|[;|&({]\s*)say(?:_err)?\b")

# 本文件自己要被排除：它必须写出被禁的那个名字（标题、注释、正则）。
SKIP = {repo / "scripts" / "shell_lint.sh"}

hits = 0
for path in sorted(repo.rglob("*.sh")):
    if ".git" in path.parts or path in SKIP:
        continue
    for lineno, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
        stripped = line.lstrip()
        if stripped.startswith("#"):
            continue
        for match in pattern.finditer(line):
            name = match.group(0).split()[-1].lstrip(";|&({")
            hits += 1
            print(f"  {path.relative_to(repo)}:{lineno}  {name}  ← 改成 mw_{name}")
print(f"# {hits}")
PYEOF
)

SAY_BAD=$(echo "$SAY_HITS" | grep -c '^  ')
echo "$SAY_HITS" | grep '^  '

if [[ "$SAY_BAD" -eq 0 ]]; then
    pass "没有与 macOS say(1) 撞名的函数"
else
    fail "$SAY_BAD 处仍在用 say / say_err（粘贴到终端会让机器朗读）"
fi

echo "========== 4. 不许用只有 bash 5 才有的语法 =========="
# LinuxWave 的最低要求是 bash 4.4（README 与安装器闸门都这么写），所以
# `${var,,}`、`mapfile`、`declare -A`、`&>>` 这些 4.x 特性是**可以**用的 ——
# MacWave 那条规则针对的是 macOS 自带的 3.2，在这里抄过来只会制造噪音。
#
# 真正该挡的是只有 5.x 才有的那几个：5.0 的 EPOCHSECONDS / EPOCHREALTIME /
# SRANDOM，以及 5.1+ 的 `${var@U}` 一类变换。它们在 4.4 上不是「语法错误」而是
# 「展开成空 / 命令不存在」，于是失败发生在很远的地方。
BASH5_BAD=$(grep -rnE '(\$\{[A-Za-z_][A-Za-z0-9_]*@[A-Z]\}|\bEPOCHSECONDS\b|\bEPOCHREALTIME\b|\bSRANDOM\b|^[[:space:]]*wait[[:space:]]+-p\b)' \
    --include=*.sh "$REPO_DIR"/lib "$REPO_DIR"/pkg "$REPO_DIR"/surfboard "$REPO_DIR"/scripts 2>/dev/null \
    | grep -v '^.*shell_lint\.sh:' \
    | grep -vE ':[0-9]+:[[:space:]]*#' || true)

if [[ -z "$BASH5_BAD" ]]; then
    pass "没有 bash 5 专有语法（最低支持 4.4）"
else
    echo "$BASH5_BAD" | sed 's/^/  /'
    fail "$(echo "$BASH5_BAD" | grep -c .) 处用了 bash 5 专有语法；最低支持版本是 4.4"
fi

echo "========== 5. 跑安装器要用 bash，不要写死 /bin/bash =========="
# 与 MacWave 正好相反：LinuxWave 要求 bash 4.4+（`${var,,}`、`declare -A` 都在用），
# 而 macOS 自带的 /bin/bash 是 3.2 —— 写死 /bin/bash 在开发机上必然失败，
# 报出来的样子是「语法错误」而不是「bash 太旧」。安装器自己有版本闸门，
# 所以这里只要求「用 PATH 上的 bash」，由闸门负责解释版本不够时怎么办。
#
# 文档里的 `/bin/bash -c "$(curl …)"` 是另一回事：那是让**用户**跑安装在线的
# 脚本，此时还不知道机器上有没有 bash 4.4，用系统自带的那个是最稳的入口 ——
# 它跑起来第一件事就是检查版本并给出升级命令。这类行（`-c` 形式）不算。
FIXED_BASH=$(cd "$REPO_DIR" && grep -rnE '/bin/bash[[:space:]]+(-|"?\$|[^ -])' \
    --include=*.sh . 2>/dev/null \
    | grep -v '^\./\.git/' \
    | grep -v 'shell_lint\.sh:' \
    | grep -vE ':[0-9]+:[[:space:]]*#' \
    | grep -vE '\-c[[:space:]]' \
    | grep -vE 'useradd.*-s[[:space:]]+/bin/bash' \
    || true)

if [[ -z "$FIXED_BASH" ]]; then
    pass "没有写死 /bin/bash 去跑脚本（用 PATH 上的 bash）"
else
    echo "$FIXED_BASH" | head -20 | sed 's/^/  /'
    fail "$(echo "$FIXED_BASH" | grep -c .) 处写死了 /bin/bash；安装器要 4.4+，请用 bash"
fi

echo
echo "========== 6. mktemp 的模板要带 X =========="

# GNU mktemp 只认带 X 的模板；`mktemp -t 前缀` 是 BSD 的习惯写法，Linux 上报
# "too few X's in template"。这条只看命令位置，注释与文档不算。
BAD_MKTEMP=$(cd "$REPO_DIR" && grep -rnE 'mktemp[[:space:]]+-t[[:space:]]' --include=*.sh . 2>/dev/null \
    | grep -v '^\./\.git/' \
    | grep -v 'shell_lint\.sh:' \
    | grep -vE ':[0-9]+:[[:space:]]*#' \
    || true)

if [[ -z "$BAD_MKTEMP" ]]; then
    pass "没有 mktemp -t（模板都带 X，BSD 与 GNU 都认）"
else
    echo "$BAD_MKTEMP" | head -20 | sed 's/^/  /'
    fail "$(echo "$BAD_MKTEMP" | grep -c .) 处用了 mktemp -t；GNU mktemp 会报 too few X's，请写 mktemp \"\${TMPDIR:-/tmp}/前缀.XXXXXX\""
fi

echo
echo "=========================================="
echo -e "🌊 Passed: $PASSED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="

[[ "$FAILED" -eq 0 ]] || exit 1
echo -e "${GREEN}🌊 All shell lint checks passed${RESET}"
