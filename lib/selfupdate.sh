#!/bin/bash

# LinuxWave 🌊 Self Updater
# Fetches linuxwavedata/<版本>/update_commands.sh and runs it, then refreshes
# VERSION.json in the active config dir (/etc/linuxwave_config or
# ~/.config/linuxwave_config).
# Invoked by `wave selfupdate` through the self-update data
# (linuxwavedata/latest.toml), or directly:
#   bash lib/selfupdate.sh [branch]        (defaults to HEAD)

# 与 lib/install.sh / lib/uninstall.sh 同一套严格模式：
#   -e        任一条命令失败就停（自更新失败时**必须**停在原版本，不能半新半旧）
#   -E        ERR 陷阱继承进函数 —— 否则函数中途失败只剩一个光秃秃的退出码
#   -u        读未定义变量即中止（所有可选环境变量都写成 ${VAR:-}）
#   pipefail  管道中任一段失败都算失败
set -eE
set -u
set -o pipefail

# ==========================================
# 输出层：双语与呈现
# ==========================================
# 与 lib/install.sh / lib/uninstall.sh 同一套。脚本被两种方式拉起：
#   · selfupdate.py 通过环境变量传目标（那时没有参数）；
#   · 人直接 `bash lib/selfupdate.sh [branch] [--zh] [--raw] [--dry-run]`。
# 两种都过 lw_say / lw_say_err，于是双语、--raw、--zh 只在这一层做一次。
RED_BOLD='\033[1;31m'
YELLOW='\033[33m'
RESET='\033[0m'

CLI_RAW=false
CLI_DRY_RUN=false
LW_LANG="en"
_PRESENTATION_APPLIED=false

lw_raw() { [[ "${CLI_RAW:-false}" == "true" ]]; }

lw_raw_filter() {
    local line item
    item="$(printf '\xf0\x9f\x8c\x8a')"
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            "$item "*) line="${line#"$item "}" ;;
            "$item"*) line="${line#"$item"}" ;;
        esac
        printf '%s\n' "$line"
    done
}

lw_say() {
    if [[ "$LW_LANG" == "zh" ]]; then
        printf '%b\n' "${2-$1}"
    else
        printf '%b\n' "$1"
    fi
}

lw_say_err() {
    # 必须用 if 而不是 `[[ … ]] && printf`：本脚本是 set -e，条件为假时那条复合
    # 命令返回 1，会被当成一次失败把自更新**静默**终止。
    if [[ "$LW_LANG" == "zh" ]]; then
        printf '%b\n' "${2-$1}" >&2
        if [[ -n "${1:-}" && "${1:-}" != "${2:-}" ]]; then
            printf '%b\n' "$1" >&2
        fi
    else
        printf '%b\n' "$1" >&2
        if [[ -n "${2:-}" && "${2:-}" != "${1:-}" ]]; then
            printf '%b\n' "$2" >&2
        fi
    fi
}

lw_plan() {
    lw_dry_run || return 0
    if [[ "$LW_LANG" == "zh" ]]; then
        printf '%b\n' "${2-$1}"
    else
        printf '%b\n' "$1"
    fi
}

lw_dry_run() { [[ "${CLI_DRY_RUN:-false}" == "true" || "${LINUXWAVE_DRY_RUN:-}" == "1" ]]; }

lw_apply_presentation() {
    [[ "$_PRESENTATION_APPLIED" == "true" ]] && return 0
    if lw_raw; then
        RED_BOLD=""; YELLOW=""; RESET=""
        exec > >(lw_raw_filter) 2>&1
    fi
    _PRESENTATION_APPLIED=true
}

# 参数预扫：下面两道闸门在正式解析之前就要说话，得先认 --zh / --raw。
CLI_ARGV=("$@")
for _lw_arg in ${CLI_ARGV[@]+"${CLI_ARGV[@]}"}; do
    case "$_lw_arg" in
        --raw|--RAW) CLI_RAW=true ;;
        --zh|--ZH) LW_LANG="zh" ;;
        --dry-run|--DRY-RUN) CLI_DRY_RUN=true ;;
    esac
done
lw_apply_presentation

# ==========================================
# 平台闸门：LinuxWave 只装 Linux
# ==========================================
if [[ "$(uname -s 2>/dev/null)" != "Linux" ]]; then
    echo "🌊 Error: this updater is for Linux; this system is $(uname -s 2>/dev/null)." >&2
    echo "🌊 On macOS use MacWave instead: https://macwave.org" >&2
    exit 1
fi

# ==========================================
# 解释器版本闸门
# ==========================================
# 下面用到 bash 4.4 的展开（${var,,} 之类）。3.x 不会报错，只会静默算出错误
# 结果，所以门槛必须立在最前面。
# `-z $BASH_VERSION` 那半句同时挡住 `sh selfupdate.sh` / dash：否则脚本会跑到一半
# 才炸在 [[ 上，报错还看不出真正原因。
if [ -z "${BASH_VERSION:-}" ]; then
    echo "🌊 Error: run this with bash, not sh." >&2
    exit 1
fi
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    echo "🌊 Error: LinuxWave needs bash 4.4 or newer; this is $BASH_VERSION." >&2
    echo "🌊 Debian/Ubuntu: sudo apt install bash   Fedora/RHEL: sudo dnf install bash   macOS: brew install bash" >&2
    exit 1
