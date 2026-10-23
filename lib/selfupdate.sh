#!/bin/bash

# LinuxWave 🌊 Self Updater
# Re-downloads every LinuxWave code file and refreshes VERSION.json in the
# active config dir (/etc/linuxwave_config or ~/.config/linuxwave_config).
# Invoked by `wave selfupdate` through the update_command field in
# configdata/versiondata/latest_version, or directly:
#   bash lib/selfupdate.sh [branch]        (defaults to HEAD)

set -e

# ==========================================
# 颜色定义
# ==========================================

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'

# ==========================================
# 目标仓库、分支与版本
# ==========================================

REPO="LinuxWaveOrg/LinuxWave"
BRANCH="${LINUXWAVE_UPDATE_BRANCH:-${1:-HEAD}}"
BASE_URL="https://raw.githubusercontent.com/$REPO/$BRANCH"
CONFIGDATA_URL="https://raw.githubusercontent.com/LinuxWaveOrg/configdata/main"
VERSION_DATA_URL="$CONFIGDATA_URL/versiondata/latest_version"

# -------------------- 测试根（隔离） --------------------
# LINUXWAVE_TEST 指向一个目录时，把它当作 /：HOME 和所有系统路径都挂到它下面，
# 整条链路都落在那个目录里，完全不碰真实系统。
# 没设置时 SYS_ROOT 为空，下面 "$SYS_ROOT/etc/..." 就还是 "/etc/..."，行为不变。
SYS_ROOT=""
if [[ -n "${LINUXWAVE_TEST:-}" ]]; then
    _lw_root="$LINUXWAVE_TEST"
    if [[ "$_lw_root" == "~"* ]]; then
        _lw_root="${HOME}${_lw_root#\~}"
    fi
    mkdir -p "$_lw_root"
    SYS_ROOT="$(cd "$_lw_root" && pwd)"
    export HOME="$SYS_ROOT${HOME}"
    export LINUXWAVE_TEST_ROOT="$SYS_ROOT"
    mkdir -p "$HOME"
    echo "🌊 Test root: $SYS_ROOT"
fi

# 配置目录：系统级优先，其次用户级（与 lib/configpaths.py 的规则一致）
# 迁移可能把配置搬到用户级位置，所以做成函数，迁移之后要再解析一次。
SYSTEM_CONFIG_DIR="$SYS_ROOT/etc/linuxwave_config"
USER_CONFIG_DIR="$HOME/.config/linuxwave_config"

resolve_config_dir() {
    CONFIG_DIR=""
    for candidate in "$SYSTEM_CONFIG_DIR" "$USER_CONFIG_DIR"; do
        if [[ -f "$candidate/config.json" ]]; then
            CONFIG_DIR="$candidate"
            break
        fi
    done

    if [[ -z "$CONFIG_DIR" ]]; then
        echo -e "${RED_BOLD}🌊 Error: LinuxWave is not installed (no config.json in $SYSTEM_CONFIG_DIR or $USER_CONFIG_DIR).${RESET}"
        echo -e "${RED_BOLD}🌊 Install it first with lib/install.sh.${RESET}"
        exit 1
    fi

    CONFIG_FILE="$CONFIG_DIR/config.json"
    VERSION_FILE="$CONFIG_DIR/VERSION.json"

    if [[ "$CONFIG_DIR" == "$HOME"* ]]; then
        CONFIG_NEED_SUDO=false
    else
        CONFIG_NEED_SUDO=true
    fi
}

resolve_config_dir

echo "🌊 Updating from branch: $BRANCH"
echo ""

# ==========================================
# 读取安装目录
# ==========================================

BASE_DIR=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE'))['base_dir'])")

if [[ -z "$BASE_DIR" || ! -d "$BASE_DIR" ]]; then
    echo -e "${RED_BOLD}🌊 Error: Cannot read base_dir from $CONFIG_FILE.${RESET}"
    exit 1
fi

