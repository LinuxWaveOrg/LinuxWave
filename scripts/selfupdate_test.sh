#!/bin/bash

# selfupdate_test.sh
# selfupdate 回归：版本数据解析 → 已是最新时的短路 → 跨大版本被拒绝 → 同大版本的端到端自更新
# 最后一步会真的把安装目录更新一遍，所以放在 CI 的最后执行。
#
# 它需要一个**真实的**配置目录（CI 里由前面几步装好）。本机想跑又不想动系统配置时，
# 把系统级与用户级配置目录都遮掉、只放一份装在 $HOME 下的配置，这样 NEED_SUDO 为 false、
# 不需要 sudo（用户命名空间里 sudo 本来就不可用）：
#
#   unshare -rm bash -c '
#     mount -t tmpfs tmpfs /etc/linuxwave_config
#     mount -t tmpfs tmpfs "$HOME/.config/linuxwave_config"
#     BASE="$HOME/.linuxwave-su-test"; mkdir -p "$BASE"/{lib,pkg,surfboard,downloads/tmp,python}
#     echo "{\"base_dir\": \"$BASE\"}" > "$HOME/.config/linuxwave_config/config.json"
#     echo "{\"version\": \"2.1.0\"}" > "$HOME/.config/linuxwave_config/VERSION.json"
#     cp lib/* pkg/* surfboard/* ...（见 CI 的 Deploy scripts 步骤）
#     bash scripts/selfupdate_test.sh'
#
# 注意：如果本机留着旧版（4.0 之前）的安装，`lib/wave.py` 会优先加载已安装的 lib，
# 那时测的就不是这份工作树了——所以必须先遮掉旧配置。

set -e

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
WAVE_BIN="$REPO_DIR/lib/wave.py"
SELFUPDATE_PY="$REPO_DIR/lib/selfupdate.py"
SELFUPDATE_SH="$REPO_DIR/lib/selfupdate.sh"
BUILDER="$REPO_DIR/scripts/build_update_commands.py"

if [[ ! -f "$WAVE_BIN" ]]; then
    echo -e "${RED_BOLD}🌊 Error: wave.py not found at $WAVE_BIN${RESET}"
    exit 1
fi

# 配置目录：系统级优先，其次用户级
if [[ -f /etc/linuxwave_config/config.json ]]; then
    CONFIG_DIR="/etc/linuxwave_config"
elif [[ -f "$HOME/.config/linuxwave_config/config.json" ]]; then
    CONFIG_DIR="$HOME/.config/linuxwave_config"
else
    echo -e "${RED_BOLD}🌊 Error: LinuxWave not installed (config not found).${RESET}"
    exit 1
fi

CONFIG_FILE="$CONFIG_DIR/config.json"
VERSION_FILE="$CONFIG_DIR/VERSION.json"

if [[ ! -f "$VERSION_FILE" ]]; then
    echo -e "${RED_BOLD}🌊 Error: LinuxWave not installed (VERSION.json not found).${RESET}"
    exit 1
fi

FAILED=0

# ==========================================
# 0. 离线镜像：本测试全程不碰 GitHub
# ==========================================
# selfupdate 的所有对外地址都可由环境变量覆盖（见 lib/selfupdate.sh 的域名块），
# 所以这里把 Core 与 Selfupdate 两个域指到本地 file:// 镜像 —— 与 sandbox_test.sh
# 同一套手法。镜像里装的是**当前工作树**，所以测的是这份代码，不是某个远端提交。

MIRROR_DIR="$(mktemp -d)"
cleanup_mirror() {
    rm -rf "$MIRROR_DIR"
}
trap cleanup_mirror EXIT

MIRROR_BRANCH="main"
PUBLISHED="3.1.0"
TARGET="3.1.1"
mkdir -p "$MIRROR_DIR/core/$MIRROR_BRANCH" "$MIRROR_DIR/selfupdate/linuxwavedata"

tar -C "$REPO_DIR" -cf - \
    --exclude=.git --exclude=.github --exclude=.templates \
    --exclude=.vscode --exclude=.codex --exclude=__pycache__ . \
    | tar -C "$MIRROR_DIR/core/$MIRROR_BRANCH" -xf -

