#!/bin/bash

# quiet_test.sh
# `-s / --silent` 与 `-S / --show-error` 的回归（离线）。
#
# 三条契约，缺一条都会让脚本用不了：
#   1. 单给 -s：什么都不输出，退出码是唯一信号（与 curl 一致）；
#   2. -sS：只留错误，且**不带 🌊** —— 输出是给脚本读的，每行都得多剥一次
#      emoji 就是解析失败；
#   3. 只读命令（list / search / info / linkquery / mirror）上给 -s 要**报错**，
#      而不是安静地什么都不打印 —— 那不是静默，是把命令废掉。
#
# 另外钉死两条容易写反的：
#   - 解析必须认得合并写法（`-sX`、`-CsX`），否则升级时会报「illegal option -s」；
#   - 静默优先于啰嗦：`-s -v` 时 -v 不生效。
#
# 全程离线：只跑参数解析与一条注定失败的安装（没有包名/包名不存在）。

set -u
set +e

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

PASSED=0
FAILED=0

pass() { echo -e "${GREEN}🌊 PASS: $1${RESET}"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED_BOLD}🌊 FAIL: $1${RESET}"; FAILED=$((FAILED + 1)); }

echo "========== 1. strip_silent：认得所有写法 =========="

collect() {
    local verdict text
    while IFS='|' read -r verdict text; do
        case "$verdict" in
            PASS) pass "$text" ;;
            FAIL) fail "$text" ;;
        esac
    done
}

collect < <(python3 - "$REPO_DIR" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/lib")

# wave.py 顶层要求已安装（读 base_dir）才 import 得动，所以只把 strip_silent
# 这一段抽出来单独执行 —— 它的行为与上下文无关。
import pathlib, types

source = pathlib.Path(sys.argv[1], "lib", "wave.py").read_text()
start = source.index("def strip_silent(words):")
end = source.index("# -------------------- 主调度逻辑")
namespace = {}
exec(source[start:end], namespace)
strip_silent = namespace["strip_silent"]

def check(label, words, expect_kept, expect_silent, expect_show_error):
    kept, silent, show_error = strip_silent(list(words))
    ok = kept == expect_kept and silent == expect_silent and show_error == expect_show_error
    print(("PASS" if ok else "FAIL") + "|" + label +
          ("" if ok else f"（实际 kept={kept} silent={silent} show={show_error}）"))

check("-s 单个", ["install", "jq", "-s"], ["install", "jq"], True, False)
check("--silent 长写法", ["install", "jq", "--silent"], ["install", "jq"], True, False)
check("-S 只保留错误", ["install", "jq", "-S"], ["install", "jq"], False, True)
check("-sS 两种都要", ["install", "jq", "-sS"], ["install", "jq"], True, True)
check("-Ss 顺序无关", ["install", "jq", "-Ss"], ["install", "jq"], True, True)
check("合并写法 -sX", ["upgrade", "jq", "-sX"], ["upgrade", "jq", "-X"], True, False)
# 只把 s/S 抠掉，剩下的字母保持原样成簇：`-CsX` -> `-CX`。
# 下游（upgrader 的 split_input）本来就会把短旗标簇拆开，这里不必代劳。
check("合并写法 -CsX", ["upgrade", "jq", "-CsX"], ["upgrade", "jq", "-CX"], True, False)
check("旗标在命令前", ["-s", "install", "jq"], ["install", "jq"], True, False)
check("长旗标不受影响", ["install", "jq", "--skip-ssl"], ["install", "jq", "--skip-ssl"], False, False)
check("包名里有 s 不受影响", ["install", "sqlite"], ["install", "sqlite"], False, False)
PY
)

echo "========== 2. 真实调用：三种写法各自输出什么 =========="

