#!/bin/bash

# help_test.sh
# 帮助文本的回归（离线）：排版引擎把「数空格」换成「按最宽标签对齐」之后，
# 有两件事必须一直成立，否则 `wave X --help` 会静默地印错东西：
#   1. COMMANDS 里的每个命令都有帮助条目，反之亦然
#      （缺一条就回落到总帮助，用户看不出是配置漏了）
#   2. 同一节里所有描述从同一列开始
#   3. 真实输出里不带未解析的占位符 / 颜色转义残留
#
# wave.py 在 import 时就会跑环境检查并要求已安装，所以这里不 import 它，
# 只从源码里把 COMMANDS 的键读出来。

set -e

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# 允许指向别的 lib 目录，方便拿一份故意改坏的副本来验证这个测试本身有效。
LIB_DIR="${1:-$REPO_DIR/lib}"

if [[ ! -f "$LIB_DIR/help.py" ]]; then
    echo -e "${RED_BOLD}🌊 Error: help.py not found at $LIB_DIR/help.py${RESET}"
    exit 1
fi

echo "========== help 表格与排版 =========="

python3 - "$LIB_DIR" <<'PY'
import ast
import contextlib
import io
import pathlib
import re
import sys

lib_dir = pathlib.Path(sys.argv[1])
sys.path.insert(0, str(lib_dir))

passed = 0
failed = 0


def pass_(text):
    global passed
    passed += 1
    print(f"\033[32m🌊 PASS: {text}\033[0m")


def fail(text, detail=""):
    global failed
    failed += 1
    print(f"\033[1;31m🌊 FAIL: {text}\033[0m")
    for line in detail.splitlines():
        print(f"    {line}")


import help as h  # noqa: E402

ANSI = re.compile(r"\x1b\[[0-9;]*m")


def render(func, *args):
    buffer = io.StringIO()
    with contextlib.redirect_stdout(buffer):
        func(*args)
    return ANSI.sub("", buffer.getvalue())


# ---------- 1. COMMANDS 与 COMMAND_HELP 必须一一对应 ----------
# 直接解析 wave.py 的 COMMANDS 字面量，不执行它（import 需要已安装的配置）。
tree = ast.parse((lib_dir / "wave.py").read_text())
commands = None
for node in ast.walk(tree):
    if isinstance(node, ast.Assign) and any(
        isinstance(target, ast.Name) and target.id == "COMMANDS" for target in node.targets
    ):
        commands = {key.value for key in node.value.keys}
        break

if commands is None:
    fail("wave.py 里找不到 COMMANDS")
else:
    helped = set(h.COMMAND_HELP)
    missing = sorted(commands - helped)
    extra = sorted(helped - commands)
    if missing or extra:
        fail("COMMANDS 与 COMMAND_HELP 不一致",
             (f"缺帮助: {missing}" if missing else "") +
             ("\n" if missing and extra else "") +
             (f"多出: {extra}" if extra else ""))
    else:
        pass_(f"每个命令都有帮助条目（{len(commands)} 个）")


# ---------- 2. 每个命令的帮助都能独立印出来 ----------
broken = []
for command in sorted(h.COMMAND_HELP):
    text = render(h.print_command_help, command)
    entry = h.COMMAND_HELP[command]
    if f"usage: {entry['usage']}" not in text:
        broken.append(f"{command}: usage 行缺失")
    elif "All commands: wave --help" not in text:
        broken.append(f"{command}: 缺结尾提示")

if broken:
    fail("有命令的帮助输出不完整", "\n".join(broken))
else:
    pass_(f"{len(h.COMMAND_HELP)} 个命令的帮助都完整")


# ---------- 3. 已知命令不会回落到总帮助 ----------
fell_back = [command for command in sorted(h.COMMAND_HELP)
             if "usage: wave <command>" in render(h.print_command_help, command)]

if fell_back:
    fail("这些命令 --help 回落到了总帮助", str(fell_back))
else:
    pass_("已知命令的 --help 都不会回落到总帮助")


# ---------- 4. 同一节内描述列对齐 ----------
# 用三行刻意长短不一的标签测引擎本身：短旗标、带 <值> 的旗标、命令名混排。
rows = [
    (h._flag("--a"), "alpha"),
    (h._flag("--longer-flag", "<string>"), "beta"),
    (h._command("wave something-long"), "gamma"),
    (h._flag("-C, --continue"), "delta"),
]
buffer = io.StringIO()
with contextlib.redirect_stdout(buffer):
    h._print_section("Synthetic", rows)
lines = ANSI.sub("", buffer.getvalue()).splitlines()

# 跳过空行和标题行，剩下的就是数据行
data_lines = [line for line in lines if line.strip() and not line.strip().endswith(":")]
columns = set()
for line, desc in zip(data_lines, [row[1] for row in rows]):
    if not line.endswith(desc):
        columns = {"<描述不完整>"}
        break
    columns.add(len(line) - len(desc))

if len(columns) != 1:
    fail("不齐：描述起始列不一致", f"列位置: {sorted(columns)}")
else:
    pass_(f"不同长度的标签仍从同一列开始（第 {columns.pop()} 列）")


# ---------- 5. 总帮助里没有未解析的占位符 ----------
full = render(h.print_custom_help)
problems = []
if "\x1b" in full:
    problems.append("颜色转义没被清掉（说明有未闭合的 RESET）")
for marker in ("{RESET}", "{PURPLE}", "{GREEN}", "None"):
    if marker in full:
        problems.append(f"输出里出现了 {marker}")
for line in full.splitlines():
    if line != line.rstrip():
        problems.append(f"行尾有多余空白: {line!r}")
        break

if problems:
    fail("总帮助输出不干净", "\n".join(problems))
else:
    pass_("总帮助没有未解析的占位符 / 行尾空白")


print()
print("==========================================")
print(f"🌊 Passed: {passed}")
print(f"🌊 Failed: {failed}")
print("==========================================")
sys.exit(1 if failed else 0)
PY