# 更新命令由**真生成器**产出（清单内联的正是要验证的东西）；安装树的内容就是
# 镜像里那份工作树，所以清单与镜像必须来自同一次扫描。
COMPONENTS="$(python3 -c "
import sys; sys.path.insert(0, '$REPO_DIR/scripts')
import components, assets
print(' '.join(components.names() + assets.names()))
")"
FILES="$(python3 - "$REPO_DIR" "$COMPONENTS" <<'GENLIST'
import pathlib
import sys

repo = pathlib.Path(sys.argv[1])
for name in sys.argv[2].split():
    for path in sorted((repo / name).rglob("*")):
        if not path.is_file():
            continue
        if "__pycache__" in path.parts or path.suffix == ".pyc":
            continue
        print(f"{name}/{path.relative_to(repo / name)}")
GENLIST
)"

for version in "$PUBLISHED" "$TARGET"; do
    mkdir -p "$MIRROR_DIR/selfupdate/linuxwavedata/$version"
    python3 "$BUILDER" --version "$version" --branch "$MIRROR_BRANCH" \
        --files $FILES \
        --out "$MIRROR_DIR/selfupdate/linuxwavedata/$version/update_commands.sh" \
        > /dev/null 2>&1 || {
            echo -e "${RED_BOLD}🌊 Error: cannot generate update_commands.sh for $version${RESET}"
            exit 1
        }
done

# 探针里记的哈希钉住「即将被 bash 执行的那份脚本」：第 4 段执行的是 $TARGET 那份
UPDATE_COMMANDS_SHA="$(python3 -c "import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" \
    "$MIRROR_DIR/selfupdate/linuxwavedata/$TARGET/update_commands.sh")"

{
    echo "version = \"$TARGET\""
    echo 'release_date = "2026-01-01"'
    echo 'build_number = "001A0001"'
    echo "branch = \"$MIRROR_BRANCH\""
    echo "update_commands_sha256 = \"$UPDATE_COMMANDS_SHA\""
} > "$MIRROR_DIR/selfupdate/linuxwavedata/latest.toml"

export LINUXWAVE_CORE_DOMAIN="file://$MIRROR_DIR/core"
export LINUXWAVE_SELFUPDATE_DOMAIN="file://$MIRROR_DIR/selfupdate"
export LINUXWAVE_PYTHON_DOMAIN="file://$MIRROR_DIR/selfupdate"
# 离线环境不下载 36MB 的自带解释器；真实产物由 CI 的 portable-python 作业覆盖
export LINUXWAVE_SKIP_PORTABLE_PYTHON=1

echo "🌊 Offline mirror: $MIRROR_DIR"
echo ""

# ==========================================
# 1. 版本数据解析与版本比较（离线，不碰网络）
# ==========================================

echo "========== parse version data =========="

if python3 - "$SELFUPDATE_PY" "$REPO_DIR" << 'PYEOF'
import importlib.util
import sys
from pathlib import Path

selfupdate_py = Path(sys.argv[1])
repo = Path(sys.argv[2])
sys.path.insert(0, str(repo / "scripts"))
import components
components.add_to_sys_path(repo)

spec = importlib.util.spec_from_file_location('selfupdate_module', selfupdate_py)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

# latest.toml 的写法：`key = "value"`，`#` 开头是注释；半行残缺不算字段
sample = (
    '# 注释\n'
    'version = "9.9.9"\n'
    'release_date = "2026-01-01"\n'
    'build_number = "X1"\n'
    'branch = "main"\n'
    'broken_line_without_equals\n'
    'unquoted = 9.9.10\n'
)
data = module.parse_toml(sample)
assert data['version'] == '9.9.9', data
assert data['branch'] == 'main', data
assert data['release_date'] == '2026-01-01', data
assert 'unquoted' not in data, data
assert 'broken_line_without_equals' not in data, data

# 版本比较：补齐到四位，2.3 == 2.3.0，跨位数按数值比
assert module.version_key('2.3') == module.version_key('2.3.0')
assert module.version_key('2.2.0') < module.version_key('2.3')
assert module.version_key('2.10.0') > module.version_key('2.9.0')
assert module.version_key('2.3') >= module.version_key('2.3')

print('🌊 Parsing and version comparison OK')
PYEOF
then
    echo -e "${GREEN}🌊 OK: parse version data${RESET}"
else
    echo -e "${RED_BOLD}🌊 FAIL: parse version data${RESET}"
    FAILED=$((FAILED + 1))