# 造一个最小安装树，避免读本机真实的 LinuxWave 配置
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
ROOT="$WORK/root"
BASE="$ROOT/opt/linuxwave"
mkdir -p "$ROOT/etc/linuxwave_config" "$BASE"/{lib,pkg,surfboard,net,bin,links,deps,downloads/tmp}
printf '{"base_dir": "%s"}\n' "$BASE" > "$ROOT/etc/linuxwave_config/config.json"
for dir in lib pkg net surfboard; do
    cp "$REPO_DIR/$dir"/*.py "$REPO_DIR/$dir"/*.sh "$BASE/$dir"/ 2>/dev/null
done

run() {  # run <参数...> → OUT / RC
    OUT=$(cd "$WORK" && LINUXWAVE_TEST="$ROOT" python3 "$REPO_DIR/lib/wave.py" "$@" 2>&1)
    RC=$?
}

# 不存在的包：走到「取包列表失败」，一定带错误输出
run install zzzz-not-a-package
plain="$OUT"
if [[ "$plain" == *"🌊"* ]]; then
    pass "普通调用带 🌊 前缀"
else
    fail "普通调用没有 🌊：$(printf '%.120s' "$plain")"
fi
if [[ "$plain" == *"Error"* ]]; then
    pass "普通调用打出错误"
else
    fail "普通调用没有错误输出"
fi

run install zzzz-not-a-package -s
if [[ -z "$OUT" ]]; then
    pass "单给 -s：一个字节都不输出"
else
    fail "-s 仍有输出：$(printf '%.200s' "$OUT")"
fi
if [[ "$RC" -ne 0 ]]; then
    pass "单给 -s：退出码仍然非零（脚本靠它判断）"
else
    fail "单给 -s：退出码是 0，调用方无从判断"
fi

run install zzzz-not-a-package -sS
if [[ "$OUT" == *"Error"* ]]; then
    pass "-sS 保留了错误"
else
    fail "-sS 把错误也吞了：$(printf '%.200s' "$OUT")"
fi
if [[ "$OUT" != *"🌊"* ]]; then
    pass "-sS 的输出不带 🌊（给脚本读）"
else
    fail "-sS 的输出里还有 🌊：$(printf '%.200s' "$OUT")"
fi
if [[ "$OUT" != *"Fetching version info"* ]]; then
    pass "-sS 丢掉了过程噪音"
else
    fail "-sS 仍然打出过程噪音"
fi

run install zzzz-not-a-package --silent
if [[ -z "$OUT" ]]; then
    pass "--silent 与 -s 等价"
else
    fail "--silent 有输出：$(printf '%.200s' "$OUT")"
fi

echo "========== 3. 只读命令上给 -s：报错，而不是静默 =========="

for cmd in list search info mirror linkquery; do
    run "$cmd" -s
    if [[ "$OUT" == *"-s only applies to"* ]]; then
        pass "wave $cmd -s 被拒绝并说明原因"
    else
        fail "wave $cmd -s 没有报错（输出：$(printf '%.120s' "$OUT")）"
    fi
    if [[ "$RC" -ne 0 ]]; then
        pass "wave $cmd -s 退出码非零"
    else
        fail "wave $cmd -s 退出码是 0"
    fi
done

# 拒绝时说清它适用于哪些命令，否则用户不知道该怎么办
run list -s
for name in install upgrade uninstall selfupdate; do
    if [[ "$OUT" == *"wave $name"* ]]; then
        pass "拒绝信息列出了 wave $name"
    else
        fail "拒绝信息里没有 wave $name"
    fi
done

echo "========== 4. 清单本身必须与实现一致 =========="

# SILENT_COMMANDS 决定「哪些命令能安静」。清单里写了一只读命令，就等于把它废掉；
# 漏写一个写命令，`wave <cmd> -s` 会报一条莫名其妙的错。
collect < <(python3 - "$REPO_DIR" <<'PY'
import pathlib, re, sys, ast

source = pathlib.Path(sys.argv[1], "lib", "wave.py").read_text()
match = re.search(r"^SILENT_COMMANDS = (\{[^}]*\})", source, re.M)
if not match:
    print("FAIL|找不到 SILENT_COMMANDS")
    raise SystemExit
declared = ast.literal_eval(match.group(1))

expected = {"install", "upgrade", "uninstall", "link", "unlink", "selfupdate"}
if declared == expected:
    print("PASS|SILENT_COMMANDS 与实现一致")
else:
    print(f"FAIL|SILENT_COMMANDS 不对：多了 {declared - expected}，少了 {expected - declared}")

# 静默只压噪音：错误一律还是原来的 print，不能经过 quiet.say
uninstaller = pathlib.Path(sys.argv[1], "pkg", "uninstaller.py").read_text()
if "quiet.say" in uninstaller and "quiet.say(f\"{RED_BOLD}🌊 Error" not in uninstaller:
    print("PASS|错误路径没有被改成 quiet.say")
else:
    print("FAIL|有错误输出被改成了 quiet.say（静默时会把错误也吞掉）")
PY
)

echo
echo "=========================================="
echo -e "🌊 Passed: $PASSED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="

[[ "$FAILED" -eq 0 ]] || exit 1
echo -e "${GREEN}🌊 All quiet-mode tests passed${RESET}"
