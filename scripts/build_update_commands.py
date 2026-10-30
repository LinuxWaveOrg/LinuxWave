#!/usr/bin/env python3

# build_update_commands.py

# 生成 4.0 布局里「按版本冻结」的更新脚本：`linuxwavedata/<版本>/update_commands.sh`。
#
# 为什么它是生成物而不是手写：脚本内容随版本变化，手写必然漂移；上游同样由
# 仓库里的脚本生成，并在文件头注明「请勿手工编辑」。
#
# 这一版的做法是**委托**：脚本自己不做逐文件下载，而是取 `$BRANCH` 上的
# `lib/selfupdate.sh` 交给它做（它读 configdata 的 files_info、处理目录迁移、
# 重建启动器）。这样按版本冻结的是「入口」，而细粒度逻辑仍在一处演进。
# 等哪天要改成「只下载真正变动的文件」，改这个生成器即可，客户端一行不用动。
#
# 用法：
#   python3 scripts/build_update_commands.py --version 3.2.0 --branch 3.2 \
#       --output ../configdata-data/linuxwavedata/3.2.0/update_commands.sh

import argparse
import pathlib
import sys

TEMPLATE = '''#!/bin/bash

# LinuxWave update commands — {version}
#
# 由 scripts/build_update_commands.py 生成，请勿手工编辑。
#
# 客户端（`wave selfupdate`）保证以下环境变量：
#
#   LINUXWAVE_INSTALL_DIR      安装根目录
#   LINUXWAVE_CONFIG_DIR       配置目录
#   LINUXWAVE_CORE_URL         代码地址前缀（不含分支）
#   LINUXWAVE_BRANCH           代码分支
#   LINUXWAVE_TARGET_VERSION   目标版本（本脚本所属的版本）
#   LINUXWAVE_CURRENT_VERSION  当前已装版本；首次安装时为空
#   LINUXWAVE_FILE_TIMEOUT     单个文件的超时秒数
#   LINUXWAVE_NEED_SUDO        1 = 安装目录需要 sudo 才能写
#   LINUXWAVE_SILENT           1 = 少打印
#   LINUXWAVE_DRY_RUN          1 = 只报告将要做什么，不落盘
#
# 约定：
#   - 任何一步失败都要 exit 非零；客户端据此判定「什么都没更新」，不写 VERSION.json
#   - 必须幂等：重跑一次不能把已经就位的东西弄坏

set -u

: "${{LINUXWAVE_INSTALL_DIR:?LINUXWAVE_INSTALL_DIR is required}}"
: "${{LINUXWAVE_CORE_URL:?LINUXWAVE_CORE_URL is required}}"
: "${{LINUXWAVE_BRANCH:?LINUXWAVE_BRANCH is required}}"

TARGET_VERSION="{version}"
TIMEOUT="${{LINUXWAVE_FILE_TIMEOUT:-180}}"

# 真正干活的脚本认的是 UPDATE_* 这两个名字，这里做一次映射
export LINUXWAVE_UPDATE_VERSION="${{LINUXWAVE_TARGET_VERSION:-$TARGET_VERSION}}"
export LINUXWAVE_UPDATE_BRANCH="${{LINUXWAVE_BRANCH}}"
export LINUXWAVE_MAX_TIME="$TIMEOUT"

url="$LINUXWAVE_CORE_URL/$LINUXWAVE_BRANCH/lib/selfupdate.sh"

# 先完整落到临时文件再执行，两个原因：
#   1. `bash -c "$(curl …)"` 里 curl 失败时 bash 仍然返回 0，会被误判成更新成功；
#   2. selfupdate.sh 自身就在这次更新要覆盖的文件里 —— 边读边覆盖同一个文件不安全。
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

if ! curl -fsSL --max-time "$TIMEOUT" -o "$tmp" "$url"; then
    echo "🌊 Error: cannot fetch $url" >&2
    echo "🌊 Nothing was updated." >&2
    exit 1
fi

/bin/bash "$tmp"
'''


def render(version, branch):
    return TEMPLATE.format(version=version, branch=branch)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True, help="目标版本，如 3.2.0")
    parser.add_argument("--branch", required=True, help="配套的代码分支，如 3.2")
    parser.add_argument("--output", required=True, help="输出路径（…/linuxwavedata/<版本>/update_commands.sh）")
    args = parser.parse_args()

    text = render(args.version, args.branch)

    output = pathlib.Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(text)
    output.chmod(0o755)

    # 生成的东西至少要能过语法检查，否则等于把一个坏更新器发给用户
    import subprocess
    result = subprocess.run(["/bin/bash", "-n", str(output)], capture_output=True, text=True)
    if result.returncode != 0:
        print(f"🌊 Error: generated script has a syntax error:\n{result.stderr}", file=sys.stderr)
        return 1

    print(f"🌊 Wrote {output} ({len(text)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