fi

# ==========================================
# 2. 已是最新时必须短路（不会去取更新脚本）
# ==========================================

echo "========== already up to date =========="

python3 - "$VERSION_FILE" << 'PYEOF'
import json
import sys

with open(sys.argv[1], 'w') as handle:
    json.dump({"version": "9999.0", "components": {"installer": "9999.0", "parser": "9999.0"}},
              handle, indent=2)
PYEOF

LOG_FILE="$(mktemp)"
RC=0
python3 "$WAVE_BIN" selfupdate > "$LOG_FILE" 2>&1 || RC=$?
cat "$LOG_FILE"

if [[ "$RC" -eq 0 ]] && grep -q 'already up to date' "$LOG_FILE"; then
    echo -e "${GREEN}🌊 OK: reports up to date${RESET}"
else
    echo -e "${RED_BOLD}🌊 FAIL: expected an up-to-date short circuit (exit $RC)${RESET}"
    FAILED=$((FAILED + 1))
fi
rm -f "$LOG_FILE"

# ==========================================
# 3. 跨大版本必须被拒绝（规则在 selfupdate.sh 里，随目标分支一起发布）
# ==========================================

echo "========== cross-major selfupdate is refused =========="

python3 - "$VERSION_FILE" << 'PYEOF'
import json
import sys

with open(sys.argv[1], 'w') as handle:
    json.dump({"version": "0.1", "components": {"installer": "0.1", "parser": "0.1"}},
              handle, indent=2)
PYEOF

LOG_FILE="$(mktemp)"
RC=0
python3 "$WAVE_BIN" selfupdate > "$LOG_FILE" 2>&1 || RC=$?
cat "$LOG_FILE"

if [[ "$RC" -ne 0 ]] && grep -q 'cannot cross major versions' "$LOG_FILE"; then
    echo -e "${GREEN}🌊 OK: cross-major selfupdate refused${RESET}"
else
    echo -e "${RED_BOLD}🌊 FAIL: expected a cross-major refusal (exit $RC)${RESET}"
    FAILED=$((FAILED + 1))
fi
rm -f "$LOG_FILE"

if [[ "$(python3 -c "import json; print(json.load(open('$VERSION_FILE'))['version'])")" == "0.1" ]]; then
    echo -e "${GREEN}🌊 OK: VERSION.json untouched after the refusal${RESET}"
else
    echo -e "${RED_BOLD}🌊 FAIL: VERSION.json changed despite the refusal${RESET}"
    FAILED=$((FAILED + 1))
fi

# ==========================================
# 4. 同大版本的端到端自更新（真的会改动安装目录，放最后）
# ==========================================

echo "========== end-to-end selfupdate =========="

if ! bash -n "$SELFUPDATE_SH"; then
    echo -e "${RED_BOLD}🌊 FAIL: selfupdate.sh has a syntax error${RESET}"
    FAILED=$((FAILED + 1))
fi

python3 - "$VERSION_FILE" "$PUBLISHED" << 'PYEOF'
import json
import sys

with open(sys.argv[1], 'w') as handle:
    json.dump({"version": sys.argv[2], "components": {"installer": sys.argv[2], "parser": sys.argv[2]}},
              handle, indent=2)
PYEOF

LOG_FILE="$(mktemp)"
RC=0
LINUXWAVE_UPDATE_VERSION="$TARGET" LINUXWAVE_UPDATE_BRANCH="$MIRROR_BRANCH" \
    bash "$SELFUPDATE_SH" > "$LOG_FILE" 2>&1 || RC=$?
cat "$LOG_FILE"

if [[ "$RC" -ne 0 ]]; then
    echo -e "${RED_BOLD}🌊 FAIL: selfupdate.sh exited with $RC${RESET}"
    FAILED=$((FAILED + 1))
fi
rm -f "$LOG_FILE"

# VERSION.json 必须变成目标版本号（这一步同时证明 selfupdate.sh 真的跑过）
if [[ "$(python3 -c "import json; print(json.load(open('$VERSION_FILE'))['version'])")" == "$TARGET" ]]; then
    echo -e "${GREEN}🌊 OK: end-to-end selfupdate ($PUBLISHED -> $TARGET)${RESET}"