fi


# ==========================================
# 域名（4.0 起所有对外地址都可由环境变量覆盖）
# ==========================================
#
# 与 net/domains.py 是同一张表：一份给 Python、一份给 shell。install.sh 是
# `curl | bash` 直接执行的，没有本地文件可以 source，只能在这里重复一遍。
#
# 这一段必须与 lib/selfupdate.sh 逐字一致 —— scripts/domains_test.sh 有断言。

lw_domain() {
    # lw_domain <变量名> <值>：校验协议、去掉末尾斜杠，然后打印规范化后的值。
    # 规则必须与 net/domains.py 的 _validate 完全一致 —— scripts/domains_test.sh
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
            echo -e "${RED_BOLD}🌊 错误：$name 含有禁止字符（空格、引号、反引号、\$ 或 \\）：$value${RESET}" >&2
            exit 1 ;;
    esac

    scheme="${value%%://*}"
    rest="${value#*://}"
    if [[ "$scheme" == "$value" || -z "$rest" ]]; then
        echo -e "${RED_BOLD}🌊 Error: $name must include a scheme (https:// or file://): $value${RESET}" >&2
        echo -e "${RED_BOLD}🌊 错误：$name 必须带协议头（https:// 或 file://）：$value${RESET}" >&2
        exit 1
    fi

    scheme="${scheme,,}"
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
        host="${host,,}"
        case "$host" in
            127.0.0.1|localhost|::1) printf '%s\n' "$value"; return 0 ;;
        esac
        echo -e "${RED_BOLD}🌊 Error: $name: plain HTTP is only allowed for loopback mirrors: $value${RESET}" >&2
        echo -e "${RED_BOLD}🌊 错误：${name}：明文 HTTP 只允许本机回环镜像：$value${RESET}" >&2
        exit 1
    fi

    echo -e "${RED_BOLD}🌊 Error: $name has an unsupported scheme '$scheme': $value${RESET}" >&2
    echo -e "${RED_BOLD}🌊 错误：$name 的协议头不受支持（'$scheme'）：$value${RESET}" >&2
    exit 1
}