LIB_DIR="$BASE_DIR/lib"
PKG_DIR="$BASE_DIR/pkg"
SURFBOARD_DIR="$BASE_DIR/surfboard"

# 更新下载是拿 root 跑的（NEED_SUDO=true 时 run_cmd 就是 sudo），新文件会落成 root
# 属主。先把这棵树的属主/属组记下来，收尾时交回去——共享安装树否则会慢慢变成 root 的。
TREE_OWNER="$(stat -c '%U' "$BASE_DIR" 2>/dev/null)"
TREE_GROUP="$(stat -c '%G' "$BASE_DIR" 2>/dev/null)"

# ==========================================
# 判断是否需要 sudo
# ==========================================

CURRENT_USER=$(whoami)

if [[ "$BASE_DIR" == "$HOME"* ]]; then
    NEED_SUDO=false
else
    NEED_SUDO=true
fi

run_cmd() {
    if [[ "$NEED_SUDO" == "true" ]]; then
        sudo "$@"
    else
        "$@"
    fi
}

# 安装目录与配置目录未必同级：用户级安装也可能读系统级配置（系统级优先），
# 所以配置目录单独判断权限。
config_cmd() {
    if [[ "$CONFIG_NEED_SUDO" == "true" ]]; then
        sudo "$@"
    else
        "$@"
    fi
}

# fetch_to_file 的 default runner：原样执行，不碰 sudo。
# 写出来是因为 fetch_to_file 里统一用 "$runner" 前缀，直接写命令名会被当成可执行文件。
direct() {
    "$@"
}

# ==========================================
# 带超时与重试的下载# ==========================================
#
# 一次网络抖动不该让整个自更新前功尽弃：每个请求都有超时，失败按 curl 的退出码
# 判断值不值得重试，并且先写 <目标>.linuxwave-part 再 mv —— 重试期间目标位置
# 不会出现半个文件，全部失败时原地那份好文件也不受影响。
#
# 这解决的是实测过的问题：链路被重置时 `Recv failure: 连接被对方重置` 会让
# 「更新到一半」直接失败，而那时 VERSION.json 还没写，版本号仍是旧的。

FETCH_ATTEMPTS=3
RETRY_DELAY=2

# 单个文件的超时。取值思路：一个几十 KB 的源码在 2 KB/s 的烂链路上也只要十几秒，
# 180 秒足够，又不会让一个真挂住的连接把整轮更新拖死。
FILE_TIMEOUT=180

fetch_to_file() {
    # fetch_to_file <url> <目标文件> <超时秒> [runner] [尝试次数]
    # runner 为 run_cmd 时按安装目录的权限决定要不要 sudo。
    local url="$1"
    local destination="$2"
    local timeout="$3"
    local runner="${4:-direct}"
    local attempts="${5:-$FETCH_ATTEMPTS}"
    local partial="$destination.linuxwave-part"
    local attempt status code

    "$runner" mkdir -p "$(dirname "$destination")"

    for ((attempt = 1; attempt <= attempts; attempt++)); do
        status=0
        # 同时取 HTTP 状态码：curl 的退出码并不总能反映「404」。
        # raw.githubusercontent 在 404 时常常报 (56) 收数据失败而不是 (22)，
        # 只看退出码会把「这个文件不存在」当成网络抖动重试三次。
        code="$("$runner" curl -fsSL --max-time "$timeout" -w '%{http_code}' \
            -o "$partial" "$url" 2>/dev/null)" || status=$?
        if [[ "$status" -eq 0 ]]; then
            "$runner" mv -f "$partial" "$destination"
            return 0
        fi
        "$runner" rm -f "$partial" 2>/dev/null || true

        case "$code" in
            4??)
                # 4xx 是「请求本身不对」，重试不会变好：404 就是没有这个文件。
                return 1
                ;;
        esac

        case "$status" in
            22|23|1|2|3)
                # 22=HTTP 错误、23=写盘失败、1~3=用法错误。同样不值得重试。
                return 1
                ;;
        esac

        if ((attempt < attempts)); then
            echo -e "${YELLOW}🌊 Retrying ($((attempt + 1))/$attempts): $url${RESET}" >&2
            sleep "$RETRY_DELAY"
        fi
    done

    return 1
}