else
    echo -e "${RED_BOLD}🌊 FAIL: VERSION.json was not updated to $TARGET${RESET}"
    FAILED=$((FAILED + 1))
fi

# ==========================================
# 5. 清单里列出的文件必须都落到了安装目录
#    2.4 就是漏在这一点上：代码里加了 pkg/linker.py，
#    但清单没同步，自更新后 wave link 直接 ImportError。
#
#    4.0 起清单不再是 configdata 的一份独立文件，而是内联在按版本冻结的
#    update_commands.sh 里（FULL_FILES 段）—— 所以直接读那份产物，测的是
#    「客户端到底执行了什么」。
# ==========================================

echo "========== every listed file landed =========="

BASE_DIR=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE'))['base_dir'])")
COMMANDS_FILE="$MIRROR_DIR/selfupdate/linuxwavedata/$TARGET/update_commands.sh"

FULL_FILES="$(sed -n '/^FULL_FILES="$/,/^"$/p' "$COMMANDS_FILE" | grep -v '^FULL_FILES="' | grep -v '^"$')"

FILE_COUNT=0
MISSING=0
while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    FILE_COUNT=$((FILE_COUNT + 1))
    if [[ ! -e "$BASE_DIR/$rel" ]]; then
        echo -e "${RED_BOLD}🌊 FAIL: $rel was not installed${RESET}"
        MISSING=$((MISSING + 1))
    fi
done <<< "$FULL_FILES"

if [[ "$FILE_COUNT" -eq 0 ]]; then
    echo -e "${RED_BOLD}🌊 FAIL: the manifest parsed to nothing${RESET}"
    FAILED=$((FAILED + 1))
elif [[ "$MISSING" -gt 0 ]]; then
    echo -e "${RED_BOLD}🌊 FAIL: $MISSING of $FILE_COUNT listed file(s) are missing${RESET}"
    FAILED=$((FAILED + 1))
else
    echo -e "${GREEN}🌊 OK: all $FILE_COUNT listed file(s) landed${RESET}"
fi

# ==========================================
# 6. wave.py 里每个命令都要有对应的模块文件
#    这一条独立于清单：即使清单漏写，只要 wave.py 引用了就会报出来
# ==========================================

echo "========== every command resolves to a module =========="

if python3 - "$BASE_DIR" "$REPO_DIR" << 'PYEOF'
import os
import re
import sys

base_dir, repo = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(repo, "scripts"))
import components

# 3.1.0 起 lib/wave 不再是 wave.py 的副本，而是 write_launcher 生成的 sh 启动器
# （自带解释器 + 私有 venv）。命令表要从 lib/wave.py 读。
with open(os.path.join(base_dir, 'lib', 'wave.py'), encoding='utf-8') as handle:
    source = handle.read()

launcher = os.path.join(base_dir, 'lib', 'wave')
if os.path.exists(launcher):
    with open(launcher, encoding='utf-8') as handle:
        if not handle.read(2).startswith('#!'):
            print('🌊 Error: lib/wave is not a launcher (no #! line)')
            sys.exit(1)

block = source.split('COMMANDS = {', 1)[1].split('}', 1)[0]
commands = re.findall(r'"(\w+)"\s*:\s*"(\w+)"', block)
if not commands:
    print('🌊 Error: could not read any entry from COMMANDS')
    sys.exit(1)

missing = []
for command, module in commands:
    if not any(os.path.exists(os.path.join(base_dir, folder, module + '.py'))
               for folder in components.names()):
        missing.append(f'{command} -> {module}.py')

if missing:
    print('🌊 Error: these commands have no module file: ' + ', '.join(missing))
    sys.exit(1)

print(f'🌊 All {len(commands)} command(s) resolve to a module file')
PYEOF
then
    echo -e "${GREEN}🌊 OK: every command module exists${RESET}"
else
    echo -e "${RED_BOLD}🌊 FAIL: a command module is missing after selfupdate${RESET}"
    FAILED=$((FAILED + 1))
fi

# ==========================================
# 汇总
# ==========================================

echo ""
echo "=========================================="
if [[ "$FAILED" -gt 0 ]]; then
    echo -e "${RED_BOLD}🌊 selfupdate tests failed: $FAILED${RESET}"
    echo "=========================================="
    exit 1
fi

echo -e "${GREEN}🌊 All selfupdate tests passed.${RESET}"
echo "=========================================="
exit 0
