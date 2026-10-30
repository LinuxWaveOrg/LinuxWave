#!/bin/bash

# LinuxWave 🌊 Self Updater
# Re-downloads every LinuxWave code file and refreshes VERSION.json in the
# active config dir (/etc/linuxwave_config or ~/.config/linuxwave_config).
# Invoked by `wave selfupdate` through the update_command field in
# configdata/versiondata/latest_version, or directly:
#   bash lib/selfupdate.sh [branch]        (defaults to HEAD)

set -e

# ==========================================
# 域名（4.0 起所有对外地址都可由环境变量覆盖）
# ==========================================
#
# 与 lib/domains.py 是同一张表：一份给 Python、一份给 shell。install.sh 是
# `curl | bash` 直接执行的，没有本地文件可以 source，只能在这里重复一遍。
#
# 这一段必须与 lib/selfupdate.sh 逐字一致 —— scripts/domains_test.sh 有断言。

mw_domain() {
    # mw_domain <变量名> <值>：校验协议、去掉末尾斜杠，然后打印规范化后的值。
    # 规则必须与 lib/domains.py 的 _validate 完全一致 —— scripts/domains_test.sh
    # 会拿同一批输入分别喂给两边逐条比对。
    local name="$1"
    local value="$2"
    local scheme rest authority host

    while [[ "$value" == */ ]]; do
        value="${value%/}"
    done

    # 这些字符会被拼进 URL、错误信息，也可能被 shell 当参数用，一律先拒
    case "$value" in
        *' '*|*$'\t'*|*$'\n'*|*'"'*|*"'"*|*'`'*|*'$'*|*'\'*)
            echo -e "${RED_BOLD}🌊 Error: $name contains a forbidden character (space, quote, backtick, \$ or \\\\): $value${RESET}" >&2
            exit 1 ;;
    esac

    scheme="${value%%://*}"
    rest="${value#*://}"
    if [[ "$scheme" == "$value" || -z "$rest" ]]; then
        echo -e "${RED_BOLD}🌊 Error: $name must include a scheme (https:// or file://): $value${RESET}" >&2
        exit 1
    fi

    scheme="$(printf '%s' "$scheme" | tr '[:upper:]' '[:lower:]')"
    case "$scheme" in
        https|file) printf '%s\n' "$value"; return 0 ;;
    esac

    if [[ "$scheme" == "http" ]]; then
        # 明文 http 只给本机镜像（离线测试、本机代理）
        authority="${rest%%/*}"
        authority="${authority##*@}"
        case "$authority" in
            \[*\]*) host="${authority#[}"; host="${host%%]*}" ;;
            *)     host="${authority%%:*}" ;;
        esac
        host="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"
        case "$host" in
            127.0.0.1|localhost|::1) printf '%s\n' "$value"; return 0 ;;
        esac
        echo -e "${RED_BOLD}🌊 Error: $name: plain HTTP is only allowed for loopback mirrors: $value${RESET}" >&2
        exit 1
    fi

    echo -e "${RED_BOLD}🌊 Error: $name has an unsupported scheme '$scheme': $value${RESET}" >&2
    exit 1
}

mw_redact() {
    # mw_redact <url>：把 URL 里的口令换成 ***，日志与报错里不能出现明文。
    # 只在 host 段找 @ —— path 里的 @ 是合法文件名（jq@1.7.1.arm64）。
    local url="$1"
    local scheme rest authority path userinfo host user

    case "$url" in
        *://*) ;;
        *) printf '%s\n' "$url"; return 0 ;;
    esac

    scheme="${url%%://*}"
    rest="${url#*://}"
    authority="${rest%%/*}"
    if [[ "$rest" == */* ]]; then path="/${rest#*/}"; else path=""; fi

    case "$authority" in
        *@*) ;;
        *) printf '%s\n' "$url"; return 0 ;;
    esac

    userinfo="${authority%@*}"
    host="${authority##*@}"
    user="${userinfo%%:*}"
    if [[ "$userinfo" == *:* ]]; then
        printf '%s://%s:***@%s%s\n' "$scheme" "$user" "$host" "$path"
    else
        printf '%s://***@%s%s\n' "$scheme" "$host" "$path"
    fi
}