if [[ "$NEED_SUDO" == "true" || "$CONFIG_NEED_SUDO" == "true" ]]; then
    echo -e "${YELLOW}🌊 Requesting temporary administrator access for the update...${RESET}"
    sudo -v
fi

# ==========================================
# 确定目标版本
# ==========================================

VERSION="${LINUXWAVE_UPDATE_VERSION:-}"

if [[ -z "$VERSION" ]]; then
    # 直接调用 selfupdate.sh（不经 wave selfupdate）时才需要自己取版本号。
    # 走同一个带重试的下载：这一步失败会让整轮更新提前结束，值得重试。
    VERSION_DATA_TMP="$(mktemp)"
    if fetch_to_file "$VERSION_DATA_URL" "$VERSION_DATA_TMP" 30 direct; then
        VERSION=$(sed -n 's/^version:[[:space:]]*"\(.*\)"/\1/p' "$VERSION_DATA_TMP" | head -n 1)
    fi
    rm -f "$VERSION_DATA_TMP" "$VERSION_DATA_TMP.linuxwave-part"
fi

if [[ -z "$VERSION" ]]; then
    echo -e "${RED_BOLD}🌊 Error: Cannot determine the target version.${RESET}"
    echo -e "${RED_BOLD}🌊 ${VERSION_DATA_URL}${RESET}"
    echo -e "${RED_BOLD}🌊 Check your network or proxy, then run 'wave selfupdate' again.${RESET}"
    exit 1
fi

echo "🌊 Updating LinuxWave to $VERSION"

# ==========================================
# 大版本守卫（跨大版本不允许 selfupdate）
# ==========================================
#
# 每个大版本的第一个版本、以及任何跨大版本升级，都必须用 install.sh 完整安装：
# 这类升级通常同时改仓库与目录结构，selfupdate 只适合同大版本内的小版本升级。
# selfupdate.sh 是从「目标分支」拉下来执行的，守卫放在这里，以后每个大版本自带的
# selfupdate.sh 都会带上它，规则自动生效，不必逐版本写死在 configdata 里。

CURRENT_VERSION="$(python3 - "$VERSION_FILE" <<'PY'
import json
import sys

try:
    with open(sys.argv[1]) as handle:
        print(json.load(handle).get("version", ""))
except Exception:
    print("")
PY
)"

major_of() {
    # 取版本号里第一段数字当大版本号："2.6.5" -> "2"，"3.0" -> "3"
    python3 -c 'import re, sys
match = re.search(r"[0-9]+", sys.argv[1])
print(match.group(0) if match else "")' "$1"
}

CURRENT_MAJOR="$(major_of "$CURRENT_VERSION")"
TARGET_MAJOR="$(major_of "$VERSION")"

if [[ -n "$CURRENT_MAJOR" && -n "$TARGET_MAJOR" && "$CURRENT_MAJOR" != "$TARGET_MAJOR" ]]; then
    echo -e "${RED_BOLD}🌊 Error: selfupdate cannot cross major versions ($CURRENT_VERSION -> $VERSION).${RESET}" >&2
    echo -e "${RED_BOLD}🌊 A new major version must be installed with install.sh:${RESET}" >&2
    echo -e "${YELLOW}   /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/LinuxWaveOrg/LinuxWave/HEAD/lib/install.sh)\"${RESET}" >&2
    exit 1
fi

# ==========================================
# 版本目录结构变更迁移（configdata/updatedata/{版本号}）
# ==========================================
#
# configdata 仓库的 updatedata/{版本号}/dir_structure_change 只有**一个字符**：
#     Y/y → 该版本改变了目录结构，执行同目录下的 transfer_commands 完成迁移
#     N/n → 没有改变，跳过（文件不存在也按「没有改变」处理）
# 目标版本号用这次要升级到的版本（上面刚确定的 $VERSION）。
# 迁移可能把配置搬到用户级位置，所以执行完要重新解析一次配置目录。