lw_redact() {
    # lw_redact <url>：把 URL 里的口令换成 ***，日志与报错里不能出现明文。
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

lw_sudo() {
    # sudo 默认 env_reset，会把 HTTPS_PROXY 这类变量清空。于是「配了代理」的机器上
    # 一旦需要提权（/opt、/usr/local 这类系统级安装），下载就绕过代理直连 ——
    # 内网里表现为超时，而不是任何看得懂的报错。
    #
    # 用 `sudo env K=V ...` 显式带过去：不依赖 sudoers 的 setenv 权限（`sudo -E` 会），
    # 也不需要用户去改 /etc/sudoers。没有代理变量时行为与 `sudo` 完全一致。
    local name value
    local -a keep=()
    for name in HTTPS_PROXY HTTP_PROXY ALL_PROXY NO_PROXY \
                https_proxy http_proxy all_proxy no_proxy; do
        value="${!name-}"
        [[ -n "$value" ]] && keep+=("$name=$value")
    done
    if [[ ${#keep[@]} -eq 0 ]]; then
        sudo "$@"
    else
        sudo env "${keep[@]}" "$@"
    fi
}

# ==========================================
# 各地址（默认值必须与 net/domains.py 的 DEFAULTS 逐字一致）
# ==========================================
#
# scripts/check_domain_defaults.py 会逐条比对 shell 与 Python，改一处就要改另一处。

API_DOMAIN="$(lw_domain LINUXWAVE_API_DOMAIN "${LINUXWAVE_API_DOMAIN:-https://raw.githubusercontent.com/LinuxWaveOrg/infosource/main}")"
CORE_URL="$(lw_domain LINUXWAVE_CORE_DOMAIN "${LINUXWAVE_CORE_DOMAIN:-https://raw.githubusercontent.com/LinuxWaveOrg/LinuxWave}")"
# 内置默认值，只用来判断「用户是不是在用镜像」（install.sh 的欢迎语据此提示一句）。
# 必须与上一行的默认值、以及 net/domains.py 的 DEFAULTS["core"] 一致 ——
# scripts/check_domain_defaults.py 会比对这三处。
CORE_DEFAULT_URL="https://raw.githubusercontent.com/LinuxWaveOrg/LinuxWave"
SELFUPDATE_URL="$(lw_domain LINUXWAVE_SELFUPDATE_DOMAIN "${LINUXWAVE_SELFUPDATE_DOMAIN:-https://raw.githubusercontent.com/LinuxWaveOrg/Selfupdate/main}")"
PYTHON_DATA_URL="$(lw_domain LINUXWAVE_PYTHON_DOMAIN "${LINUXWAVE_PYTHON_DOMAIN:-https://raw.githubusercontent.com/LinuxWaveOrg/configdata/main}")"
# pip 的索引：只影响「装 requests/packaging/urllib3/rich」这一次调用，不参与「从哪儿取文件」
PIP_INDEX_URL="$(lw_domain LINUXWAVE_PIP_INDEX "${LINUXWAVE_PIP_INDEX:-https://pypi.org/simple}")"

# ==========================================
# 颜色定义
# ==========================================

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'

# ==========================================
# 实验性签名校验（4.0）
# ==========================================
#
# 与 lib/install.sh 里那一段完全相同（两份脚本都是 curl | bash 执行的，没法
# source，只能各带一份）；改一处就要改另一处。
#
# 4.0 只**警告**：验签能力要客户端版本铺开之后才能真正强制。
#
# 公钥从哪来：lw_trusted_pub() —— 优先 LINUXWAVE_RSA_PUB（PEM 路径），否则用
# 脚本内嵌的那把（scripts/embed_rsa_pub.py 维护，测试会比对是否同步）。

LW_RSA_PUB_TMP=""

lw_sha256() {
    openssl dgst -sha256 -r "$1" 2>/dev/null | awk '{print $1}'
}

lw_signature_note() {
    # lw_signature_note <一行英文> <一行中文>：签名相关的提示一律黄字进 stderr
    echo -e "${YELLOW}$1${RESET}" >&2
    echo -e "${YELLOW}${2-$1}${RESET}" >&2
}

lw_trusted_pub() {
    # 输出一个可读的 PEM 路径，给 openssl 用。两个来源：
    #   1. LINUXWAVE_RSA_PUB（运维/测试自己指定）
    #   2. 脚本内置的那一份
    # 刻意**不读**安装树里的 Keys/*.pem：那份和 latest.toml 走同一条下载通道，
    # 能换数据的人也能换公钥，拿它验等于自证。
    # 两个都没有就输出空串，调用方据此整段跳过。
    if [[ -n "${LINUXWAVE_RSA_PUB:-}" ]]; then
        printf '%s' "${LINUXWAVE_RSA_PUB:-}"
        return 0
    fi
    [[ -n "$LW_RSA_PUB_PEM" ]] || return 0
    if [[ -z "$LW_RSA_PUB_TMP" ]]; then
        LW_RSA_PUB_TMP="$(mktemp -d 2>/dev/null)" || return 0
        printf '%s\n' "$LW_RSA_PUB_PEM" > "$LW_RSA_PUB_TMP/linuxwave-rsa.pub.pem"
        chmod 700 "$LW_RSA_PUB_TMP"
        chmod 600 "$LW_RSA_PUB_TMP/linuxwave-rsa.pub.pem"
    fi
    printf '%s' "$LW_RSA_PUB_TMP/linuxwave-rsa.pub.pem"
}

lw_check_integrity() {
    # lw_check_integrity <说明> <文件> <期望 sha256>
    # 期望值为空 = 这一版没带哈希，直接放行。
    local what="$1" file="$2" expect="$3" got
    [[ -n "$expect" ]] || return 0
    got="$(lw_sha256 "$file")"
    [[ "$got" == "$expect" ]] && return 0
    if [[ "${LINUXWAVE_STRICT_HASHES:-}" == "1" ]]; then
        echo -e "${RED_BOLD}🌊 Error: $what does not match the signed data.${RESET}" >&2
        echo -e "${RED_BOLD}🌊   expected $expect${RESET}" >&2
        echo -e "${RED_BOLD}🌊   got      ${got:-<unreadable>}${RESET}" >&2
        exit 1
    fi
    lw_signature_note "🌊 Warning: $what does not match the signed data (continuing)" \
        "🌊 警告：$what 与已签名数据不符（继续）"
    echo -e "${YELLOW}🌊   expected $expect${RESET}" >&2
    echo -e "${YELLOW}🌊   got      ${got:-<unreadable>}${RESET}" >&2
    return 0
}

lw_verify_latest_signature() {
    # lw_verify_latest_signature <latest.toml 的内容> <它的 URL>
    # 没有公钥就跳过；有公钥但 .sig 404 也算「这一版没签名」（实验期常态）。
    local data="$1" url="$2"
    local pub
    pub="$(lw_trusted_pub)"
    [[ -n "$pub" ]] || return 0

    local tmp sig status=0
    tmp="$(mktemp)"
    sig="$(mktemp)"
    printf '%s\n' "$data" > "$tmp"
    curl -fsSL --max-time 30 ${CURL_LIMITS:-} -o "$sig" "$url.sig" 2>/dev/null || status=$?
    if [[ "$status" -ne 0 ]]; then
        lw_signature_note "🌊 No signature for the self-update data (this release predates signing)." \
            "🌊 这份自更新数据没有签名（早于签名制度，属正常情况）。"
        rm -f "$tmp" "$sig"
        return 0
    fi

    if openssl dgst -sha256 -verify "$pub" -signature "$sig" "$tmp" > /dev/null 2>&1; then
        lw_signature_note "🌊 Self-update data: signature OK." "🌊 自更新数据：签名校验通过。"
    elif [[ "${LINUXWAVE_STRICT_HASHES:-}" == "1" ]]; then
        echo -e "${RED_BOLD}🌊 Error: the self-update data is not signed by the trusted key.${RESET}" >&2
        echo -e "${RED_BOLD}🌊 错误：自更新数据不是由可信密钥签的。${RESET}" >&2
        rm -f "$tmp" "$sig"
        exit 1
    else
        lw_signature_note "🌊 Warning: the self-update data is not signed by the trusted key (continuing)" \
            "🌊 警告：自更新数据的签名不对（继续）"
    fi
    rm -f "$tmp" "$sig"
    return 0
}

# >>> RSA public key (managed by scripts/embed_rsa_pub.py) >>>
LW_RSA_PUB_PEM=''
# <<< RSA public key <<<

# ==========================================
# 目标仓库、分支与版本
# ==========================================

# 正式解析：`--zh / --raw / --dry-run` 之外的位置参数是代码分支。
# selfupdate.py 拉起本脚本时一个参数都不传，目标通过 LINUXWAVE_UPDATE_* 传，
# 所以这里只为人手工调用准备。
BRANCH_ARG=""
for _lw_arg in "$@"; do
    case "$_lw_arg" in
        --zh|--ZH) LW_LANG="zh" ;;
        --raw|--RAW) CLI_RAW=true ;;
        --dry-run|--DRY-RUN) CLI_DRY_RUN=true; export LINUXWAVE_DRY_RUN=1 ;;
        -h|--help)
            lw_say "LinuxWave self-updater — usage: bash lib/selfupdate.sh [branch] [--zh] [--raw] [--dry-run]" \
                   "LinuxWave 自更新脚本 —— 用法：bash lib/selfupdate.sh [分支] [--zh] [--raw] [--dry-run]"
            exit 0
            ;;
        -*)
            lw_say_err "🌊 Error: unknown option '$_lw_arg'." "🌊 错误：未知选项 '$_lw_arg'。"
            exit 1
            ;;
        *)
            if [[ -n "$BRANCH_ARG" ]]; then
                lw_say_err "🌊 Error: more than one branch given ('$BRANCH_ARG', '$_lw_arg')." \
                           "🌊 错误：给了不止一个分支（'$BRANCH_ARG'、'$_lw_arg'）。"
                exit 1
            fi
            BRANCH_ARG="$_lw_arg"
            ;;
    esac
done

BRANCH="${LINUXWAVE_UPDATE_BRANCH:-${BRANCH_ARG:-HEAD}}"
BASE_URL="$CORE_URL/$BRANCH"
# 自更新探针：唯一入口文件。linuxwavedata/latest.toml 说「哪个版本是最新的」，
# linuxwavedata/<版本>/update_commands.sh 说「那一版具体怎么装」。拆开的理由：
# 装了旧版本的人仍在运行，他们那份更新说明不能因为发了新版就变样。
VERSION_DATA_URL="$SELFUPDATE_URL/linuxwavedata/latest.toml"

# -------------------- 测试根（隔离） --------------------
# LINUXWAVE_TEST 指向一个目录时，把它当作 /：HOME 和所有系统路径都挂到它下面，
# 整条链路都落在那个目录里，完全不碰真实系统。
# 没设置时 SYS_ROOT 为空，下面 "$SYS_ROOT/etc/..." 就还是 "/etc/..."，行为不变。
SYS_ROOT=""
if [[ -n "${LINUXWAVE_TEST:-}" ]]; then
    _lw_root="${LINUXWAVE_TEST:-}"
    if [[ "$_lw_root" == "~"* ]]; then
        _lw_root="${HOME}${_lw_root#\~}"
    fi
    mkdir -p "$_lw_root"
    # 物理路径：与下面比较用的 HOME（configpaths 已 resolve 过）要用同一种形式，
    # 否则符号链接一掺和，前缀判断就会失效。
    SYS_ROOT="$(cd "$_lw_root" && pwd -P)"
    # 幂等：config/configpaths.py 也会把 HOME 搬进测试根。从 wave.py 一路调用下来时
    # HOME 已经被改过一次，这里再套一层就会变成 "<根><根>/home/<你>"，配置目录于是
    # 永远找不到。两边都取物理路径再比较，才不会被符号链接骗过去。
    _lw_home_real="$(cd "$HOME" 2>/dev/null && pwd -P)" || _lw_home_real="$HOME"
    case "$_lw_home_real" in
        "$SYS_ROOT"|"$SYS_ROOT"/*) ;;
        *) export HOME="$SYS_ROOT${HOME}" ;;
    esac
    export LINUXWAVE_TEST_ROOT="$SYS_ROOT"
    mkdir -p "$HOME"
    # 不带 🌊：这行在呈现层（--raw 的过滤器）装好之前就打，带了也过滤不掉。
    echo "Test root: $SYS_ROOT"
fi

# 配置目录：系统级优先，其次用户级（与 config/configpaths.py 的规则一致）
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

lw_say "🌊 Updating from branch: $BRANCH" "🌊 从分支更新：$BRANCH"
echo ""

# ==========================================
# 读取安装目录
# ==========================================

BASE_DIR=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE'))['base_dir'])")

if [[ -z "$BASE_DIR" || ! -d "$BASE_DIR" ]]; then
    echo -e "${RED_BOLD}🌊 Error: Cannot read base_dir from $CONFIG_FILE.${RESET}"
    exit 1
fi

# 组件目录：清单在 scripts/components.txt（与 lib/wave.py 的 sys.path、
# 测试沙箱的拷贝、安装清单共用同一份）。这里列出来是为了升级前清掉各目录的
# __pycache__ —— 漏一个就会留着旧字节码，后面排查「改了代码没生效」非常费时间。
LIB_DIR="$BASE_DIR/lib"
NET_DIR="$BASE_DIR/net"
CLI_DIR="$BASE_DIR/cli"
CONFIG_CODE_DIR="$BASE_DIR/config"
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
        lw_sudo "$@"
    else
        "$@"
    fi
}

# 安装目录与配置目录未必同级：用户级安装也可能读系统级配置（系统级优先），
# 所以配置目录单独判断权限。
config_cmd() {
    if [[ "$CONFIG_NEED_SUDO" == "true" ]]; then
        lw_sudo "$@"
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

# 三档超时都由 selfupdate.py 以**原始文本**传下来（`1min20s` 原样，不先算成秒）：
# 换算规则只有 net/timeouts.py 一份，这里只负责把它变成 curl 的旗标。
# 没给的那一档不设，按下面按场景调好的默认值走。
lw_seconds() {
    # 与 net/timeouts.py 的 parse_duration 同一套规则：40 / 40s / 1min /
    # 1min20s / 2h / 250ms 都行，无单位按秒。成功打印整数秒（向上取整，至少 1）。
    awk -v raw="$1" 'BEGIN {
        text = tolower(raw)
        gsub(/[ \t]/, "", text)
        if (text == "") exit 1
        total = 0
        while (length(text) > 0) {
            # 单位必须长优先：`1min` 若先匹配到单字母 `m`，剩下的 `in` 就无解了
            if (!match(text, /^[0-9]+(\.[0-9]+)?/)) exit 1
            number = substr(text, 1, RLENGTH)
            text = substr(text, RLENGTH + 1)
            if (match(text, /^(hrs|hr|h|mins|min|ms|secs|sec|s|m)/)) {
                unit = substr(text, 1, RLENGTH)
                text = substr(text, RLENGTH + 1)
            } else {
                unit = ""
            }
            if (unit == "" || unit == "s" || unit == "sec" || unit == "secs") factor = 1
            else if (unit == "m" || unit == "min" || unit == "mins") factor = 60
            else if (unit == "h" || unit == "hr" || unit == "hrs") factor = 3600
            else if (unit == "ms") factor = 0.001
            else exit 1
            total += number * factor
        }
        if (total <= 0) exit 1
        seconds = int(total)
        if (seconds < total) seconds++
        if (seconds < 1) seconds = 1
        printf "%d\n", seconds
    }'
}

if [[ -n "${LINUXWAVE_MAX_TIME:-}" ]]; then
    if ! _user_timeout="$(lw_seconds "${LINUXWAVE_MAX_TIME:-}")"; then
        echo -e "${RED_BOLD}🌊 Error: cannot parse --max-time value '$LINUXWAVE_MAX_TIME'.${RESET}" >&2
        echo -e "${RED_BOLD}🌊 Use a number of seconds or a suffix like 40s, 1min, 1min20s, 2h.${RESET}" >&2
        exit 1
    fi
    META_TIMEOUT="$_user_timeout"
    FILE_TIMEOUT="$_user_timeout"
else
    META_TIMEOUT=30
fi

CONNECT_TIMEOUT=""
if [[ -n "${LINUXWAVE_CONNECT_TIMEOUT:-}" ]]; then
    if ! CONNECT_TIMEOUT="$(lw_seconds "${LINUXWAVE_CONNECT_TIMEOUT:-}")"; then
        echo -e "${RED_BOLD}🌊 Error: cannot parse --connect-timeout value '$LINUXWAVE_CONNECT_TIMEOUT'.${RESET}" >&2
        echo -e "${RED_BOLD}🌊 Use a number of seconds or a suffix like 40s, 1min, 1min20s, 2h.${RESET}" >&2
        exit 1
    fi
fi

CONTENT_TIME=""
if [[ -n "${LINUXWAVE_CONTENT_TIME:-}" ]]; then
    if ! CONTENT_TIME="$(lw_seconds "${LINUXWAVE_CONTENT_TIME:-}")"; then
        echo -e "${RED_BOLD}🌊 Error: cannot parse --content-time value '$LINUXWAVE_CONTENT_TIME'.${RESET}" >&2
        echo -e "${RED_BOLD}🌊 Use a number of seconds or a suffix like 40s, 1min, 1min20s, 2h.${RESET}" >&2
        exit 1
    fi
fi

# 除 --max-time 之外的限制，拼成一段附加参数给每个 curl 用。
#   --connect-timeout          握手多久算失败
#   --speed-limit 1 --speed-time N   连上之后 N 秒收不到数据算失败
# 只有整数，所以按空格拆开用是安全的。
CURL_LIMITS=""
if [[ -n "$CONNECT_TIMEOUT" ]]; then
    CURL_LIMITS="${CURL_LIMITS:-} --connect-timeout $CONNECT_TIMEOUT"
fi
if [[ -n "$CONTENT_TIME" ]]; then
    CURL_LIMITS="${CURL_LIMITS:-} --speed-limit 1 --speed-time $CONTENT_TIME"
fi

# 额外根证书（LINUXWAVE_CACERT）。单独一个变量、不并进 CURL_LIMITS：
# 那里全是整数与 -k，可以按空格拆开用；路径会有空格，必须整体加引号展开。
# 设了就必须可用 —— 静默忽略会让人以为已经信任了那家 CA。
CURL_CACERT=""
if [[ -n "${LINUXWAVE_CACERT:-}" ]]; then
    _cacert="${LINUXWAVE_CACERT/#\~/$HOME}"
    if [[ ! -f "$_cacert" || ! -r "$_cacert" ]]; then
        echo -e "${RED_BOLD}🌊 Error: LINUXWAVE_CACERT is not a readable file: ${_cacert}${RESET}" >&2
        echo -e "${RED_BOLD}🌊 Next      point it at the CA's root certificate in PEM form, e.g. export LINUXWAVE_CACERT=/etc/ssl/corp-root.pem${RESET}" >&2
        echo -e "${RED_BOLD}🌊           unset it to go back to the system trust store${RESET}" >&2
        exit 1
    fi
    CURL_CACERT="$_cacert"
fi

curl_hint() {
    # curl_hint <退出码> <stderr 文本>：认得出就打印一句下一步，认不出返回 1。
    #
    # 为什么需要它：curl 对这类失败只给一个退出码（60），但「证书过期 / 自签 /
    # 链不完整 / 主机名不匹配」的下一步完全不同 —— 过期只能等对方修，自签要
    # 找网管要根证书，链不完整要找镜像维护者。统一说「SSL error」等于把四种
    # 情况都推给用户自己猜，而这类错在开发机上永远不会出现。
    local status="$1" err="${2:-}" text
    text="$(printf '%s' "$err" | tr '[:upper:]' '[:lower:]')"

    case "$text" in
        *"certificate has expired"*)
            echo -e "${RED_BOLD}🌊 The server's certificate has expired. This is the server's problem: retry later, or contact the mirror maintainer. --skip-ssl does not fix it.${RESET}" >&2
            return 0 ;;
        *"self-signed"*)
            echo -e "${RED_BOLD}🌊 The server uses a self-signed certificate or a private CA (typical inside a corporate network). Ask your network team for the root certificate, then trust it with LINUXWAVE_CACERT=/path/to/root.pem — or switch to an official mirror.${RESET}" >&2
            return 0 ;;
        *"unable to get local issuer"*|*"unable to verify the first certificate"*|*"certificate chain is incomplete"*)
            echo -e "${RED_BOLD}🌊 The server's certificate chain is incomplete (a required intermediate CA is missing). Ask the mirror maintainer to serve the full chain, or trust that root with LINUXWAVE_CACERT=/path/to/root.pem.${RESET}" >&2
            return 0 ;;
        *"hostname mismatch"*|*"doesn't match"*|*"does not match"*|*"not valid for"*)
            echo -e "${RED_BOLD}🌊 The certificate is not valid for this host. Check the domain and the mirror configuration; do not work around this by skipping verification.${RESET}" >&2
            return 0 ;;
    esac

    case "$status" in
        6)
            echo -e "${RED_BOLD}🌊 Cannot resolve the host name. This is a network problem, not a TLS or certificate one.${RESET}" >&2 ;;
        7|28)
            echo -e "${RED_BOLD}🌊 Cannot connect. This is a network problem, not a TLS or certificate one.${RESET}" >&2 ;;
        35|51|58|60|77)
            echo -e "${RED_BOLD}🌊 TLS certificate verification failed. Check the mirror's certificate, or use an official mirror (wave mirror shows the addresses in use).${RESET}" >&2 ;;
        *)
            return 1 ;;
    esac
    return 0
}

fetch_to_file() {
    # fetch_to_file <url> <目标文件> <超时秒> [runner] [尝试次数]
    # runner 为 run_cmd 时按安装目录的权限决定要不要 sudo。
    local url="$1"
    local destination="$2"
    local timeout="$3"
    local runner="${4:-direct}"
    local attempts="${5:-$FETCH_ATTEMPTS}"
    local partial="$destination.linuxwave-part"
    local attempt status code err
    local errfile
    errfile="$(mktemp "${TMPDIR:-/tmp}/linuxwave-curl-err.XXXXXX")"

    "$runner" mkdir -p "$(dirname "$destination")"

    for ((attempt = 1; attempt <= attempts; attempt++)); do
        status=0
        # 同时取 HTTP 状态码：curl 的退出码并不总能反映「404」。
        # raw.githubusercontent 在 404 时常常报 (56) 收数据失败而不是 (22)，
        # 只看退出码会把「这个文件不存在」当成网络抖动重试三次。
        #
        # stderr 单独留一份：证书失败的原因只在那里（curl 只给一个退出码 60），
        # 而「过期 / 自签 / 链不完整 / 主机名不匹配」的下一步完全不同。
        code="$("$runner" curl -fsSL --max-time "$timeout" ${CURL_CACERT:+--cacert "$CURL_CACERT"} ${CURL_LIMITS:-} \
            -w '%{http_code}' -o "$partial" "$url" 2>"$errfile")" || status=$?
        if [[ "$status" -eq 0 ]]; then
            "$runner" mv -f "$partial" "$destination"
            rm -f "$errfile"
            return 0
        fi
        "$runner" rm -f "$partial" 2>/dev/null || true
        err="$(cat "$errfile" 2>/dev/null || true)"

        case "$code" in
            4??)
                # 4xx 是「请求本身不对」，重试不会变好：404 就是没有这个文件。
                rm -f "$errfile"
                return 1
                ;;
        esac

        case "$status" in
            22|23|1|2|3)
                # 22=HTTP 错误、23=写盘失败、1~3=用法错误。同样不值得重试。
                rm -f "$errfile"
                return 1
                ;;
        esac

        if ((attempt < attempts)); then
            echo -e "${YELLOW}🌊 Retrying ($((attempt + 1))/$attempts): $url${RESET}" >&2
            sleep "$RETRY_DELAY"
        fi
    done

    # 全部尝试都失败：把最后一次的原因翻译成一句能照做的下一步。
    # 认不出时什么都不加，让调用方原来那句「取不到」继续负责。
    curl_hint "$status" "$err" || true
    rm -f "$errfile"
    return 1
}

if [[ "$NEED_SUDO" == "true" || "$CONFIG_NEED_SUDO" == "true" ]]; then
    echo -e "${YELLOW}🌊 Requesting temporary administrator access for the update...${RESET}"
    sudo -v
fi

# ==========================================
# 确定目标版本
# ==========================================

read_toml_string() {
    # read_toml_string <文本> <键>：只认 `key = "value"`，`#` 开头是注释。
    # 不引 TOML 解析器：latest.toml 的字段全是字符串，为此加一个依赖不值得。
    # 值不带引号就当不存在 —— 半行残缺不该被当成版本号。
    printf '%s\n' "$1" | sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1
}

VERSION="${LINUXWAVE_UPDATE_VERSION:-}"

# 探针**总是**要取一次：即使调用方已经给了版本号，验签与「update_commands 的哈希」
# 都对着这份数据。只在没给版本号时才取，等于让 Python 那条路从来没校验过
# update_commands_sha256 —— 实验期只是警告，但那是另一回事。
VERSION_DATA_TMP="$(mktemp)"
VERSION_DATA=""
if fetch_to_file "$VERSION_DATA_URL" "$VERSION_DATA_TMP" "$META_TIMEOUT" direct; then
    VERSION_DATA="$(cat "$VERSION_DATA_TMP")"
fi
rm -f "$VERSION_DATA_TMP" "$VERSION_DATA_TMP.linuxwave-part"

if [[ -z "$VERSION" ]]; then
    VERSION="$(read_toml_string "$VERSION_DATA" version)"
fi
PROBE_BRANCH="$(read_toml_string "$VERSION_DATA" branch)"

# 实验性签名：钉住即将被 bash 执行的那个脚本（空 = 这一版没带哈希）
EXPECTED_UPDATE_COMMANDS_SHA256="$(read_toml_string "$VERSION_DATA" update_commands_sha256)"
lw_verify_latest_signature "$VERSION_DATA" "$VERSION_DATA_URL"

if [[ -z "$VERSION" ]]; then
    lw_say_err "${RED_BOLD}🌊 Error: Cannot determine the target version.${RESET}" \
               "${RED_BOLD}🌊 错误：拿不到目标版本号。${RESET}"
    lw_say_err "${RED_BOLD}🌊 ${VERSION_DATA_URL}${RESET}" ""
    lw_say_err "${RED_BOLD}🌊 Check your network or proxy, then run 'wave selfupdate' again.${RESET}" \
               "${RED_BOLD}🌊 检查网络或代理，然后重跑 'wave selfupdate'。${RESET}"
    exit 1
fi

# --dry-run：只报告将要做什么，不下载、不落盘。`wave selfupdate --dry-run`
# 自己就把计划打完了（它不会执行本脚本）；这一段是给「直接 bash lib/selfupdate.sh」
# 准备的，两边都停在下载之前。
if [[ "${LINUXWAVE_DRY_RUN:-}" == "1" ]]; then
    lw_say "🌊 Dry run: nothing will be downloaded or written." \
           "🌊 试运行：不下载、不写盘。"
    lw_say "🌊 Target version : $VERSION" "🌊 目标版本：$VERSION"
    lw_say "🌊 Branch         : $BRANCH" "🌊 分支　　：$BRANCH"
    lw_say "🌊 Install dir    : $BASE_DIR" "🌊 安装目录：$BASE_DIR"
    lw_say "🌊 Config dir     : $CONFIG_DIR" "🌊 配置目录：$CONFIG_DIR"
    lw_say "🌊 Would fetch linuxwavedata/$VERSION/update_commands.sh and run it," \
           "🌊 将下载并执行 linuxwavedata/$VERSION/update_commands.sh，"
    lw_say "🌊 regenerate lib/wave, install the Python dependencies, and rewrite" \
           "🌊 重建 lib/wave、安装 Python 依赖，并重写"
    lw_say "🌊 $VERSION_FILE." "🌊 $VERSION_FILE。"
    exit 0
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
# 更新脚本（linuxwavedata/<版本>/update_commands.sh）
# ==========================================
#
# 要下载哪些文件、放到哪里，以前是客户端读一份 files_info 自己解析。现在改成
# 由自更新数据提供一个脚本，客户端只负责取回来执行：
#
#   - 脚本知道这一版该下哪些文件，所以能只列变动的那些；
#   - 目录结构变更的迁移也写在同一个脚本里，不必再维护第二套机制；
#   - 客户端不再需要「缩进树」这种自定义格式的解析器。
#
# LINUXWAVE_CURRENT_VERSION 传的是本机已经装着的版本，脚本据此决定走增量还是全量。

UPDATE_COMMANDS_URL="$SELFUPDATE_URL/linuxwavedata/$VERSION/update_commands.sh"
UPDATE_COMMANDS_TMP="$(mktemp)"

cleanup_update_commands() {
    rm -f "$UPDATE_COMMANDS_TMP" "$UPDATE_COMMANDS_TMP.linuxwave-part"
}
trap cleanup_update_commands EXIT

echo "🌊 Fetching the update commands..."

if ! fetch_to_file "$UPDATE_COMMANDS_URL" "$UPDATE_COMMANDS_TMP" "$FILE_TIMEOUT" direct; then
    echo -e "${RED_BOLD}🌊 Error: Cannot fetch the update commands ($(lw_redact "$UPDATE_COMMANDS_URL")).${RESET}"
    echo -e "${RED_BOLD}🌊 Nothing was updated. Check your network or proxy, then try again.${RESET}"
    exit 1
fi

# 哈希对不上说明「即将被 bash 执行的东西」不是发布时那一份。
lw_check_integrity "update_commands.sh" "$UPDATE_COMMANDS_TMP" "$EXPECTED_UPDATE_COMMANDS_SHA256"

if ! bash -n "$UPDATE_COMMANDS_TMP" 2>/dev/null; then
    echo -e "${RED_BOLD}🌊 Error: the update commands for $VERSION are not valid shell.${RESET}"
    echo -e "${RED_BOLD}🌊 Nothing was updated. Please report this to the administrator.${RESET}"
    exit 1
fi

# ==========================================
# 执行更新脚本
# ==========================================

export LINUXWAVE_INSTALL_DIR="$BASE_DIR"
export LINUXWAVE_CORE_URL="$CORE_URL"
export LINUXWAVE_BRANCH="$BRANCH"
export LINUXWAVE_CURRENT_VERSION="$CURRENT_VERSION"
export LINUXWAVE_FILE_TIMEOUT="$FILE_TIMEOUT"
LINUXWAVE_NEED_SUDO="$([ "$NEED_SUDO" = "true" ] && echo 1 || echo "")"
export LINUXWAVE_NEED_SUDO
# 这一版带了逐文件哈希才开校验；没带就不开，让更新脚本保持旧行为。
if [[ -n "$EXPECTED_UPDATE_COMMANDS_SHA256" ]]; then
    export LINUXWAVE_WANT_HASHES=1
fi

echo "🌊 Running the update commands for $VERSION..."

if ! bash "$UPDATE_COMMANDS_TMP"; then
    echo -e "${RED_BOLD}🌊 Error: the update commands for $VERSION failed.${RESET}" >&2
    # VERSION.json 只在全部文件到位后才写，所以版本号还是旧的：
    # 网络恢复后再跑一次 wave selfupdate 就会从这里继续。
    echo -e "${RED_BOLD}🌊 Nothing was recorded as updated. Fix the cause above, then run wave selfupdate again.${RESET}" >&2
    exit 1
fi

# ==========================================
# 清理旧的字节码缓存
# ==========================================

for cache in "$LIB_DIR/__pycache__" "$NET_DIR/__pycache__" \
             "$PKG_DIR/__pycache__" "$SURFBOARD_DIR/__pycache__" \
             "$CLI_DIR/__pycache__" "$CONFIG_CODE_DIR/__pycache__"; do
    if [[ -d "$cache" ]]; then
        echo "🌊 Removing stale bytecode cache: ${cache#"$BASE_DIR"/}"
        run_cmd rm -rf "$cache"
    fi
done

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
    local data_url="$PYTHON_DATA_URL/pythondata/latest_python"
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
        # 路径形状由 net/domains.py 的 python_archive_url 定义，scripts/python_source_test.sh 会比对。
        if [[ -z "${LINUXWAVE_PYTHON_FROM_SOURCE:-}" ]]; then
            if ! run_cmd curl -fsSL --connect-timeout 20 --max-time 600 ${CURL_LIMITS:-} -o "$archive" \
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
    "$1" -c 'import requests, packaging, urllib3, rich' >/dev/null 2>&1
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
if [ -n "${LINUXWAVE_PYTHON:-}" ] && deps_ok "${LINUXWAVE_PYTHON:-}"; then
    exec "$LINUXWAVE_PYTHON" "$entry" "$@"
fi

# 4. 最后才用 PATH 上的 python3（wave.py 会明确指出缺哪个依赖）
if command -v python3 >/dev/null 2>&1; then
    exec python3 "$entry" "$@"
fi

lw_say_err "🌊 Error: no usable Python 3 interpreter was found." \
           "🌊 错误：找不到可用的 Python 3 解释器。"
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
    "$1" -c 'import requests, packaging, urllib3, rich' >/dev/null 2>&1
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
        requests packaging urllib3 rich >/dev/null 2>&1 || true

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
    echo -e "${RED_BOLD}🌊   python3 -m pip install requests packaging urllib3 rich${RESET}"
    exit 1
fi

# 共享安装里其他组员要能读/执行新生成的环境（私有安装里这一句也无害）
if [[ -d "$BASE_DIR/python" || -d "$VENV_DIR" ]]; then
    run_cmd chmod -R a+rX "$BASE_DIR/python" "$VENV_DIR" 2>/dev/null || true
fi

write_launcher "$BASE_DIR" "$PYTHON_BIN"

# ==========================================
# 写入新的版本号
# ==========================================

config_cmd mkdir -p "$CONFIG_DIR"

config_cmd tee "$VERSION_FILE" > /dev/null << EOF
{
  "version": "$VERSION",
$( [[ -n "${LINUXWAVE_UPDATE_BUILD:-}" ]] && printf '  "build_number": "%s",\n' "${LINUXWAVE_UPDATE_BUILD:-}" )
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