# ==========================================
# 各地址（默认值必须与 lib/domains.py 的 DEFAULTS 逐字一致）
# ==========================================
#
# scripts/check_domain_defaults.py 会逐条比对 shell 与 Python，改一处就要改另一处。

API_DOMAIN="$(mw_domain LINUXWAVE_API_DOMAIN "${LINUXWAVE_API_DOMAIN:-https://raw.githubusercontent.com/LinuxWaveOrg/infosource/main}")"
CORE_URL="$(mw_domain LINUXWAVE_CORE_DOMAIN "${LINUXWAVE_CORE_DOMAIN:-https://raw.githubusercontent.com/LinuxWaveOrg/LinuxWave}")"
# 内置默认值，只用来判断「用户是不是在用镜像」（install.sh 的欢迎语据此提示一句）。
# 必须与上一行的默认值、以及 lib/domains.py 的 DEFAULTS["core"] 一致 ——
# scripts/check_domain_defaults.py 会比对这三处。
CORE_DEFAULT_URL="https://raw.githubusercontent.com/LinuxWaveOrg/LinuxWave"
SELFUPDATE_URL="$(mw_domain LINUXWAVE_SELFUPDATE_DOMAIN "${LINUXWAVE_SELFUPDATE_DOMAIN:-https://raw.githubusercontent.com/LinuxWaveOrg/configdata/main}")"
PYTHON_DATA_URL="$(mw_domain LINUXWAVE_PYTHON_DOMAIN "${LINUXWAVE_PYTHON_DOMAIN:-https://raw.githubusercontent.com/LinuxWaveOrg/configdata/main}")"
# pip 的索引：只影响「装 requests/packaging/rich」这一次调用，不参与「从哪儿取文件」
PIP_INDEX_URL="$(mw_domain LINUXWAVE_PIP_INDEX "${LINUXWAVE_PIP_INDEX:-https://pypi.org/simple}")"

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

BRANCH="${LINUXWAVE_UPDATE_BRANCH:-${1:-HEAD}}"
BASE_URL="$CORE_URL/$BRANCH"
CONFIGDATA_URL="$SELFUPDATE_URL"   # 版本数据与自更新数据同源，见下方域名块
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
    # 物理路径：与下面比较用的 HOME（configpaths 已 resolve 过）要用同一种形式，
    # 否则符号链接一掺和，前缀判断就会失效。
    SYS_ROOT="$(cd "$_lw_root" && pwd -P)"
    # 幂等：lib/configpaths.py 也会把 HOME 搬进测试根。从 wave.py 一路调用下来时
    # HOME 已经被改过一次，这里再套一层就会变成 "<根><根>/home/<你>"，配置目录于是
    # 永远找不到。两边都取物理路径再比较，才不会被符号链接骗过去。
    _lw_home_real="$(cd "$HOME" 2>/dev/null && pwd -P)" || _lw_home_real="$HOME"
    case "$_lw_home_real" in
        "$SYS_ROOT"|"$SYS_ROOT"/*) ;;
        *) export HOME="$SYS_ROOT${HOME}" ;;
    esac
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

# `--max-time` 由 selfupdate.py 以**秒**传下来（命令行上写 `1min20s` 也在这里变成 80）。
# 给了就统一覆盖：取元数据与下单个文件用同一个上限；没给则保留上面按场景调好的默认。
if [[ -n "${LINUXWAVE_MAX_TIME:-}" ]]; then
    META_TIMEOUT="$LINUXWAVE_MAX_TIME"
    FILE_TIMEOUT="$LINUXWAVE_MAX_TIME"
else
    META_TIMEOUT=30
fi

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
    echo -e "${YELLOW}   /bin/bash -c \"\$(curl -fsSL $CORE_URL/HEAD/lib/install.sh)\"${RESET}" >&2
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

DIR_STRUCTURE_CHANGE="$(curl -fsSL --max-time "$META_TIMEOUT" "$UPDATEDATA_URL/dir_structure_change" 2>/dev/null | tr -d '[:space:]')" || DIR_STRUCTURE_CHANGE=""

if [[ "$DIR_STRUCTURE_CHANGE" == "Y" || "$DIR_STRUCTURE_CHANGE" == "y" ]]; then
    echo -e "${YELLOW}🌊 Directory structure changed in $VERSION, running migration...${RESET}"

    TRANSFER_COMMANDS="$(curl -fsSL --max-time "$META_TIMEOUT" "$UPDATEDATA_URL/transfer_commands" 2>/dev/null)" || TRANSFER_COMMANDS=""
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
# PATH 上的入口 lib/wave 不在这份清单里：它由 write_launcher 生成（内容随解释器位置变）。
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

    # lib/wave.py 按原名落盘；PATH 上的入口 lib/wave 由后面的 write_launcher 生成
    # （它要按私有 venv 与解释器路径决定怎么启动，不能直接复制脚本本体）。
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
# Python 运行环境（自带解释器 + 私有 venv + 启动器）
# ==========================================
#
# 与 install.sh 同一套机制：自更新也要保证「入口不依赖 PATH 上的 python3」，
# 否则从 3.0.x 升上来的用户仍然会卡在「系统 Python 一升级 wave 就全废」。
# 这里只做幂等补齐：解释器与 venv 已经存在就不重复下载 / 重建。

portable_python_arch() {
    case "$(uname -m)" in
        arm64|aarch64) echo "arm64" ;;
        x86_64|amd64)  echo "amd64" ;;
        *)             echo "" ;;
    esac
}

portable_python_binary() {
    local root="$1" candidate
    for candidate in \
        "$root/install/bin/python3" \
        "$root/bin/python3" \
        "$root/python/install/bin/python3" \
        "$root/python/bin/python3"
    do
        if [[ -x "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done
    candidate="$(find "$root" -maxdepth 4 -type f \( -name 'python3' -o -name 'python3.*' \) -perm -u+x 2>/dev/null | head -n 1)"
    if [[ -n "$candidate" ]]; then
        echo "$candidate"
        return 0
    fi
    return 1
}

normalize_portable_python() {
    local target="$1"
    local py="$2"
    local link="$target/bin/python3"
    local relative

    run_cmd mkdir -p "$target/bin" 2>/dev/null || return 0
    if [[ "$py" == "$link" ]]; then
        return 0
    fi
    if [[ "$py" != "$target"/* ]]; then
        return 0
    fi
    relative="../${py#"$target"/}"
    run_cmd ln -sfn "$relative" "$link" 2>/dev/null || true
    return 0
}

ensure_portable_python() {
    # 成功时把解释器路径打到 stdout，失败返回 1（调用方回退系统 python3）。
    local base_dir="$1"
    local arch="$2"
    local data_url="$CONFIGDATA_URL/pythondata/latest_python"
    local data_file version url sha target current archive actual py

    [[ -n "$arch" ]] || return 1

    # 隔离测试根 / 沙箱测试里都不下载 30MB+ 的解释器（离线）；真实产物由 CI 校验。
    if [[ -n "${LINUXWAVE_TEST:-}" || -n "${LINUXWAVE_SKIP_PORTABLE_PYTHON:-}" ]]; then
        return 1
    fi

    # 先看本机是否已经有一份能用的解释器：有就直接用，一个网络请求都不发。
    # 自更新每次都会走到这里，而为了确认一份早就装好的解释器去联网 ——
    # 网络不好时就是「卡在某一行不动」的来源。
    for candidate in "$base_dir/python/current" "$base_dir"/python/*/; do
        [[ -d "$candidate" ]] || continue
        if py="$(portable_python_binary "$candidate" 2>/dev/null)" \
           && "$py" -c 'import sys; sys.exit(0)' >/dev/null 2>&1; then
            echo "$py"
            return 0
        fi
    done

    # 本机没有，才去版本数据里找该下哪个。进度写 stderr：stdout 是返回值通道。
    echo "🌊 Fetching the bundled Python definition..." >&2
    target=""
    data_file="$(mktemp)"
    if ! fetch_to_file "$data_url" "$data_file" 30 run_cmd; then
        run_cmd rm -f "$data_file" 2>/dev/null || true
        return 1
    fi
    version="$(sed -n 's/^version:[[:space:]]*"\(.*\)"/\1/p' "$data_file" | head -n 1)"
    url="$(sed -n "s/^${arch}_url:[[:space:]]*\"\(.*\)\"/\1/p" "$data_file" | head -n 1)"
    sha="$(sed -n "s/^${arch}_sha256:[[:space:]]*\"\(.*\)\"/\1/p" "$data_file" | head -n 1)"
    run_cmd rm -f "$data_file" 2>/dev/null || true

    if [[ -z "$version" || -z "$url" || -z "$sha" ]]; then
        return 1
    fi

    target="$base_dir/python/$version"
    current="$base_dir/python/current"

    if py="$(portable_python_binary "$target" 2>/dev/null)"; then
        :
    else
        echo "🌊 Downloading the bundled Python $version (about 30 MB)..." >&2
        archive="$base_dir/downloads/tmp/portable-python-$version.tar.gz"
        run_cmd mkdir -p "$base_dir/downloads/tmp" 2>/dev/null || true
        # 默认先试我们自己托管的 `pythondata/<版本>/<文件名>`；没有或取不到就回落到上游地址。
        # 路径形状由 lib/domains.py 的 python_archive_url 定义，scripts/python_source_test.sh 会比对。
        if [[ -z "${LINUXWAVE_PYTHON_FROM_SOURCE:-}" ]]; then
            if ! run_cmd curl -fsSL --connect-timeout 20 --max-time 600 -o "$archive" \
                     "$PYTHON_DATA_URL/pythondata/$version/$(basename "$url")" 2>/dev/null; then
                run_cmd rm -f "$archive" 2>/dev/null || true
                echo -e "${YELLOW}🌊 No hosted copy of the bundled Python; using the upstream URL.${RESET}" >&2
            fi
        fi

        if [[ ! -f "$archive" ]]; then
        if ! fetch_to_file "$url" "$archive" 600 run_cmd; then
            run_cmd rm -f "$archive" 2>/dev/null || true
            return 1
        fi
        fi
        actual="$(sha256sum "$archive" 2>/dev/null | awk '{print $1}')"
        if [[ -z "$actual" && -n "$(command -v shasum)" ]]; then
            actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
        fi
        if [[ "$actual" != "$sha" ]]; then
            run_cmd rm -f "$archive" 2>/dev/null || true
            echo -e "${RED_BOLD}🌊 Error: the bundled Python download failed its checksum check.${RESET}" >&2
            return 1
        fi
        run_cmd mkdir -p "$target" 2>/dev/null || true
        if ! run_cmd tar -xzf "$archive" -C "$target" 2>/dev/null; then
            run_cmd rm -f "$archive" 2>/dev/null || true
            return 1
        fi
        run_cmd rm -f "$archive" 2>/dev/null || true
        py="$(portable_python_binary "$target" 2>/dev/null)" || return 1
    fi

    if ! "$py" -c 'import sys; sys.exit(0)' >/dev/null 2>&1; then
        return 1
    fi

    normalize_portable_python "$target" "$py"

    run_cmd mkdir -p "$base_dir/python" 2>/dev/null || true
    run_cmd ln -sfn "$version" "$current" 2>/dev/null || true
    echo "$py"
    return 0
}

write_launcher() {
    # 生成 lib/wave 启动器。每次自更新都会重写：它的内容随解释器位置而变。
    # 注意：调用本函数时**不能**写 run_cmd write_launcher —— sudo 无法执行 shell 函数。
    local base_dir="$1"
    local recorded="$2"
    local target="$base_dir/lib/wave"
    local tmp escaped rendered

    tmp="$(mktemp)"
    cat > "$tmp" <<'LAUNCHER'
#!/bin/sh
# LinuxWave launcher
# 由 install.sh / selfupdate.sh 生成，会被覆盖，请不要手工编辑。
#
# 选择一个**真正能 import 到依赖**的解释器来运行 lib/wave.py：
#   1. 安装根目录下的私有 venv（与系统 Python 升级完全解耦）
#   2. 自带的便携 Python（venv 坏掉时的第一选择）
#   3. 生成这个启动器时的解释器路径
#   4. PATH 上的 python3（最后兜底，wave.py 会明确指出缺哪个依赖）

set -u

# 解析自身真实路径（可能经由 PATH 上的符号链接调用）
self="$0"
while [ -L "$self" ]; do
    link="$(readlink "$self")"
    case "$link" in
        /*) self="$link" ;;
        # 不用 dirname：它是外部命令，PATH 不正常时启动器就起不来了。
        *)  case "$self" in */*) self="${self%/*}/$link" ;; *) self="$link" ;; esac ;;
    esac
done
case "$self" in
    */*) self_dir="${self%/*}" ;;
    *)   self_dir="." ;;
esac
lib_dir="$(cd -- "$self_dir" && pwd)" || exit 1
root_dir="$(cd -- "$lib_dir/.." && pwd)" || exit 1
entry="$lib_dir/wave.py"

#__LINUXWAVE_PYTHON__

deps_ok() {
    [ -x "$1" ] || return 1
    "$1" -c 'import requests, packaging, rich' >/dev/null 2>&1
}

# 1. 私有 venv（正常情况下就是它）
if deps_ok "$root_dir/venv/bin/python3"; then
    exec "$root_dir/venv/bin/python3" "$entry" "$@"
fi
if deps_ok "$root_dir/venv/bin/python"; then
    exec "$root_dir/venv/bin/python" "$entry" "$@"
fi

# 2. 自带的便携 Python（它自带的 site-packages 里没有我们的依赖，
#    但如果 venv 被删了、依赖被装进过它，这里仍然能救场）
if [ -x "$root_dir/python/current/bin/python3" ] && deps_ok "$root_dir/python/current/bin/python3"; then
    exec "$root_dir/python/current/bin/python3" "$entry" "$@"
fi

# 3. 安装时记录的解释器
if [ -n "${LINUXWAVE_PYTHON:-}" ] && deps_ok "$LINUXWAVE_PYTHON"; then
    exec "$LINUXWAVE_PYTHON" "$entry" "$@"
fi

# 4. 最后才用 PATH 上的 python3（wave.py 会明确指出缺哪个依赖）
if command -v python3 >/dev/null 2>&1; then
    exec python3 "$entry" "$@"
fi

echo "🌊 Error: no usable Python 3 interpreter was found." >&2
echo "🌊 Reinstall LinuxWave with lib/install.sh." >&2
exit 1
LAUNCHER

    escaped="$(printf '%s' "$recorded" | sed 's/[\\"`$]/\\&/g')"
    rendered="$(mktemp)"
    sed "s|#__LINUXWAVE_PYTHON__|LINUXWAVE_PYTHON=\"$escaped\"|" "$tmp" > "$rendered"
    rm -f "$tmp"

    run_cmd mkdir -p "$(dirname "$target")"
    run_cmd cp "$rendered" "$target"
    run_cmd chmod 755 "$target"
    rm -f "$rendered"
}

VENV_DIR="$BASE_DIR/venv"
VENV_PY=""
PYTHON_BIN=""
PYTHON_SOURCE=""

echo "🌊 Preparing the Python runtime..."
BUNDLED_PY="$(ensure_portable_python "$BASE_DIR" "$(portable_python_arch)")" || BUNDLED_PY=""

if [[ -n "$BUNDLED_PY" ]]; then
    PYTHON_BIN="$BUNDLED_PY"
    PYTHON_SOURCE="bundled"
    echo "🌊 Using the bundled Python: ${BUNDLED_PY#"$BASE_DIR"/}"
else
    # 已装好的自带解释器优先于 PATH：即使这一轮下载失败，只要 python/current 还在，
    # 就应该继续用它，而不是莫名其妙退回系统解释器。
    if py="$(portable_python_binary "$BASE_DIR/python/current" 2>/dev/null)"; then
        PYTHON_BIN="$py"
        PYTHON_SOURCE="bundled"
        echo "🌊 Using the existing bundled Python: ${py#"$BASE_DIR"/}"
    else
        PYTHON_BIN="$(command -v python3 || true)"
        PYTHON_SOURCE="system"
        if [[ -z "$PYTHON_BIN" ]]; then
            echo -e "${RED_BOLD}🌊 Error: no Python 3 interpreter is available.${RESET}"
            exit 1
        fi
        echo -e "${YELLOW}🌊 Warning: could not prepare the bundled Python; using $PYTHON_BIN instead.${RESET}"
    fi
fi

deps_present() {
    [[ -n "$1" ]] || return 1
    "$1" -c 'import requests, packaging, rich' >/dev/null 2>&1
}

# venv 已存在就复用（自更新不该每次重建 32MB 的环境）；不存在或坏了才重建。
VENV_PY=""
if [[ -x "$VENV_DIR/bin/python3" ]]; then
    VENV_PY="$VENV_DIR/bin/python3"
elif [[ -x "$VENV_DIR/bin/python" ]]; then
    VENV_PY="$VENV_DIR/bin/python"
fi

if ! deps_present "$VENV_PY"; then
    if [[ -n "$VENV_PY" ]]; then
        echo -e "${YELLOW}🌊 The private environment cannot import its dependencies; rebuilding it.${RESET}"
        run_cmd rm -rf "$VENV_DIR" 2>/dev/null || true
    fi
    run_cmd mkdir -p "$VENV_DIR" 2>/dev/null || true
    if run_cmd "$PYTHON_BIN" -m venv "$VENV_DIR" >/dev/null 2>&1; then
        VENV_PY="$VENV_DIR/bin/python3"
        [[ -x "$VENV_PY" ]] || VENV_PY="$VENV_DIR/bin/python"
        echo "🌊 Private Python environment ready: ${VENV_DIR#"$BASE_DIR"/}"
    else
        VENV_PY=""
        echo -e "${YELLOW}🌊 Warning: could not create a private virtualenv; using the ${PYTHON_SOURCE} interpreter directly.${RESET}"
    fi
fi

if [[ -n "$VENV_PY" && -x "$VENV_PY" ]] && ! deps_present "$VENV_PY"; then
    echo "🌊 Installing Python dependencies into the private environment..."
    run_cmd "$VENV_PY" -m pip install --quiet --timeout 10 --retries 1 \
        --upgrade pip >/dev/null 2>&1 || true
    run_cmd "$VENV_PY" -m pip install --quiet --timeout 10 --retries 1 \
        requests packaging rich >/dev/null 2>&1 || true

    if ! deps_present "$VENV_PY"; then
        # 拿不到 PyPI 时退回「继承父解释器 site-packages」的 venv（与 install.sh 一致）
        echo -e "${YELLOW}🌊 Could not install the dependencies into the venv; retrying with the parent's packages.${RESET}"
        run_cmd rm -rf "$VENV_DIR" 2>/dev/null || true
        run_cmd mkdir -p "$VENV_DIR" 2>/dev/null || true
        if run_cmd "$PYTHON_BIN" -m venv --system-site-packages "$VENV_DIR" >/dev/null 2>&1; then
            VENV_PY="$VENV_DIR/bin/python3"
            [[ -x "$VENV_PY" ]] || VENV_PY="$VENV_DIR/bin/python"
        fi
        if ! deps_present "$VENV_PY"; then
            VENV_PY=""
        fi
    fi
fi

if [[ -z "$VENV_PY" ]]; then
    echo -e "${YELLOW}🌊 Warning: no private environment with the dependencies; using $PYTHON_BIN directly.${RESET}"
fi

if ! deps_present "$VENV_PY" && ! deps_present "$PYTHON_BIN"; then
    echo -e "${RED_BOLD}🌊 Error: no Python interpreter with requests/packaging/rich is available.${RESET}"
    echo -e "${RED_BOLD}🌊 The code files are already updated, but 'wave' cannot start until this is fixed.${RESET}"
    echo -e "${RED_BOLD}🌊   python3 -m pip install requests packaging rich${RESET}"
    exit 1
fi

# 共享安装里其他组员要能读/执行新生成的环境（私有安装里这一句也无害）
if [[ -d "$BASE_DIR/python" || -d "$VENV_DIR" ]]; then
    run_cmd chmod -R a+rX "$BASE_DIR/python" "$VENV_DIR" 2>/dev/null || true
fi

write_launcher "$BASE_DIR" "$PYTHON_BIN"

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