UPDATEDATA_URL="$CONFIGDATA_URL/updatedata/$VERSION"

DIR_STRUCTURE_CHANGE="$(curl -fsSL --max-time 30 "$UPDATEDATA_URL/dir_structure_change" 2>/dev/null | tr -d '[:space:]')" || DIR_STRUCTURE_CHANGE=""

if [[ "$DIR_STRUCTURE_CHANGE" == "Y" || "$DIR_STRUCTURE_CHANGE" == "y" ]]; then
    echo -e "${YELLOW}🌊 Directory structure changed in $VERSION, running migration...${RESET}"

    TRANSFER_COMMANDS="$(curl -fsSL --max-time 60 "$UPDATEDATA_URL/transfer_commands" 2>/dev/null)" || TRANSFER_COMMANDS=""
    if [[ -z "$TRANSFER_COMMANDS" ]]; then
        echo -e "${RED_BOLD}🌊 Error: Cannot fetch the migration script for $VERSION.${RESET}"
        echo -e "${RED_BOLD}🌊 Nothing was updated. Check your network, then try again.${RESET}"
        exit 1
    fi

    # 把当前安装的位置与配置目录告诉迁移脚本，由它自己判断该不该搬
    export LINUXWAVE_INSTALL_DIR="$BASE_DIR"
    export LINUXWAVE_CONFIG_DIR="$CONFIG_DIR"
    export LINUXWAVE_TARGET_VERSION="$VERSION"

    if ! bash -c "$TRANSFER_COMMANDS"; then
        echo -e "${RED_BOLD}🌊 Error: The migration for $VERSION failed.${RESET}"
        echo -e "${RED_BOLD}🌊 Nothing was updated. Fix the issue above, then try again.${RESET}"
        exit 1
    fi

    resolve_config_dir    # 配置可能已经搬到用户级位置
    echo ""
fi

# ==========================================
# 文件清单（configdata/versiondata/files_info）
# ==========================================
#
# 要更新哪些文件不再写死在本脚本里，而是去 configdata 分支读一份清单。
# 清单内容**只表示仓库里的路径**，写法：
#
#     /                      单独一个 / 表示安装根（等价于 BASE_DIR）
#         lib/               以 / 结尾 → 目录，只创建不下载
#             wave.py        其它 → 文件
#         pkg/linker.py      也可以行内直接写完整路径，代替缩进
#             # 以 # 开头的是注释，空行忽略
#
# 缩进每层 4 个空格，Tab 与 4 个空格等价，两种可以混用。
# 每个文件都从 "$BASE_URL/<仓库路径>" 下载，落到 "$BASE_DIR" 下的同名位置。
# 唯一的特例：lib/wave.py 装成可执行的 lib/wave（它是 PATH 里的入口名）。
# 以后新增文件只要改 configdata 的这份清单，不用再动本脚本。

FILES_INFO_URL="$CONFIGDATA_URL/versiondata/files_info"
FILES_INFO_TMP="$(mktemp)"

cleanup_files_info() {
    rm -f "$FILES_INFO_TMP" "$FILES_INFO_TMP.linuxwave-part"
}
trap cleanup_files_info EXIT

echo "🌊 Fetching the file list..."

if ! fetch_to_file "$FILES_INFO_URL" "$FILES_INFO_TMP" 60 direct; then
    echo -e "${RED_BOLD}🌊 Error: Cannot fetch versiondata/files_info from the configdata branch.${RESET}"
    echo -e "${RED_BOLD}🌊 Nothing was updated. Check your network or proxy, then try again.${RESET}"
    exit 1
fi

