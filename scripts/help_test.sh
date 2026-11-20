#!/bin/bash

# help_test.sh
# 帮助文本的回归（离线）。帮助现在完全由 cli/commands.py 这一张表生成，
# 所以这里盯的是「表 → 输出」这段路：
#   1. 每条命令的 summary / usage / desc / examples 都不是空的
#   2. 每条命令的 `--help` 都能独立印出来，且不回落到总帮助
#   3. 排版引擎按最宽标签对齐（数空格的做法一旦回来，长旗标就会错位）
#   4. 总帮助里没有未解析的占位符 / 颜色转义残留
#   5. lib/wave.py 的 COMMANDS 与 cli/commands.py 是同一批命令
#      （漏一条的症状是「帮助里挂着、敲下去是 unknown command」）
#
# wave.py 在 import 时会跑环境检查并要求已安装，所以这里不 import 它，
# 只用 AST 读它的 COMMANDS 字面量。

set -e

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

python3 - "$REPO_DIR" <<'PY'
import ast
import contextlib
import io
import pathlib
import re
import sys

repo = pathlib.Path(sys.argv[1])
sys.path.insert(0, str(repo / "scripts"))
import components

components.add_to_sys_path(repo)

import commands as commands_module  # noqa: E402
import help as h  # noqa: E402

ANSI = re.compile(r"\x1b\[[0-9;]*m")

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


def render(func, *args):
    buffer = io.StringIO()
    with contextlib.redirect_stdout(buffer):
        func(*args)
    return ANSI.sub("", buffer.getvalue())


# ---------- 1. 每条的元数据都完整 ----------
broken = []
for command in commands_module.all():
    for field in ("summary", "usage", "desc"):
        if not getattr(command, field).strip():
            broken.append(f"{command.name}: {field} 是空的")
    if not command.examples:
        broken.append(f"{command.name}: 没有示例")

if broken:
    fail("命令元数据不完整", "\n".join(broken))
else:
    pass_(f"每条命令的 summary/usage/desc/examples 都不空（{len(commands_module.all())} 条）")


# ---------- 2. 每个命令的帮助都能独立印出来 ----------
broken = []
for command in commands_module.all():
    text = render(h.print_command_help, command.name)
    if f"usage: {command.usage}" not in text:
        broken.append(f"{command.name}: usage 行缺失")
    elif "wave --help" not in text:
        broken.append(f"{command.name}: 缺结尾提示")

if broken:
    fail("有命令的帮助输出不完整", "\n".join(broken))
else:
    pass_(f"{len(commands_module.all())} 个命令的帮助都完整")


# ---------- 3. 已知命令不会回落到总帮助 ----------
fell_back = [command.name for command in commands_module.all()
             if "usage: wave <command>" in render(h.print_command_help, command.name)]

if fell_back:
    fail("这些命令 --help 回落到了总帮助", str(fell_back))
else:
    pass_("已知命令的 --help 都不会回落到总帮助")


# ---------- 4. 同一节内描述列对齐 ----------
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


# ---------- 6. 分发只有一条路：命令表 ----------
# 4.0 起 wave.py 不再自带 COMMANDS 字典 / if-elif 链 —— 加命令只改
# cli/commands.py。有人把链加回来时这里变红：那意味着又有了第二份清单，
# 表里有、链上没有的命令会静默地变成 unknown。
wave_text = (repo / "lib" / "wave.py").read_text(encoding="utf-8")
problems = []
if "commands_module.get(" not in wave_text:
    problems.append("lib/wave.py 没有按命令表分发（commands_module.get）")
if "elif module_name ==" in wave_text:
    problems.append("lib/wave.py 里又出现了 if/elif 分发链")
if problems:
    fail("分发不是表驱动", "\n".join(problems))
else:
    pass_("分发只有一条路：cli/commands.py 这张表")


print()
print("==========================================")
print(f"🌊 Passed: {passed}")
print(f"🌊 Failed: {failed}")
print("==========================================")
sys.exit(1 if failed else 0)
PY