parse_files_info() {
    # 把缩进树解析成 "<仓库路径>\t<本地相对路径>\t<是否需要 +x>"，一行一个文件
    python3 - "$1" <<'PY'
import sys

stack = []   # [(缩进宽度, 目录名)]：当前所在目录的祖先链
lines = []

for raw in open(sys.argv[1], encoding="utf-8"):
    line = raw.rstrip("\n")
    if not line.strip() or line.lstrip().startswith("#"):
        continue

    # 缩进按 4 个空格算，Tab 等价于 4 个空格（两者可以混用）
    expanded = line.expandtabs(4)
    indent = len(expanded) - len(expanded.lstrip(" "))
    name = line.strip()

    while stack and stack[-1][0] >= indent:   # 缩进回退：弹掉不比当前行浅的祖先
        stack.pop()

    if name == "/":                 # 单独一个 /：安装根，等价于 BASE_DIR
        stack = []
        continue

    if name.endswith("/"):          # 以 / 结尾 → 目录：只记层次，不下载
        stack.append((indent, name.rstrip("/")))
        continue

    if "/" in name:                 # 行内直接写完整路径（可代替缩进）
        repo_path = name.strip("/")
    else:
        repo_path = "/".join([directory for _, directory in stack] + [name])

    if repo_path == "lib/wave.py":
        local_path, executable = "lib/wave", 1
    else:
        local_path, executable = repo_path, int(repo_path.endswith(".sh"))

    lines.append(f"{repo_path}\t{local_path}\t{executable}")

print("\n".join(lines))
PY
}

FILE_ENTRIES="$(parse_files_info "$FILES_INFO_TMP")"

if [[ -z "$FILE_ENTRIES" ]]; then
    echo -e "${RED_BOLD}🌊 Error: The file list is empty, nothing to update.${RESET}"
    exit 1
fi

FILE_COUNT=$(printf '%s\n' "$FILE_ENTRIES" | wc -l | tr -d ' ')
echo "🌊 Updating $FILE_COUNT file(s) from branch: $BRANCH"
echo ""

# ==========================================
# 按清单更新
# ==========================================

while IFS=$'\t' read -r repo_path local_path executable; do
    if [[ -z "$repo_path" ]]; then
        continue
    fi

    echo "🌊 Updating $repo_path..."
    if ! fetch_to_file "$BASE_URL/$repo_path" "$BASE_DIR/$local_path" "$FILE_TIMEOUT" run_cmd; then
        echo -e "${RED_BOLD}🌊 Error: Cannot download $repo_path after $FETCH_ATTEMPTS attempts.${RESET}" >&2
        echo -e "${RED_BOLD}🌊 Nothing was updated past this file; VERSION.json is unchanged.${RESET}" >&2
        echo -e "${RED_BOLD}🌊 Run 'wave selfupdate' again when the network recovers.${RESET}" >&2
        exit 1
    fi

    if [[ "$executable" == "1" ]]; then
        run_cmd chmod +x "$BASE_DIR/$local_path"
    fi
done <<< "$FILE_ENTRIES"

# ==========================================
# 清理旧的字节码缓存
# ==========================================

for cache in "$LIB_DIR/__pycache__" "$PKG_DIR/__pycache__" "$SURFBOARD_DIR/__pycache__"; do
    if [[ -d "$cache" ]]; then
        echo "🌊 Removing stale bytecode cache: ${cache#"$BASE_DIR"/}"
        run_cmd rm -rf "$cache"
    fi
done

# ==========================================
# 写入新的版本号
# ==========================================

config_cmd mkdir -p "$CONFIG_DIR"

config_cmd tee "$VERSION_FILE" > /dev/null << EOF
{
  "version": "$VERSION",
  "components": {
    "installer": "$VERSION",
    "parser": "$VERSION"
  }
}
EOF

if [[ "$CONFIG_NEED_SUDO" == "true" ]]; then
    sudo chown -R "$CURRENT_USER": "$CONFIG_DIR"
fi

config_cmd chmod 755 "$CONFIG_DIR"
config_cmd chmod 644 "$CONFIG_FILE" "$VERSION_FILE"

echo "🌊 Version saved to $VERSION_FILE"

# ==========================================
# 交回属主，并补上共享写（组共享）
# ==========================================
#
# 安装器从 2.6.3 起会给共享安装自动配好组共享写；这里让**已经存在的**安装树
# 在升级时就地补上，不必重装。
#
# 只对「树属于别的账号」的树做：系统级安装（/opt、/usr/local）的树属 root 或调用者
# 自己，既不需要这套权限，也不该劝人去加入 root 组——安装器里是同一个判断。

if [[ "$NEED_SUDO" == "true" && -n "$TREE_OWNER" && -n "$TREE_GROUP" ]]; then
    run_cmd chown -R "$TREE_OWNER:$TREE_GROUP" "$BASE_DIR"
fi

if [[ "$NEED_SUDO" == "true" && -n "$TREE_GROUP" && "$TREE_GROUP" != "root" \
    && -n "$TREE_OWNER" && "$TREE_OWNER" != "$CURRENT_USER" ]]; then

    echo "🌊 Setting up shared write through the '$TREE_GROUP' group..."

    SHARED_GID="$(getent group "$TREE_GROUP" 2>/dev/null | cut -d: -f3)"
    RELOGIN_NEEDED=false

    if [[ -n "$SHARED_GID" ]] \
        && ! id -G "$CURRENT_USER" 2>/dev/null | tr ' ' '\n' | grep -qx "$SHARED_GID"; then
        # 加组失败不该让升级失败：代码已经换好了，用户只是还得按提示用 sudo 装包
        if run_cmd usermod -aG "$TREE_GROUP" "$CURRENT_USER"; then
            RELOGIN_NEEDED=true
        else
            echo -e "${YELLOW}🌊 Could not add '$CURRENT_USER' to '$TREE_GROUP'.${RESET}"
            echo -e "${YELLOW}🌊 Add it by hand: sudo usermod -aG $TREE_GROUP $CURRENT_USER${RESET}"
        fi
    fi

    run_cmd chmod -R g+w "$BASE_DIR"
    # setgid 加在目录上：否则组员新建的文件会落回他自己的主组，下一个组员就写不进去
    run_cmd find "$BASE_DIR" -type d -exec chmod g+s {} +

    # 会话里还没有这个组的身份 -> 也要提示（加过组但一直没重登就是这种）。
    # 用不带参数的 `id -G`：具名那种查的是 /etc 数据库，会把「已写进库、但当前
    # shell 还没这个组」误判成已生效，于是谎报「不用重登」。
    if ! id -G 2>/dev/null | tr ' ' '\n' | grep -qx "$SHARED_GID"; then
        RELOGIN_NEEDED=true
    fi

    if [[ "$RELOGIN_NEEDED" == "true" ]]; then
        echo ""
        echo -e "${YELLOW}🌊 '$CURRENT_USER' is now in the '$TREE_GROUP' group, but this shell${RESET}"
        echo -e "${YELLOW}🌊 does not have it yet: log out and back in (or run 'newgrp $TREE_GROUP')${RESET}"
        echo -e "${YELLOW}🌊 before installing packages. A group only takes effect in a new login${RESET}"
        echo -e "${YELLOW}🌊 session - until then the tree is still unwritable, and 'wave' will say so.${RESET}"
        echo -e "${YELLOW}🌊 If it is still unwritable after a re-login, the user manager started at${RESET}"
        echo -e "${YELLOW}🌊 your first login is holding the old credentials: run${RESET}"
        echo -e "${YELLOW}     systemctl --user exit${RESET}"
        echo -e "${YELLOW}🌊 then log in again (a reboot does the same).${RESET}"
        echo -e "${YELLOW}🌊 The update itself is done; nothing is broken.${RESET}"
    else
        echo "🌊 '$CURRENT_USER' already has the '$TREE_GROUP' group; no re-login needed."
    fi
fi

exit 0
