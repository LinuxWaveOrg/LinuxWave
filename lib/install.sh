#!/bin/bash

# LinuxWave 🌊 Official Installer
# This script downloads wave.py, installs dependencies, and configures PATH.
# Usage: /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/LinuxWaveOrg/LinuxWave/HEAD/lib/install.sh)"

# 退出码要有语义
# 0 = 成功
# 1 = 用法错误
# 2 = 环境不满足（如 bash 太旧）
# 3 = 网络/下载失败

set -eE
set -u
set -o pipefail

# 旗标默认值必须在这里先定下来：`set -u` 之下，未定义的变量一读就中止，而
# 写盘预检（CLI_DRY_RUN / CLI_SKIP_PROBE）与自更新探针都在参数解析之前就要读它们。
# 真正的解析在「命令行参数（批量 / 脚本化安装）」一节。
CLI_CI=false
CLI_DRY_RUN=false
CLI_PRINT_USAGE=false
# --help：打用法后**停**；--print-usage：打用法后继续。两者分工见解析之后那段。
CLI_HELP=false
CLI_SKIP_PROBE=false
CLI_SKIP_PLATFORM_CHECK=false
CLI_DIR_OPTION=""
CLI_CUSTOM_DIR=""
# ==========================================
# 颜色定义
# ==========================================

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
YELLOW='\033[33m'
SKY_BLUE='\033[38;5;74m'
RESET='\033[0m'

# ==========================================
# 输出层：双语与呈现
# ==========================================
# 所有面向用户的话都过 lw_say / lw_say_err，于是三件事只在这两个函数里做一次：
#   1. 双语：lw_say "<English>" "<中文>"；只给一句时两种语言共用。
#   2. --raw：去掉颜色与行首的 🌊，给日志与 grep 用（逐行过滤，见 lw_raw_filter）。
#   3. --zh：说中文。默认英文 —— 终端不一定有中文 locale，反过来会让英文用户
#      看到乱码。
CLI_RAW=false
LW_LANG="en"
_PRESENTATION_APPLIED=false

lw_raw() { [[ "${CLI_RAW:-false}" == "true" ]]; }

# 逐行读 stdin，去掉行首的 🌊 与紧跟的一个空格。
# 🌊 用 printf 的字节写：$'\U0001F30A' 这种写法要 bash 4.2+，这里不赌。
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
    # 只给一句时两种语言都用它（`${2-$1}`）—— 空行、纯符号行、中英同文的命令行
    # 都属于这种。注意是 `-` 不是 `:-`：显式传了空串（英文有下半句、中文已经说完）
    # 必须打空行，不能回退到英文。
    if [[ "$LW_LANG" == "zh" ]]; then
        printf '%b\n' "${2-$1}"
    else
        printf '%b\n' "$1"
    fi
}

lw_say_err() {
    # 错误信息两边都打：英文给日志与工单，中文给用户。语言只决定先后。
    if [[ "$LW_LANG" == "zh" ]]; then
        printf '%b\n' "${2-$1}" >&2
        [[ -n "${1:-}" && "${1:-}" != "${2:-}" ]] && printf '%b\n' "$1" >&2
    else
        printf '%b\n' "$1" >&2
        [[ -n "${2:-}" && "${2:-}" != "${1:-}" ]] && printf '%b\n' "$2" >&2
    fi
}

# --raw 要关颜色、改输出管道，而参数是在后面才解析的。所以解析完之后再调一次，
# 把「还没开始说话之前」就已经定了的事补上。
#
# 也正因为如此，这里从**原始参数**里再认一次呈现类旗标：解析可能停在第一个未知
# 选项上（那时 --raw 还没轮到），只靠解析结果的话，`--raw --bogus` 报出来的错
# 仍然是带颜色和 🌊 的。从 CLI_ARGV 认一遍，才不会漏。
lw_apply_presentation() {
    [[ "$_PRESENTATION_APPLIED" == "true" ]] && return 0
    local arg
    for arg in ${CLI_ARGV[@]+"${CLI_ARGV[@]}"}; do
        case "$arg" in
            --raw|--RAW) CLI_RAW=true ;;
            --zh|--ZH) LW_LANG="zh" ;;
        esac
    done
    if lw_raw; then
        RED_BOLD=""; GREEN=""; YELLOW=""; SKY_BLUE=""; RESET=""
        exec > >(lw_raw_filter) 2>&1
    fi
    _PRESENTATION_APPLIED=true
}


# ==========================================
# 最早的参数预扫（闸门专用）
# ==========================================
#
# 下面两道闸门（平台、解释器）在参数解析之前就要说话，而它们该按 --zh / --raw 的
# 样子说话。所以这里先从原始参数里认出呈现类旗标与 --skip-platform-check；正式解析
# 仍在「命令行参数」一节 —— 两处认的是同一批旗标，重复这一次只是为了闸门不说错话。
CLI_ARGV=("$@")
for _lw_arg in ${CLI_ARGV[@]+"${CLI_ARGV[@]}"}; do
    case "$_lw_arg" in
        --raw|--RAW) CLI_RAW=true ;;
        --zh|--ZH) LW_LANG="zh" ;;
        --skip-platform-check|--SKIP-PLATFORM-CHECK) CLI_SKIP_PLATFORM_CHECK=true ;;
    esac
done
unset _lw_arg
lw_apply_presentation

# ==========================================
# 平台闸门：LinuxWave 只装 Linux
# ==========================================
# 先判平台再判 bash 版本：macOS 自带 bash 3.2，若先报「请升级 bash」，用户会去
# 装个新 bash，然后发现这个安装器根本不是给他用的。macOS 上该用的是 MacWave。
#
# --skip-platform-check 跳过这道闸门：拿它调试、或者在手上没有那台机器的时候
# 演练一遍（通常配 --dry-run）。跳过时必须说一声 —— 后面的下载地址是按 Linux
# 挑的，装出来能不能跑没人保证。
if [[ "$CLI_SKIP_PLATFORM_CHECK" != "true" && "$(uname -s 2>/dev/null)" != "Linux" ]]; then
    lw_say "🌊 Error: this installer is for Linux; this system is $(uname -s 2>/dev/null)." \
        "🌊 错误：本安装器只用于 Linux；当前系统是 $(uname -s 2>/dev/null)。" >&2
    lw_say "🌊 On macOS use MacWave instead: https://macwave.org" \
        "🌊 macOS 上请改用 MacWave：https://macwave.org" >&2
    exit 1
fi
if [[ "$CLI_SKIP_PLATFORM_CHECK" == "true" ]]; then
    lw_say_err "${YELLOW}🌊 Warning: --skip-platform-check — the platform check is skipped." \
        "${YELLOW}🌊 警告：--skip-platform-check —— 已跳过平台检查。${RESET}"
    lw_say_err "${YELLOW}🌊   This system is $(uname -s 2>/dev/null) $(uname -m 2>/dev/null);" \
        "${YELLOW}🌊   当前系统是 $(uname -s 2>/dev/null) $(uname -m 2>/dev/null)；${RESET}"
    lw_say_err "${YELLOW}🌊   what gets installed is untested here. Use it with --dry-run." \
        "${YELLOW}🌊   装出来的东西在本机没有验证过，请配合 --dry-run 使用。${RESET}"
fi

# ==========================================
# 解释器版本闸门
# ==========================================
# 下面用到 bash 4.4 的展开（${var,,} 之类）。3.x 不会报错，只会静默算出错误
# 结果，所以门槛必须立在最前面。
# `-z $BASH_VERSION` 那半句同时挡住 `sh install.sh` / dash：否则脚本会跑到一半
# 才炸在 [[ 上，报错还看不出真正原因。
if [ -z "${BASH_VERSION:-}" ]; then
    lw_say "🌊 Error: run the installer with bash, not sh." \
        "🌊 错误：请用 bash 运行安装器，而不是 sh。" >&2
    exit 1
fi
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    lw_say "🌊 Error: LinuxWave needs bash 4.4 or newer; this is $BASH_VERSION." \
        "🌊 错误：LinuxWave 需要 bash 4.4 或更高版本；当前是 $BASH_VERSION。" >&2
    lw_say "🌊 Debian/Ubuntu: sudo apt install bash   Fedora/RHEL: sudo dnf install bash" \
        "🌊 Debian/Ubuntu：sudo apt install bash   Fedora/RHEL：sudo dnf install bash" >&2
    lw_say "🌊 Install it with the command above. macOS does not need this — use MacWave there." \
        "🌊 请按上一行安装新版本 bash。macOS 上不需要——那个平台用 MacWave。" >&2
    exit 1
fi

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
    # 不带 🌊：这行在呈现层（--raw 的过滤器）装好之前就打，带了也过滤不掉。
    echo "Test root: $SYS_ROOT"
fi

# -E（errtrace）让下面那个 ERR 陷阱能看见 run_cmd 等**函数内部**的失败：
# 默认情况下陷阱不继承进函数，中途失败就只剩一个光秃秃的 curl 退出码。
# 显式 `return 1`、调用方用 `||` 容忍的失败、`if` 条件里的失败都不会误触发。
set -eE

# ==========================================
# 函数命名：一律带前缀，且不叫 say
# ==========================================
#
# macOS 自带 /usr/bin/say，它把参数朗读出来。所以 MacWave 的安装器开场要先确认
# 自己的输出函数没被同名命令顶掉，否则一行 `say "…"` 被误粘进终端，整个房间都会
# 听见命令内容。Linux 没有 /usr/bin/say（要朗读得另装 espeak / spd-say 之类，
# 名字都不叫 say），那套检查在这里没有必要，因此不做。
#
# 命名规则照旧：输出函数叫 lw_say。误粘贴只会得到 command not found。

# ==========================================
# 完整性校验与签名
# ==========================================
# 这一层守的是「拿到的字节是不是发布时那一份」。HTTPS 只保护传输，保护不了
# 数据源被换掉。
#
#   latest.toml        探针：定版本与分支，所以它附带一份 RSA 签名（latest.toml.sig）
#   update_commands.sh 按探针里 update_commands_sha256 校验（SHA-256 装进已签名的探针里）
#
# 实验期策略与 MacWave 4.4 一致：**验不过只警告**。要让它变成硬失败，设
# LINUXWAVE_STRICT_HASHES=1。

LW_RSA_PUB_TMP=""

read_toml_string() {
    # read_toml_string <文本> <键> —— 取平铺的字符串值，去掉引号与行尾注释
    printf '%s\n' "$1" \
        | sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
        | head -n 1
}

LW_WRITE_ERROR=""
LW_WRITE_ERROR_PATH=""

lw_can_write() {
    # 能往这个路径里写吗？返回 0 可写 / 1 需要提权 / 2 写不进去但不是权限问题。
    #
    # 两步，先「猜」再「问」：
    #   1. `test -w` —— 权限位与 ACL 的静态判断，够快，能挡住「/opt 属于 root」这类；
    #   2. 真写一个空文件再删掉 —— 只读挂载、磁盘满、目录带 immutable 标志时
    #      `test -w` 会说能写而实际写不进去。既然安装第一件事就是往里写，那就先写一次。
    #
    # 探针失败分两类，不能一律当成「需要提权」：
    #   Permission denied → 提权能解决，返回 1；
    #   其它（只读文件系统、磁盘满…）→ 提权也没用，返回 2 并留下原因，由调用方当场报。
    #
    # 不存在的路径沿祖先往上找第一个存在的目录 —— 直接对不存在的路径 test -w 恒为假，
    # 会让每一次新装都被判定成需要提权。
    local path="$1" probe errfile reason
    LW_WRITE_ERROR=""
    LW_WRITE_ERROR_PATH=""
    [[ -n "$path" ]] || return 1
    while [[ ! -e "$path" && "$path" != "/" ]]; do
        path="$(dirname "$path")"
    done
    [[ -d "$path" ]] || return 1
    [[ -w "$path" ]] || return 1

    # --dry-run 承诺「不写文件」，所以试运行只用上面那步静态判断；
    # --skip-probe 是用户显式要求跳过这次写探针。
    if [[ "$CLI_DRY_RUN" == "true" || "$CLI_SKIP_PROBE" == "true" ]]; then
        return 0
    fi

    errfile="$(mktemp)"
    if probe="$(mktemp "$path/.linuxwave-write-probe.XXXXXX" 2>"$errfile")"; then
        rm -f "$probe" "$errfile"
        return 0
    fi
    reason="$(cat "$errfile" 2>/dev/null)"
    rm -f "$errfile"
    case "$reason" in
        *"Permission denied"*) return 1 ;;
    esac
    LW_WRITE_ERROR="$reason"
    LW_WRITE_ERROR_PATH="$path"
    return 2
}

lw_write_state() {
    # 写一处状态文件之前的统一检查：两个目标都要能写。
    # 返回 2 直接报错退出（提权解决不了）。
    local status=0
    lw_can_write "$1" || status=$?
    if [[ "$status" -eq 2 ]]; then
        lw_say_err "${RED_BOLD}🌊 Error: cannot create files in '$LW_WRITE_ERROR_PATH'.${RESET}" \
            "${RED_BOLD}🌊 错误：无法在 '$LW_WRITE_ERROR_PATH' 里创建文件。${RESET}"
        lw_say_err "🌊 ${LW_WRITE_ERROR}" "🌊 ${LW_WRITE_ERROR}"
        lw_say_err "🌊 This is not a privilege problem: sudo would fail the same way." \
            "🌊 这不是权限问题：提权也会一样失败。"
        lw_say_err "🌊 Fix the filesystem (read-only mount, full disk, …) or choose another directory." \
            "🌊 请处理文件系统本身（只读挂载、磁盘已满等），或者换一个目录。"
        exit 1
    fi
    return "$status"
}

lw_sha256() {
    # 用 openssl：Linux 上不需要额外的 shasum/perl 依赖
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
    # 能换数据的人也能换公钥，拿它验等于自证。脚本内置的这份是「上一次可信
    # 安装」留下的锚点。
    # 两个都没有就输出空串，调用方据此整段跳过。
    if [[ -n "${LINUXWAVE_RSA_PUB:-}" ]]; then
        printf '%s' "$LINUXWAVE_RSA_PUB"
        return 0
    fi
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
        lw_say_err "${RED_BOLD}🌊 Error: $what does not match the signed data.${RESET}" \
            "${RED_BOLD}🌊 错误：$what 与已签名数据不符。${RESET}"
        lw_say_err "🌊   expected $expect" "🌊   期望 $expect"
        lw_say_err "🌊   got      ${got:-<unreadable>}" "🌊   实际 ${got:-<读不出>}"
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
    #
    # 没有公钥就整段跳过；有公钥但下载不到 .sig（404）也算「这一版没签名」——
    # 实验期这是常态，不能当错误。
    local data="$1" url="$2"
    local pub
    pub="$(lw_trusted_pub)"
    [[ -n "$pub" ]] || return 0

    local tmp sig status=0
    tmp="$(mktemp)"
    sig="$(mktemp)"
    printf '%s\n' "$data" > "$tmp"
    curl -fsSL --max-time 30 -o "$sig" "$url.sig" 2>/dev/null || status=$?
    if [[ "$status" -ne 0 ]]; then
        lw_signature_note "🌊 No signature for the self-update data (this release predates signing)." \
            "🌊 这份自更新数据没有签名（早于签名制度，属正常情况）。"
        rm -f "$tmp" "$sig"
        return 0
    fi

    if openssl dgst -sha256 -verify "$pub" -signature "$sig" "$tmp" > /dev/null 2>&1; then
        lw_signature_note "🌊 Self-update data: signature OK." "🌊 自更新数据：签名校验通过。"
    elif [[ "${LINUXWAVE_STRICT_HASHES:-}" == "1" ]]; then
        lw_say_err "${RED_BOLD}🌊 Error: the self-update data is not signed by the trusted key.${RESET}" \
            "${RED_BOLD}🌊 错误：自更新数据不是由可信密钥签的。${RESET}"
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
# 域名（4.0 起所有对外地址都可由环境变量覆盖）
# ==========================================
#
# 与 lib/domains.py 是同一张表：一份给 Python、一份给 shell。install.sh 是
# `curl | bash` 直接执行的，没有本地文件可以 source，只能在这里重复一遍。
#
# 这一段必须与 lib/selfupdate.sh 逐字一致 —— scripts/domains_test.sh 有断言。

lw_domain() {
    # lw_domain <变量名> <值>：校验协议、去掉末尾斜杠，然后打印规范化后的值。
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
        echo -e "${RED_BOLD}🌊 错误：$name：明文 HTTP 只允许本机回环镜像：$value${RESET}" >&2
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
# 各地址（默认值必须与 lib/domains.py 的 DEFAULTS 逐字一致）
# ==========================================
#
# scripts/check_domain_defaults.py 会逐条比对 shell 与 Python，改一处就要改另一处。

API_DOMAIN="$(lw_domain LINUXWAVE_API_DOMAIN "${LINUXWAVE_API_DOMAIN:-https://raw.githubusercontent.com/LinuxWaveOrg/infosource/main}")"
CORE_URL="$(lw_domain LINUXWAVE_CORE_DOMAIN "${LINUXWAVE_CORE_DOMAIN:-https://raw.githubusercontent.com/LinuxWaveOrg/LinuxWave}")"
# 内置默认值，只用来判断「用户是不是在用镜像」（install.sh 的欢迎语据此提示一句）。
# 必须与上一行的默认值、以及 lib/domains.py 的 DEFAULTS["core"] 一致 ——
# scripts/check_domain_defaults.py 会比对这三处。
CORE_DEFAULT_URL="https://raw.githubusercontent.com/LinuxWaveOrg/LinuxWave"
SELFUPDATE_URL="$(lw_domain LINUXWAVE_SELFUPDATE_DOMAIN "${LINUXWAVE_SELFUPDATE_DOMAIN:-https://raw.githubusercontent.com/LinuxWaveOrg/configdata/main}")"
PYTHON_DATA_URL="$(lw_domain LINUXWAVE_PYTHON_DOMAIN "${LINUXWAVE_PYTHON_DOMAIN:-https://raw.githubusercontent.com/LinuxWaveOrg/configdata/main}")"
# pip 的索引：只影响「装 requests/packaging/rich」这一次调用，不参与「从哪儿取文件」
PIP_INDEX_URL="$(lw_domain LINUXWAVE_PIP_INDEX "${LINUXWAVE_PIP_INDEX:-https://pypi.org/simple}")"

# 数据仓库：版本号、代码分支与文件清单都从这里读
CONFIGDATA_URL="$SELFUPDATE_URL"   # 版本数据与自更新数据同源，见下方域名块

# ==========================================
# 辅助函数：将路径中的 $HOME 替换为 ~
# ==========================================

home_to_tilde() {
    local path="$1"
    if [[ "$path" == "$HOME"* ]]; then
        echo "~${path#$HOME}"
    else
        echo "$path"
    fi
}

# 同上，但结果会**原样交给用户复制执行**，所以要照顾 shell 的展开规则：
#   - `~` 只在引号外展开，`"~/a b/x"` 展开不了；含空格的片段写成 `~/"a b"/x`，
#     bash、zsh 与 csh 都实测可用。
#   - 路径不在家目录下且含空格时，整段加引号。
home_to_tilde_arg() {
    local path="$1"
    local prefix="" rest="$path"
    if [[ "$path" == "$HOME" || "$path" == "$HOME"/* ]]; then
        prefix="~"
        rest="${path#"$HOME"}"
        rest="${rest#/}"
        [[ -z "$rest" ]] && { printf '~'; return; }
    fi
    if [[ "$rest" == *" "* || "$rest" == *'"'* ]]; then
        rest="${rest//\"/\\\"}"
        printf '%s"%s"' "${prefix:+$prefix/}" "$rest"
    else
        printf '%s%s' "${prefix:+$prefix/}" "$rest"
    fi
}

# ==========================================
# 辅助函数：校验自定义目录，防止路径穿越
# ==========================================

validate_custom_dir() {
    local dir="$1"

    if [[ -z "$dir" ]]; then
        lw_say_err "${RED_BOLD}🌊 Error: Empty path is not allowed.${RESET}" \
            "${RED_BOLD}🌊 错误：路径不能为空。${RESET}"
        return 1
    fi

    if [[ "$dir" == *".."* ]]; then
        lw_say_err "${RED_BOLD}🌊 Error: Path traversal ('..') is not allowed.${RESET}" \
            "${RED_BOLD}🌊 错误：路径中不允许出现 '..'。${RESET}"
        return 1
    fi

    if [[ "$dir" == *$'\n'* ]] || [[ "$dir" == *$'\r'* ]] || [[ "$dir" == *$'\t'* ]]; then
        lw_say_err "${RED_BOLD}🌊 Error: Invalid control characters in path.${RESET}" \
            "${RED_BOLD}🌊 错误：路径中包含非法控制字符。${RESET}"
        return 1
    fi

    if LC_ALL=C grep -q '[^a-zA-Z0-9/_.~ -]' <<< "$dir"; then
        lw_say_err "${RED_BOLD}🌊 Error: Path contains non-ASCII or invalid characters.${RESET}" \
            "${RED_BOLD}🌊 错误：路径包含非 ASCII 字符或非法字符。${RESET}"
        lw_say_err "${RED_BOLD}🌊 Only ASCII letters, digits, '/', '-', '_', '.', '~', and spaces are allowed.${RESET}" \
            "${RED_BOLD}🌊 只允许 ASCII 字母、数字以及 '/' '-' '_' '.' '~' 和空格。${RESET}"
        return 1
    fi

    local expanded="${dir/#\~/$HOME}"

    if [[ "$expanded" != /* ]]; then
        lw_say_err "${RED_BOLD}🌊 Error: Please use an absolute path (starting with / or ~).${RESET}" \
            "${RED_BOLD}🌊 错误：请使用绝对路径（以 / 或 ~ 开头）。${RESET}"
        return 1
    fi

    if [[ "$expanded" == *"//"* ]]; then
        lw_say_err "${RED_BOLD}🌊 Error: Path contains consecutive slashes.${RESET}" \
            "${RED_BOLD}🌊 错误：路径中包含连续的斜杠。${RESET}"
        return 1
    fi

    if [[ "$expanded" == "/" ]]; then
        lw_say_err "${RED_BOLD}🌊 Error: Cannot install to root directory.${RESET}" \
            "${RED_BOLD}🌊 错误：不能安装到根目录。${RESET}"
        return 1
    fi

    # 下面三条是这个函数最要紧的部分。
    #
    # 装到系统目录时会 `lw_privileged chown -R root:root "$BASE_DIR"`（非共享）或交给
    # `$SHARED_USER`（共享安装），而拒绝协议时的回滚是 `rm -rf "$BASE_DIR"`。
    # 如果 BASE_DIR 是 /usr/local 这种「别的软件的家」，这两件事分别是**把整个
    # 系统目录接管过来**和**删掉它** —— 与 MacWave 4.3.0 修掉的是同一类问题。

    # 1) 这些目录本身绝不能被当作安装根目录。它们的子目录可以（/opt/linuxwave、
    #    /usr/local/linuxwave），正因为如此才要按「完全相等」判，不能用前缀。
    local _forbidden
    for _forbidden in /bin /sbin /usr /usr/bin /usr/sbin \
                     /usr/lib /usr/lib64 /usr/libexec /usr/local /usr/share \
                     /opt /etc /var /tmp /boot /dev /proc /sys /run \
                     /srv /mnt /media /root /home /lib /lib64; do
        if [[ "$expanded" == "$_forbidden" ]]; then
            lw_say_err "${RED_BOLD}🌊 Error: '$expanded' is a system directory, not an install directory.${RESET}" \
                "${RED_BOLD}🌊 错误：'$expanded' 是系统目录，不能当作安装目录。${RESET}"
            lw_say_err "🌊 Pick a directory of its own, for example ${_forbidden}/linuxwave" \
                "🌊 请用一个专属目录，例如 ${_forbidden}/linuxwave"
            return 1
        fi
    done

    # 2) 家目录本身同理。装进去会把 LinuxWave 的文件撒得到处都是，回滚时还会
    #    rm -rf 整个家目录。
    if [[ "$expanded" == "$HOME" ]]; then
        lw_say_err "${RED_BOLD}🌊 Error: Cannot install directly into your home directory.${RESET}" \
            "${RED_BOLD}🌊 错误：不能直接装到家目录里。${RESET}"
        lw_say_err "🌊 Use a subdirectory such as ~/linuxwave" "🌊 请用一个子目录，例如 ~/linuxwave"
        return 1
    fi

    # 3) 已存在且非空、又不是 LinuxWave 安装的目录：拒绝。
    #    判据是 lib/wave.py：只有安装树有它，所以重装与升级仍然放行。
    if [[ -d "$expanded" && ! -f "$expanded/lib/wave.py" ]]; then
        if [[ -n "$(ls -A "$expanded" 2>/dev/null)" ]]; then
            lw_say_err "${RED_BOLD}🌊 Error: '$expanded' already exists and is not empty.${RESET}" \
                "${RED_BOLD}🌊 错误：'$expanded' 已存在且非空。${RESET}"
            lw_say_err "🌊 Installing here would take ownership of files LinuxWave did not create;" \
                "🌊 装在这里会把 LinuxWave 没创建过的文件一并接管；"
            lw_say_err "🌊 pick a new or empty directory instead." "🌊 请改用一个新的或空的目录。"
            return 1
        fi
    fi

    echo "$expanded"
    return 0
}

# ==========================================
# 共享安装：前置准备清单
# ==========================================

print_shared_install_notes() {
    lw_say ""
    lw_say "${YELLOW}🌊 Shared install (Linuxbrew style)${RESET}" \
        "${YELLOW}🌊 共享安装（Linuxbrew 式）${RESET}"
    lw_say "🌊 Install directory : $SHARED_BASE_DIR" "🌊 安装目录：$SHARED_BASE_DIR"
    lw_say "🌊 Config directory  : $SHARED_CONFIG_DIR  (system-level, shared by every user)" \
        "🌊 配置目录：$SHARED_CONFIG_DIR（系统级，全机共用）"
    lw_say "🌊 Owner             : $SHARED_USER" "🌊 归属用户：$SHARED_USER"
    lw_say ""
    lw_say "${YELLOW}🌊 Make sure these are ready before continuing:${RESET}" \
        "${YELLOW}🌊 继续之前请确认这几件事：${RESET}"
    lw_say "   1. sudo - needed once, to create $SHARED_HOME and write $SHARED_CONFIG_DIR" \
        "   1. sudo —— 建 $SHARED_HOME 与写 $SHARED_CONFIG_DIR 时各需要一次"
    lw_say "   2. patchelf - dependency libraries cannot be relocated without it:" \
        "   2. patchelf —— 没有它无法重定位依赖库："
    lw_say "        Debian/Ubuntu : sudo apt install patchelf" "        Debian/Ubuntu：sudo apt install patchelf"
    lw_say "        Fedora/RHEL   : sudo dnf install patchelf" "        Fedora/RHEL  ：sudo dnf install patchelf"
    lw_say "        Arch          : sudo pacman -S patchelf" "        Arch         ：sudo pacman -S patchelf"
    lw_say "   3. Python 3.14 or above - required by LinuxWave and by .conda packages" \
        "   3. Python 3.14 或更高 —— LinuxWave 与 .conda 包都需要"
    lw_say ""
    lw_say "${YELLOW}🌊 4. One thing you must do afterwards: log out and back in.${RESET}" \
        "${YELLOW}🌊 4. 装完之后必须做一件事：注销再登录。${RESET}"
    lw_say "${YELLOW}🌊    Packages are installed through the '$SHARED_USER' group, and '$CURRENT_USER'${RESET}" \
        "${YELLOW}🌊    装包是通过 '$SHARED_USER' 组完成的，本次安装已把 '$CURRENT_USER'${RESET}"
    lw_say "${YELLOW}🌊    is added to it by this install - but a group only takes effect in a new${RESET}" \
        "${YELLOW}🌊    加进该组 —— 但组身份只在下一次登录会话里生效。${RESET}"
    lw_say "${YELLOW}🌊    login session. Until you re-login the tree is still unwritable and 'wave'${RESET}" \
        "${YELLOW}🌊    在重新登录之前，安装树对你仍是不可写的，'wave' 会如实告诉你。${RESET}"
    lw_say "${YELLOW}🌊    will say so. Nothing is broken; just log out and back in (or run${RESET}" \
        "${YELLOW}🌊    什么都没坏：注销重登即可，也可以在当前 shell 里运行${RESET}"
    lw_say "${YELLOW}🌊    'newgrp $SHARED_USER' in this shell).${RESET}" \
        "${YELLOW}🌊    'newgrp $SHARED_USER'。${RESET}"
    lw_say "🌊    To start installing now, without re-logging:${RESET}" \
        "🌊    不想重登、现在就要装包的话：${RESET}"
    lw_say "       newgrp $SHARED_USER           # new subshell with the group; 'exit' leaves it" \
        "       newgrp $SHARED_USER           # 进入带该组的子 shell，exit 退出"
    lw_say "       sg $SHARED_USER -c 'wave install <package>'    # one-off" \
        "       sg $SHARED_USER -c 'wave install <包名>'    # 只跑一次"
    lw_say "🌊    Afterwards, run 'id -G' inside that shell: some implementations of newgrp${RESET}" \
        "🌊    进去之后先跑一次 'id -G'：某些 newgrp 实现会把你的其他组权限一并重置${RESET}"
    lw_say "🌊    reset your other supplementary groups (docker, sudo, …) in that shell.${RESET}" \
        "🌊    （docker、sudo 之类），那一层 shell 里就没有它们了。${RESET}"
    lw_say ""
    lw_say "🌊 The '$SHARED_USER' account is created automatically if missing." \
        "🌊 缺少 '$SHARED_USER' 账号时会自动创建。"
    lw_say "🌊 Every user on this machine will be able to run 'wave'." \
        "🌊 本机所有用户都能运行 'wave'。"
    lw_say "🌊 Installs are shared through that group, so they need neither sudo nor a full" \
        "🌊 装包通过该组共享，所以既不需要 sudo，也不需要写全路径："
    lw_say "🌊 path:"
    lw_say "     wave install <package>"
    lw_say "🌊 More users: sudo usermod -aG $SHARED_USER <user>   (they re-login as well)" \
        "🌊 再开一个用户：sudo usermod -aG $SHARED_USER <用户名>（同样要重新登录）"
    lw_say ""
}

# ==========================================
# 命令行参数（批量 / 脚本化安装）
# ==========================================

# 默认值不在这里定 —— 见文件开头的说明：`set -u` 之下，它们必须在任何读取之前
# 就有值，而写盘预检与探针都在解析之前跑。

usage() {
    if [[ "$LW_LANG" == "zh" ]]; then
        cat <<'USAGE_EOF'
LinuxWave 安装器

用法：
  install.sh [选项]

选项：
  --install-python-from-source
                         自带解释器从数据里记的上游地址取，不走我们自己的仓库
                         （与 `wave selfupdate` 同名旗标含义一致）
      --ci               全程无交互：目录菜单与协议都自动应答。不带 --dir-option
                         时用推荐默认项（第 1 项，共享安装），那一项需要 sudo。
                         需要提权时要求免密 sudo 或 root。
      --dry-run          只打印将要做什么，不建目录、不下载、不写配置
      --raw              纯文本输出：无颜色、无 🌊，给日志与脚本用
      --zh               说中文（默认英文）
      --print-usage      打印本用法后继续执行（--help 则打印后停止）
      --skip-probe       不访问自更新探针（离线/自建镜像时用）
      --skip-platform-check
                         跳过平台检查（不是 Linux 也继续）。调试用，
                         通常与 --dry-run 连用；装出来能不能跑本机不保证
      --dir-option=N     免菜单直接选第 N 项（1-5）
      --dir-option=DIR   直接用 DIR 作为安装目录（等同 --dir-option=5=DIR）
      --dir-option=N=DIR 选第 N 项；自定义项（5）用 DIR 作为安装目录
  -h, --help             显示本帮助后停止

目录菜单：
  1. /home/linuxwave/.linuxwave（共享安装，全机可用）[推荐]
  2. ~/.local/linuxwave
  3. /opt/linuxwave
  4. /usr/local/linuxwave
  5. 其它（自行输入目录）

示例：
  install.sh --ci                      # 推荐：共享安装
  install.sh --ci --dir-option=2       # 用户级安装，不需要 sudo
  install.sh --ci --dir-option=5=/opt/mylw
  install.sh --ci --dir-option=/opt/mylw
USAGE_EOF
    else
        cat <<'USAGE_EOF'
LinuxWave installer

Usage:
  install.sh [options]

Options:
  --install-python-from-source
                         Fetch the bundled Python from its upstream URL instead of
                         our own store (same meaning as on `wave selfupdate`)
      --ci               No interaction at all: the directory menu and the
                         agreement are answered automatically. Without
                         --dir-option the recommended default (option 1, the
                         shared install) is used, and that one needs sudo.
                         Requires passwordless sudo when privilege is needed.
      --dry-run          Print what would be done; create/download/write nothing
      --raw              Plain output: no colours, no 🌊, for logs and scripts
      --zh               Speak Chinese (English by default)
      --print-usage      Print this usage, then continue (--help stops instead)
      --skip-probe       Do not contact the self-update probe (offline mirrors)
      --skip-platform-check
                         Continue even if this is not Linux. For debugging,
                         usually with --dry-run; the result is not tested here
      --dir-option=N     Pick menu entry N without prompting (1-5).
      --dir-option=DIR   Use DIR as the installation directory (shorthand for
                         --dir-option=5=DIR).
      --dir-option=N=DIR Pick entry N and, for the custom entry (5), use DIR
                         as the installation directory.
  -h, --help             Show this help and stop.

Directory menu:
  1. /home/linuxwave/.linuxwave (shared, all users) [recommended]
  2. ~/.local/linuxwave
  3. /opt/linuxwave
  4. /usr/local/linuxwave
  5. other (enter custom directory)

Examples:
  install.sh --ci                      # recommended: shared install
  install.sh --ci --dir-option=2       # user-level, no sudo
  install.sh --ci --dir-option=5=/opt/mylw
  install.sh --ci --dir-option=/opt/mylw
USAGE_EOF
    fi
}

# 呈现（--raw / --zh）先于循环装上：循环里任何一处报错都应该是这条命令该有的
# 样子，而不是等到解析完之后才发现「原来是 --raw」。CLI_ARGV 留一份原始参数，
# lw_apply_presentation 从里面认旗标 —— 它不依赖解析结果，所以放在这里安全。
CLI_ARGV=("$@")
lw_apply_presentation

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ci|--CI)
            # 无人值守：目录菜单与协议都自动应答。旧名字 -S/--silent 在 4.0
            # 废弃（大版本允许破坏性变更），见到就说清楚该换成什么。
            CLI_CI=true
            ;;
        -S|--silent)
            lw_say_err "${RED_BOLD}🌊 Error: -S/--silent was renamed to --ci in 4.0.${RESET}" \
                "${RED_BOLD}🌊 错误：-S/--silent 在 4.0 已更名为 --ci。${RESET}"
            lw_say_err "🌊 Use: install.sh --ci …" "🌊 请改用：install.sh --ci …"
            exit 1
            ;;
        --dry-run|--DRY-RUN)
            CLI_DRY_RUN=true
            ;;
        --raw|--RAW)
            CLI_RAW=true
            ;;
        --zh|--ZH)
            LW_LANG="zh"
            ;;
        --print-usage|--PRINT-USAGE)
            CLI_PRINT_USAGE=true
            ;;
        --skip-probe|--SKIP-PROBE)
            CLI_SKIP_PROBE=true
            ;;
        --skip-platform-check|--SKIP-PLATFORM-CHECK)
            # 预扫已经认过一次（闸门在解析之前），这里再认一次是为了让 `--help`
            # 与用法里的这一项名副其实：解析路径与预扫路径必须收尾一致。
            CLI_SKIP_PLATFORM_CHECK=true
            ;;
        --install-python-from-source)
            # 自带的解释器一律从数据里的上游地址取，不试我们自己托管的副本
            export LINUXWAVE_PYTHON_FROM_SOURCE=1
            ;;
        --dir-option=*)
            _value="${1#--dir-option=}"
            # 只有 N=DIR（前缀是数字）才拆分；--dir-option=<路径> 里若本身带 '='，
            # 整条按路径处理，不会被误拆。
            if [[ "$_value" == *=* && "${_value%%=*}" =~ ^[0-9]+$ ]]; then
                CLI_DIR_OPTION="${_value%%=*}"
                CLI_CUSTOM_DIR="${_value#*=}"
            else
                CLI_DIR_OPTION="$_value"
            fi
            ;;
        -h|--help)
            CLI_HELP=true
            ;;
        *)
            lw_say_err "${RED_BOLD}🌊 Error: unknown option '$1'. Try --help.${RESET}" \
                "${RED_BOLD}🌊 错误：未知选项 '$1'。可试 --help。${RESET}"
            exit 1
            ;;
    esac
    shift
done

# --raw / --zh 要在真正开始说话之前生效：后面每一行都经 lw_say。
lw_apply_presentation

# ==========================================
# --help 的连用规则
# ==========================================
#
# --help 只回答「怎么用」，不安装。所以它只允许两种出现方式：
#
#   install.sh --help                 打用法，停在这里
#   install.sh --help --dry-run       打用法，然后照 --dry-run 走一遍（不安装）
#
# 与其它安装参数连用一律报错：`--help --ci --dir-option=2` 读起来像「按这些参数
# 装」，实际却只打帮助 —— 拦下来比让人以为装过了强。--zh / --raw 例外，它们只改
# 呈现；--skip-platform-check 也例外，它只是把闸门关掉，本身不装任何东西。
if [[ "$CLI_HELP" == "true" ]]; then
    _lw_bad=""
    for _lw_arg in ${CLI_ARGV[@]+"${CLI_ARGV[@]}"}; do
        case "$_lw_arg" in
            -h|--help|--dry-run|--DRY-RUN|--zh|--ZH|--raw|--RAW) ;;
            --skip-platform-check|--SKIP-PLATFORM-CHECK) ;;
            *) _lw_bad="$_lw_arg"; break ;;
        esac
    done
    if [[ -n "$_lw_bad" ]]; then
        lw_say_err "${RED_BOLD}🌊 Error: --help cannot be combined with '$_lw_bad'.${RESET}" \
            "${RED_BOLD}🌊 错误：--help 不能和 '$_lw_bad' 连用。${RESET}"
        lw_say_err "🌊 --help only prints the usage and stops. Two ways to go further:" \
            "🌊 --help 只打用法、不安装。想再往下走有两条路："
        lw_say_err "🌊   install.sh --help --dry-run    print the usage, then walk the install" \
            "🌊   install.sh --help --dry-run    先打用法，再走一遍流程（不安装）"
        lw_say_err "🌊   install.sh --print-usage       print the usage, then install for real" \
            "🌊   install.sh --print-usage       先打用法，再真的安装"
        exit 1
    fi
fi

if [[ "$CLI_PRINT_USAGE" == "true" ]]; then
    usage
fi

if [[ "$CLI_HELP" == "true" ]]; then
    usage
    # 与 --dry-run 连用时继续往下走；单独出现时到此为止（探针都不碰，断网也能看）。
    [[ "$CLI_DRY_RUN" == "true" ]] || exit 0
fi

# 用 `/bin/bash -c "$(curl ...)"` 运行时，第一个参数会变成脚本名（$0）：
#   /bin/bash -c "$(curl ...)" --ci        ← --ci 成了 $0，被静默丢掉
# 正确写法是加 `--`：它结束 bash 自身的选项，后面的参数才会传进脚本。
# 这里明确提示，避免「静默模式没生效、脚本却卡在交互上」。
case "$0" in
    --) ;;              # 正确写法：`--` 之后的参数才轮到脚本
    -*)
        lw_say_err "${YELLOW}🌊 Warning: '$0' was treated as the script name, not as an option.${RESET}" \
            "${YELLOW}🌊 警告：'$0' 被当成了脚本名，而不是选项。${RESET}"
        lw_say_err "${YELLOW}🌊 Put installer options after '--', which ends bash's own options.${RESET}" \
            "${YELLOW}🌊 请把选项写在 '--' 之后：'--' 会结束 bash 自身的选项。${RESET}"
        lw_say_err "🌊   /bin/bash -c \"\$(curl -fsSL <url>)\" -- $0" \
            "🌊   正确写法：/bin/bash -c \"\$(curl -fsSL <url>)\" -- --ci"
        ;;
esac

# --dir-option=<路径> 是 --dir-option=5=<路径> 的简写：值不是纯数字时，
# 直接把该值当作自定义安装目录（纯数字仍走下面的 1-5 校验，超范围会报错）。
if [[ -n "$CLI_DIR_OPTION" && ! "$CLI_DIR_OPTION" =~ ^[0-9]+$ ]]; then
    CLI_CUSTOM_DIR="$CLI_DIR_OPTION"
    CLI_DIR_OPTION="5"
fi

if [[ -n "$CLI_DIR_OPTION" && ! "$CLI_DIR_OPTION" =~ ^[1-5]$ ]]; then
    lw_say_err "${RED_BOLD}🌊 Error: --dir-option must be 1-5, got '$CLI_DIR_OPTION'.${RESET}" \
        "${RED_BOLD}🌊 错误：--dir-option 必须是 1-5，收到 '$CLI_DIR_OPTION'。${RESET}"
    exit 1
fi

if [[ "$CLI_DIR_OPTION" == "5" && -z "$CLI_CUSTOM_DIR" && "$CLI_CI" == "true" ]]; then
    lw_say_err "${RED_BOLD}🌊 Error: --dir-option=5 needs a directory in --ci mode.${RESET}" \
        "${RED_BOLD}🌊 错误：--ci 模式下 --dir-option=5 必须附上目录。${RESET}"
    lw_say_err "${RED_BOLD}🌊 Use --dir-option=5=/some/dir${RESET}" "${RED_BOLD}🌊 请写成 --dir-option=5=/some/dir${RESET}"
    exit 1
fi

# ==========================================
# 版本号与代码分支（读自更新探针，不写死在脚本里）
# ==========================================
#
# 位置在参数解析**之后**：探针要联网，而 --help / --raw 都是本地就能答的事，
# 不能因为连不上自更新数据就打不出帮助；探针的提示行也得按 --raw 该有的样子输出。
#
# 4.0 起自更新数据是两级结构：
#
#   linuxwavedata/latest.toml                哪个版本是最新的（每次发版都变）
#   linuxwavedata/<版本>/update_commands.sh  那个版本「下载什么、放到哪」（按版本冻结）
#
# 拆开的理由：装了旧版本的用户仍在运行，他们那份更新说明不能因为发了新版就变样。
#
# 迁移期回落到 3.x 的 versiondata/latest_version —— 镜像上两份可以并存，
# 谁也不会被打断。

PROBE_URL="$CONFIGDATA_URL/linuxwavedata/latest.toml"
PROBE_DATA=""
LINUXWAVE_VERSION=""
LATEST_BRANCH=""
EXPECTED_UPDATE_COMMANDS_SHA256=""

if [[ "$CLI_SKIP_PROBE" == "true" ]]; then
    # --skip-probe：不碰探针。此时版本号与分支只能靠环境变量给，否则后面的下载
    # 没有目标。
    LINUXWAVE_VERSION="${LINUXWAVE_VERSION:-}"
    LATEST_BRANCH="${LINUXWAVE_BRANCH:-HEAD}"
else
    PROBE_DATA="$(curl -fsSL --max-time 30 "$PROBE_URL" 2>/dev/null || true)"
    if [[ -n "$PROBE_DATA" ]]; then
        # 先验签再看字段：签名覆盖的正是下面要读的这份内容。
        lw_verify_latest_signature "$PROBE_DATA" "$PROBE_URL"
        LINUXWAVE_VERSION="$(read_toml_string "$PROBE_DATA" version)"
        LATEST_BRANCH="$(read_toml_string "$PROBE_DATA" branch)"
        EXPECTED_UPDATE_COMMANDS_SHA256="$(read_toml_string "$PROBE_DATA" update_commands_sha256)"
    fi
fi

if [[ -z "$LINUXWAVE_VERSION" || -z "$LATEST_BRANCH" ]]; then
    # 3.x 回落：versiondata/latest_version
    LATEST_VERSION_DATA="$(curl -fsSL --max-time 30 "$CONFIGDATA_URL/versiondata/latest_version" 2>/dev/null || true)"
    LINUXWAVE_VERSION="$(printf '%s\n' "$LATEST_VERSION_DATA" | sed -n 's/^version:[[:space:]]*"\(.*\)"/\1/p' | head -n 1)"
    LATEST_BRANCH="$(printf '%s\n' "$LATEST_VERSION_DATA" | sed -n 's/^branch:[[:space:]]*"\(.*\)"/\1/p' | head -n 1)"
fi

if [[ -z "$LINUXWAVE_VERSION" || -z "$LATEST_BRANCH" ]]; then
    lw_say_err "${RED_BOLD}🌊 Error: Cannot read the latest version from the self-update probe.${RESET}" \
        "${RED_BOLD}🌊 错误：读不到自更新探针里的版本号。${RESET}"
    lw_say_err "🌊 Check your network or proxy, then run the installer again." \
        "🌊 请检查网络或代理后重新运行安装器。"
    exit 1
fi

BRANCH="$LATEST_BRANCH"
BASE_URL="$CORE_URL/$BRANCH"

# ==========================================
# 显示欢迎信息
# ==========================================

# WAVE 艺术字。与语言无关，两种语言都打 —— 它只是装饰，不值得为它写两份。
#
# --raw 时整段跳过：那是给日志和 grep 看的输出，六行全是块字符，只会把真正的
# 内容顶出屏幕、把日志撑满。装饰不参与「装得成不成」这件事，去掉它不影响任何断言。
if ! lw_raw; then
    echo ""
    printf '%b\n' "${SKY_BLUE}██╗    ██╗ █████╗ ██╗   ██╗███████╗${RESET}"
    printf '%b\n' "${SKY_BLUE}██║    ██║██╔══██╗██║   ██║██╔════╝${RESET}"
    printf '%b\n' "${SKY_BLUE}██║ █╗ ██║███████║██║   ██║█████╗  ${RESET}"
    printf '%b\n' "${SKY_BLUE}██║███╗██║██╔══██║╚██╗ ██╔╝██╔══╝  ${RESET}"
    printf '%b\n' "${SKY_BLUE}╚███╔███╔╝██║  ██║ ╚████╔╝ ███████╗${RESET}"
    printf '%b\n' "${SKY_BLUE} ╚══╝╚══╝ ╚═╝  ╚═╝  ╚═══╝  ╚══════╝${RESET}"
    echo ""
fi
lw_say "🌊 Welcome to LinuxWave $LINUXWAVE_VERSION!" "🌊 欢迎使用 LinuxWave $LINUXWAVE_VERSION！"

# 用了镜像就明说一句。装完遇到问题，第一件事是确认自己连的到底是谁 —— 而镜像地址里
# 可能带凭据，所以过一遍 lw_redact。
if [[ "$CORE_URL" != "$CORE_DEFAULT_URL" ]]; then
    lw_say "🌊 Core files come from a mirror: $(lw_redact "$CORE_URL")" \
        "🌊 程序文件来自镜像：$(lw_redact "$CORE_URL")"
fi

echo ""

# ==========================================
# 检测系统架构
# ==========================================

ARCH=$(uname -m)
lw_say "🌊 Detected architecture: $ARCH" "🌊 检测到架构：$ARCH"

# ==========================================
# 共享安装（菜单推荐项，选项 1）相关常量
# ==========================================

SHARED_INSTALL=false
SHARED_USER="linuxwave"
SHARED_HOME="/home/$SHARED_USER"
SHARED_BASE_DIR="$SHARED_HOME/.linuxwave"
SHARED_CONFIG_DIR="$SYS_ROOT/etc/linuxwave_config"

# ==========================================
# 交互式目录选择
# ==========================================

print_dir_menu() {
    lw_say "${YELLOW}Where do you want to install LinuxWave? (Enter the number)${RESET}" \
        "${YELLOW}你想把 LinuxWave 装到哪里？（输入序号）${RESET}"
    lw_say "1. $SHARED_BASE_DIR (shared, all users) [recommended]" \
        "1. $SHARED_BASE_DIR（共享安装，全机可用）[推荐]"
    lw_say "2. ~/.local/linuxwave" "2. ~/.local/linuxwave"
    lw_say "3. /opt/linuxwave" "3. /opt/linuxwave"
    lw_say "4. /usr/local/linuxwave" "4. /usr/local/linuxwave"
    lw_say "5. other (enter custom directory)" "5. 其它（自行输入目录）"
    echo ""
    lw_say "${YELLOW}Enter your choice:${RESET}" "${YELLOW}请输入序号：${RESET}"
}

# 目录菜单对 x86_64 与 arm64 完全一致。
# MacWave 曾把 /usr/local 限制为 Intel Mac（Apple 芯片上不建议写入 /usr/local），
# Linux 没有这个限制，因此这里不做区分。
if [[ -n "$CLI_DIR_OPTION" ]]; then
    choice="$CLI_DIR_OPTION"
    lw_say "🌊 Directory option: $choice (from --dir-option)" \
        "🌊 目录选项：$choice（来自 --dir-option）"
elif [[ "$CLI_CI" == "true" ]]; then
    # --ci 承诺「自动应答目录菜单」，那就明确地选默认项并说出来，
    # 而不是去读一个可能不存在的终端、再靠「无效输入」兜底。
    choice="1"
    lw_say "🌊 --ci without --dir-option: using the recommended default, $SHARED_BASE_DIR (shared)" \
        "🌊 --ci 未指定 --dir-option：使用推荐默认项 $SHARED_BASE_DIR（共享安装）"
else
    MENU_ATTEMPTS=3
    menu_try=0
    while true; do
        print_dir_menu
        # `2>/dev/null` 写在输入重定向之前：没有控制终端时打开 /dev/tty 会失败，
        # 重定向按从左到右处理，先屏蔽 stderr 才不会喷出原始报错。
        if ! read -r 2>/dev/null choice < /dev/tty; then
            # 同上：EOF 不是「输错了一个序号」，再问两次也不会有人回答。
            lw_say_err "" ""
            lw_say_err "${RED_BOLD}🌊 Error: no choice was given (end of input). Nothing was installed.${RESET}" \
                "${RED_BOLD}🌊 错误：没有选择任何目录（输入已结束）。什么都没装。${RESET}"
            lw_say_err "🌊 Re-run the installer, or pass --dir-option=N (see --help)." \
                "🌊 请重新运行安装器，或用 --dir-option=N（见 --help）。"
            exit 1
        fi
        case "$choice" in
            1|2|3|4|5)
                break
                ;;
            *)
                menu_try=$((menu_try + 1))
                echo ""
                lw_say_err "${RED_BOLD}🌊 Error: '$choice' is not one of 1-5.${RESET}" \
                    "${RED_BOLD}🌊 错误：'$choice' 不是 1-5 之一。${RESET}"
                # 绝不静默换到别的目录：那等于把东西装到用户没选的位置。
                if [[ "$menu_try" -ge "$MENU_ATTEMPTS" ]]; then
                    lw_say_err "${RED_BOLD}🌊 Gave up after $MENU_ATTEMPTS attempts. Nothing was installed.${RESET}" \
                        "${RED_BOLD}🌊 已尝试 $MENU_ATTEMPTS 次，放弃。什么都没装。${RESET}"
                    lw_say_err "🌊 Re-run the installer, or pass --dir-option=N (see --help)." \
                        "🌊 请重新运行安装器，或用 --dir-option=N（见 --help）。"
                    exit 1
                fi
                lw_say_err "${YELLOW}🌊 Please enter a number from 1 to 5.${RESET}" \
                    "${YELLOW}🌊 请输入 1 到 5 之间的序号。${RESET}"
                echo ""
                ;;
        esac
    done
fi

case "$choice" in
    1)
        SHARED_INSTALL=true
        BASE_DIR="$SHARED_BASE_DIR"
        ;;
    2)
        BASE_DIR="$HOME/.local/linuxwave"
        ;;
    3)
        BASE_DIR="$SYS_ROOT/opt/linuxwave"
        ;;
    4)
        BASE_DIR="$SYS_ROOT/usr/local/linuxwave"
        ;;
    5)
        if [[ -n "$CLI_CUSTOM_DIR" ]]; then
            custom_dir="$CLI_CUSTOM_DIR"
            lw_say "🌊 Installation directory: $custom_dir (from --dir-option)" \
                "🌊 安装目录：$custom_dir（来自 --dir-option）"
        else
            lw_say "${YELLOW}Please enter the installation directory:${RESET}" \
                "${YELLOW}请输入安装目录：${RESET}"
            read -r custom_dir < /dev/tty
        fi
        validated=$(validate_custom_dir "$custom_dir") || exit 1
        BASE_DIR="$validated"
        ;;
    *)
        # 上面已把选择校验到 1-5，这里只是兜底；
        # 无论如何都不静默换成别的目录。
        lw_say_err "${RED_BOLD}🌊 Error: unsupported directory choice '$choice'. Nothing was installed.${RESET}" \
            "${RED_BOLD}🌊 错误：不支持的目录选项 '$choice'。什么都没装。${RESET}"
        exit 1
        ;;
esac

# 调用者是谁要早于共享安装提示，提示里要报出「你」会被加进哪个组
CURRENT_USER=$(whoami)

DISPLAY_DIR=$(home_to_tilde "$BASE_DIR")

if [[ "$SHARED_INSTALL" == "true" ]]; then
    print_shared_install_notes
fi

# ==========================================
# 判断是否需要 sudo
# ==========================================

# 共享安装固定按系统级处理：安装树不在任何个人家目录之下，
# 且配置必须落在 /etc，否则其他用户会按各自的 $HOME 去找、找不到。
if [[ "$SHARED_INSTALL" == "true" ]]; then
    NEED_SUDO=true
elif [[ "$BASE_DIR" == "$HOME"* ]]; then
    NEED_SUDO=false
else
    NEED_SUDO=true
fi

lw_privileged() {
    # 提权执行一条**会改动系统**的命令。--dry-run 下只打印：试运行承诺「不建目录、
    # 不写配置」，但建账号、改属主、开组写位这些操作如果直接调 sudo，试运行就会
    # 在系统里留下一个真的 linuxwave 账号。所有写操作都走这里。
    # 只读探针（sudo -n true、sudo test -f、sudo grep）不走这里 —— 它们不改东西。
    if [[ "$CLI_DRY_RUN" == "true" ]]; then
        lw_say "${YELLOW}    sudo $*${RESET}"
        return 0
    fi
    lw_sudo "$@"
}

run_cmd() {
    # 试运行只把命令打出来：建目录、写配置、删旧文件都经由这里。
    if [[ "${CLI_DRY_RUN:-false}" == "true" ]]; then
        if [[ "$NEED_SUDO" == "true" ]]; then
            lw_say "${YELLOW}    sudo $*${RESET}"
        else
            lw_say "${YELLOW}    $*${RESET}"
        fi
        return 0
    fi
    if [[ "$NEED_SUDO" == "true" ]]; then
        lw_sudo "$@"
    else
        "$@"
    fi
}

if [[ "$NEED_SUDO" == "true" ]]; then
    if [[ "$CLI_CI" == "true" ]]; then
        # --ci 不能停下来等密码：要么已经是 root，要么已有免密 sudo
        if ! sudo -n true 2> /dev/null; then
            lw_say_err "${RED_BOLD}🌊 Error: this install needs privilege, but --ci cannot ask for a password.${RESET}" \
                "${RED_BOLD}🌊 错误：本次安装需要提权，而 --ci 不能停下来问密码。${RESET}"
            lw_say_err "${RED_BOLD}🌊 Run as root, or configure passwordless sudo for the install user.${RESET}" \
                "${RED_BOLD}🌊 请以 root 运行，或为安装用户配置免密 sudo。${RESET}"
            exit 1
        fi
    else
        lw_say "${YELLOW}🌊 Granting temporary administrator access for installation...${RESET}" \
            "${YELLOW}🌊 正在获取临时的管理员权限以完成安装……${RESET}"
        sudo -v
    fi
fi

if [[ "$SHARED_INSTALL" == "true" ]]; then
    if id "$SHARED_USER" >/dev/null 2>&1; then
        lw_say "🌊 User '$SHARED_USER' already exists." "🌊 用户 '$SHARED_USER' 已存在。"
    else
        lw_say "🌊 Creating user '$SHARED_USER'..." "🌊 正在创建用户 '$SHARED_USER'……"
        lw_privileged useradd -m -d "$SHARED_HOME" -s /bin/bash "$SHARED_USER"
    fi

    lw_privileged mkdir -p "$BASE_DIR"
    lw_privileged chown "$SHARED_USER:$SHARED_USER" "$SHARED_HOME" "$BASE_DIR"
fi

# ==========================================
# 更新命令（linuxwavedata/<版本>/update_commands.sh）
# ==========================================
#
# 要下载哪些文件、放到哪里，4.0 起由一份**按版本冻结**的脚本回答，客户端只负责
# 取回来执行：
#   - 脚本自己知道这一版该下哪些文件，所以能只列变动的那些（没碰过的文件不必重下）；
#   - 目录结构变更的迁移也写在同一个脚本里，不必再维护第二套机制；
#   - 客户端不再需要「缩进树」这种自定义格式的解析器。
#
# 这一步刻意放在「建目录 / 写配置 / 清旧版」之前：连不上就直接退出，
# 不会留下一个配置已写好、文件却一个都没下的半成品安装。

UPDATE_COMMANDS_URL="$CONFIGDATA_URL/linuxwavedata/$LINUXWAVE_VERSION/update_commands.sh"
UPDATE_COMMANDS_TMP="$(mktemp)"
UPDATE_COMMANDS_ATTEMPTS=3

# 每个文件的重试次数由更新脚本自己管；这里只管「把说明取回来」这一件事。
cleanup_update_commands() {
    rm -f "$UPDATE_COMMANDS_TMP"
}
trap cleanup_update_commands EXIT

lw_say "🌊 Fetching the update commands..." "🌊 正在获取更新命令……"

UPDATE_COMMANDS_OK=false
for attempt in $(seq 1 "$UPDATE_COMMANDS_ATTEMPTS"); do
    if curl -fsSL --max-time 60 -o "$UPDATE_COMMANDS_TMP" "$UPDATE_COMMANDS_URL"; then
        UPDATE_COMMANDS_OK=true
        break
    fi
    if [[ "$attempt" -lt "$UPDATE_COMMANDS_ATTEMPTS" ]]; then
        lw_say "${YELLOW}🌊 Retrying the update commands ($((attempt + 1))/$UPDATE_COMMANDS_ATTEMPTS)...${RESET}" \
            "${YELLOW}🌊 正在重试获取更新命令（$((attempt + 1))/$UPDATE_COMMANDS_ATTEMPTS）……${RESET}"
    fi
done

if [[ "$UPDATE_COMMANDS_OK" != "true" ]]; then
    lw_say_err "${RED_BOLD}🌊 Error: Cannot fetch the update commands for $LINUXWAVE_VERSION.${RESET}" \
        "${RED_BOLD}🌊 错误：取不到 $LINUXWAVE_VERSION 的更新命令。${RESET}"
    lw_say_err "${RED_BOLD}🌊   $(lw_redact "$UPDATE_COMMANDS_URL")${RESET}" \
        "${RED_BOLD}🌊   $(lw_redact "$UPDATE_COMMANDS_URL")${RESET}"
    lw_say_err "🌊 Nothing was installed. Check your network or proxy, then run the installer again." \
        "🌊 什么都没装。请检查网络或代理后重新运行安装器。"
    exit 1
fi

# 哈希对不上说明「即将被 bash 执行的东西」不是发布时那一份。
# 实验期只警告；LINUXWAVE_STRICT_HASHES=1 时才失败。
lw_check_integrity "update_commands.sh" "$UPDATE_COMMANDS_TMP" "$EXPECTED_UPDATE_COMMANDS_SHA256"

# 即将被 bash 执行的东西，先确认它至少是合法 shell。
if ! /bin/bash -n "$UPDATE_COMMANDS_TMP" 2>/dev/null; then
    lw_say_err "${RED_BOLD}🌊 Error: the update commands for $LINUXWAVE_VERSION are not valid shell.${RESET}" \
        "${RED_BOLD}🌊 错误：$LINUXWAVE_VERSION 的更新命令不是合法 shell。${RESET}"
    lw_say_err "🌊 Nothing was installed. Please report this to the administrator." \
        "🌊 什么都没装。请把这件事报给维护者。"
    exit 1
fi

# ==========================================
# 创建目录
# ==========================================

INSTALL_DIR="$BASE_DIR/bin"
LINKS_DIR="$BASE_DIR/links"
REPO_DIR="$BASE_DIR/pkg"
SURFBOARD_DIR="$BASE_DIR/surfboard"
LIB_DIR="$BASE_DIR/lib"
DEPS_DIR="$BASE_DIR/deps"
DOWNLOAD_DIR="$BASE_DIR/downloads/tmp"

# 配置文件目录：共享安装固定用 /etc/linuxwave_config —— 用户级那份会按
# 每个调用者各自的 $HOME 解析，其他用户会找不到。装到其他系统目录（需要
# sudo）时同样用 /etc；装在用户目录（无需 sudo）时才用 ~/.config。
# 读取时系统级优先，所以系统级 LinuxWave 总是盖过用户级的。
if [[ "$SHARED_INSTALL" == "true" ]]; then
    CONFIG_DIR="$SHARED_CONFIG_DIR"
elif [[ "$NEED_SUDO" == "true" ]]; then
    CONFIG_DIR="$SYS_ROOT/etc/linuxwave_config"
else
    CONFIG_DIR="$HOME/.config/linuxwave_config"
fi
CONFIG_FILE="$CONFIG_DIR/config.json"
VERSION_FILE="$CONFIG_DIR/VERSION.json"
# 同意记录。selfupdate.py 读的就是这个文件（AGREEMENT_FILE_NAME）；
# 里面的值来自装好的 lib/selfupdate.py 的 AGREEMENT_ID，安装器不另抄一份。
AGREEMENT_FILE="$CONFIG_DIR/AGREEMENT.json"

# 中途失败时给出明确指引。刻意**不自动删除**已下载的内容：升级安装时
# 删掉安装树会把用户原有的可用安装一起毁掉，重跑安装器才是安全的做法。
LW_OPTIONAL_RESULT=""

lw_try() {
    # lw_try <命令...>：跑一个「失败也无所谓」的命令，stdout 存进 LW_OPTIONAL_RESULT。
    # 失败时不惊动 ERR 陷阱 —— 否则用户会先看到「Installation did not finish」，
    # 几百行之后再看到「Installation complete!」，比不提示更糟。
    #
    # 旗标必须在**命令替换的整个生命周期内**保持设置：`set -E` 让 ERR 陷阱传进
    # 子 shell，而子 shell 退出时如果那条命令返回非零，陷阱照样会响。
    local output
    LW_FAILURE_HANDLED=1
    output="$("$@")" && LW_OPTIONAL_RESULT="$output" || LW_OPTIONAL_RESULT=""
    unset LW_FAILURE_HANDLED
    return 0
}

install_failed() {
    local code=$?

    # 有些失败是**预期之内**的：自带解释器取不到时会回落到系统 python3，安装照常完成。
    # 那些地方用 lw_try 包着，会临时立这个旗标，于是这里不报「安装未完成」。
    if [[ -n "${LW_FAILURE_HANDLED:-}" ]]; then
        return 0
    fi
    lw_say_err "" ""
    lw_say_err "${RED_BOLD}🌊 Installation did not finish (exit $code).${RESET}" \
        "${RED_BOLD}🌊 安装未完成（退出码 $code）。${RESET}"
    lw_say_err "🌊 Nothing was removed. Files already downloaded may be left in:" \
        "🌊 没有删除任何内容。已下载的文件可能留在："
    lw_say_err "     ${BASE_DIR:-<not chosen yet>}" "     ${BASE_DIR:-<尚未选定>}"
    lw_say_err "     ${CONFIG_DIR:-<not chosen yet>}" "     ${CONFIG_DIR:-<尚未选定>}"
    lw_say_err "🌊 Fix the cause (network, permissions, disk space) and run the installer again;" \
        "🌊 请排除原因（网络、权限、磁盘空间）后重新运行安装器；"
    lw_say_err "🌊 a repeated install overwrites what it downloaded and is safe to rerun." \
        "🌊 重复安装会覆盖已下载的内容，可以安全重跑。"
}
trap install_failed ERR

# 回滚（拒绝协议时）要不要删这棵树，取决于它是不是**本次**安装建出来的：
# 覆盖升级时 BASE_DIR 本来就在，删掉它等于毁掉用户已有的安装。
# 必须在第一条 mkdir 之前判断。
TREE_PREEXISTED=0
if [[ -d "$BASE_DIR" || -d "$CONFIG_DIR" ]]; then
    TREE_PREEXISTED=1
fi

run_cmd mkdir -p "$INSTALL_DIR"
run_cmd mkdir -p "$LINKS_DIR"
run_cmd mkdir -p "$REPO_DIR"
run_cmd mkdir -p "$SURFBOARD_DIR"
run_cmd mkdir -p "$LIB_DIR"
run_cmd mkdir -p "$DEPS_DIR"
run_cmd mkdir -p "$DOWNLOAD_DIR"
run_cmd mkdir -p "$CONFIG_DIR"
run_cmd chmod 755 "$CONFIG_DIR"

# ==========================================
# 版本目录结构变更迁移（configdata/updatedata/{版本号}）
# ==========================================
#
# configdata 的 updatedata/{版本号}/dir_structure_change 只有**一个字符**：
#     Y/y → 该版本改变了目录结构，执行同目录下的 transfer_commands 完成迁移
#     N/n → 没有改变，跳过（文件不存在也按「没有改变」处理）
# 目标版本号就是本脚本的 LINUXWAVE_VERSION（正在安装的这个版本）。
# 迁移逻辑全部由 configdata 里的脚本提供，以后目录结构再变只改 configdata，
# 不用再动这个脚本。

UPDATEDATA_URL="$CONFIGDATA_URL/updatedata/$LINUXWAVE_VERSION"

DIR_STRUCTURE_CHANGE="$(curl -fsSL --max-time 30 "$UPDATEDATA_URL/dir_structure_change" 2>/dev/null | tr -d '[:space:]')" || DIR_STRUCTURE_CHANGE=""

if [[ "$DIR_STRUCTURE_CHANGE" == "Y" || "$DIR_STRUCTURE_CHANGE" == "y" ]]; then
    lw_say "${YELLOW}🌊 Directory structure changed in $LINUXWAVE_VERSION, running migration...${RESET}" \
        "${YELLOW}🌊 $LINUXWAVE_VERSION 改变了目录结构，正在执行迁移……${RESET}"

    TRANSFER_COMMANDS="$(curl -fsSL --max-time 60 "$UPDATEDATA_URL/transfer_commands" 2>/dev/null)" || TRANSFER_COMMANDS=""
    if [[ -z "$TRANSFER_COMMANDS" ]]; then
        lw_say_err "${RED_BOLD}🌊 Error: Cannot fetch the migration script for $LINUXWAVE_VERSION.${RESET}" \
            "${RED_BOLD}🌊 错误：取不到 $LINUXWAVE_VERSION 的迁移脚本。${RESET}"
        lw_say_err "${RED_BOLD}🌊 Nothing was installed. Check your network, then run the installer again.${RESET}" \
            "${RED_BOLD}🌊 什么都没装。请检查网络后重新运行安装器。${RESET}"
        exit 1
    fi

    # 把本次安装的位置与配置目录告诉迁移脚本，由它自己判断该不该搬
    export LINUXWAVE_INSTALL_DIR="$BASE_DIR"
    export LINUXWAVE_CONFIG_DIR="$CONFIG_DIR"
    export LINUXWAVE_TARGET_VERSION="$LINUXWAVE_VERSION"

    if ! bash -c "$TRANSFER_COMMANDS"; then
        lw_say_err "${RED_BOLD}🌊 Error: The migration for $LINUXWAVE_VERSION failed.${RESET}" \
            "${RED_BOLD}🌊 错误：$LINUXWAVE_VERSION 的迁移失败。${RESET}"
        lw_say_err "${RED_BOLD}🌊 Nothing was installed. Fix the issue above, then run the installer again.${RESET}" \
            "${RED_BOLD}🌊 什么都没装。请按上面的提示排除原因后重新运行安装器。${RESET}"
        exit 1
    fi

    echo ""
fi

# ==========================================
# 写入配置文件
# ==========================================

run_cmd tee "$CONFIG_FILE" > /dev/null << EOF
{
  "base_dir": "$BASE_DIR"
}
EOF

run_cmd tee "$VERSION_FILE" > /dev/null << EOF
{
  "version": "$LINUXWAVE_VERSION",
  "components": {
    "installer": "$LINUXWAVE_VERSION",
    "parser": "$LINUXWAVE_VERSION"
  }
}
EOF

# ==========================================
# 安装过程中先把写权限交回调用者
# ==========================================
#
# 这一步只是为了让后面的下载与落盘不必每条命令都 sudo。**它不是最终属主**：
# 装完之后那块「最后一步：确定安装树的属主」会把它改成 root:root（非共享）
# 或 $SHARED_USER（共享）。两处不要合并，顺序也不能颠倒。

if [[ "$NEED_SUDO" == "true" ]]; then
    if [[ "$SHARED_INSTALL" == "true" ]]; then
        lw_privileged chown -R "$SHARED_USER:$SHARED_USER" "$BASE_DIR"
    else
        lw_privileged chown -R "$CURRENT_USER": "$BASE_DIR"
    fi
fi

# 系统级安装的配置一律 root:root 644：全体用户可读，但只有 root 能改
if [[ "$NEED_SUDO" == "true" ]]; then
    lw_privileged chown -R root:root "$CONFIG_DIR"
fi
run_cmd chmod 755 "$CONFIG_DIR"
run_cmd chmod 644 "$CONFIG_FILE"
run_cmd chmod 644 "$VERSION_FILE"

lw_say "🌊 Configuration saved to $CONFIG_FILE" "🌊 配置已保存到 $CONFIG_FILE"
lw_say "🌊 Version saved to $VERSION_FILE" "🌊 版本信息已保存到 $VERSION_FILE"

# ==========================================
# 删除旧版 repo.json
# ==========================================

OLD_JSON="$REPO_DIR/repo.json"
if [ -f "$OLD_JSON" ]; then
    lw_say "🌊 Removing old repo.json (legacy format)..." "🌊 正在删除旧格式的 repo.json……"
    run_cmd rm -f "$OLD_JSON"
fi

# ==========================================
# 清理旧版（2.1.0）遗留的平铺 bin/ 文件
# ==========================================

LEGACY_BINS=$(find "$INSTALL_DIR" -maxdepth 1 -type f 2>/dev/null || true)
if [[ -n "$LEGACY_BINS" ]]; then
    lw_say "${YELLOW}🌊 Removing files installed by an older version in $DISPLAY_DIR/bin:${RESET}" \
        "${YELLOW}🌊 正在删除旧版本装在 $DISPLAY_DIR/bin 里的文件：${RESET}"
    while IFS= read -r legacy_file; do
        echo -e "${YELLOW}    $(basename "$legacy_file")${RESET}"
    done <<< "$LEGACY_BINS"
    while IFS= read -r legacy_file; do
        run_cmd rm -f "$legacy_file"
    done <<< "$LEGACY_BINS"
    lw_say "${YELLOW}🌊 ${BRANCH} keeps packages in bin/{name}@{version}/ directories.${RESET}" \
        "${YELLOW}🌊 ${BRANCH} 把软件包放在 bin/{name}@{version}/ 目录里。${RESET}"
    lw_say "${YELLOW}🌊 Please reinstall the packages: wave install {name}${RESET}" \
        "${YELLOW}🌊 请重新安装这些包：wave install {name}${RESET}"
fi

# ==========================================
# 检查动态库路径替换所需的工具
# ==========================================

if command -v patchelf > /dev/null 2>&1; then
    lw_say "🌊 patchelf detected (dependency library relocation enabled)." \
        "🌊 已检测到 patchelf（启用依赖库重定位）。"
else
    lw_say "${YELLOW}🌊 Warning: patchelf not found.${RESET}" \
        "${YELLOW}🌊 警告：没有找到 patchelf。${RESET}"
    lw_say "${YELLOW}🌊 Dependency libraries cannot be relocated, so some packages may fail to run.${RESET}" \
        "${YELLOW}🌊 无法重定位依赖库，部分软件包可能跑不起来。${RESET}"
    lw_say "🌊 You can install it later with: sudo apt install patchelf   (or: sudo dnf install patchelf)" \
        "🌊 之后可以这样安装：sudo apt install patchelf（或 sudo dnf install patchelf）"
fi

# ==========================================
# 执行更新命令
# ==========================================
#
# 环境变量是这个脚本与更新脚本之间的合同，字段含义见 scripts/build_update_commands.py
# 的文件头。CURRENT_VERSION 留空只表示「不知道装的是哪版」，不等于全量安装 ——
# 走增量还是全量由更新脚本自己按安装树判断。

export LINUXWAVE_INSTALL_DIR="$BASE_DIR"
export LINUXWAVE_LANG="$LW_LANG"
export LINUXWAVE_CORE_URL="$CORE_URL"
export LINUXWAVE_BRANCH="$BRANCH"
export LINUXWAVE_TARGET_VERSION="$LINUXWAVE_VERSION"
export LINUXWAVE_CURRENT_VERSION=""
export LINUXWAVE_FILE_TIMEOUT=180
LINUXWAVE_NEED_SUDO="$([ "$NEED_SUDO" = "true" ] && echo 1 || echo "")"
LINUXWAVE_SILENT="$([ "$CLI_CI" = "true" ] && echo 1 || echo "")"
LINUXWAVE_RAW="$([ "$CLI_RAW" = "true" ] && echo 1 || echo "")"
LINUXWAVE_DRY_RUN="$([ "$CLI_DRY_RUN" = "true" ] && echo 1 || echo "")"
export LINUXWAVE_NEED_SUDO LINUXWAVE_SILENT LINUXWAVE_RAW LINUXWAVE_DRY_RUN

if [[ "$CLI_DRY_RUN" == "true" ]]; then
    lw_say "${YELLOW}🌊 Dry run: the update commands for $LINUXWAVE_VERSION would run now.${RESET}" \
        "${YELLOW}🌊 试运行：$LINUXWAVE_VERSION 的更新命令本该在此执行，实际未执行。${RESET}"
elif ! /bin/bash "$UPDATE_COMMANDS_TMP"; then
    lw_say_err "${RED_BOLD}🌊 Error: the update commands for $LINUXWAVE_VERSION failed.${RESET}" \
        "${RED_BOLD}🌊 错误：$LINUXWAVE_VERSION 的更新命令执行失败。${RESET}"
    lw_say_err "🌊 Nothing was recorded as installed. Fix the cause above, then run the installer again." \
        "🌊 没有记录任何安装结果。请按上面的提示排除原因后重新运行安装器。"
    exit 1
fi

# ==========================================
# Python 运行环境（自带解释器 + 私有 venv + 启动器）
# ==========================================
#
# 为什么不用 PATH 上的 python3 当入口：
#   Linux 上 `python3` 可能来自 apt / pyenv / Homebrew / conda，换个版本就换了路径，
#   而三个第三方依赖仍留在旧那个解释器的 site-packages 里。入口写死
#   `#!/usr/bin/env python3` 就会在升级后全线报错（"module not available"）。
#   Linux 上还多一层：现代 Debian/Ubuntu 的系统 Python 受 PEP 668 保护，
#   `pip3 install requests` 直接以 externally-managed-environment 失败，而本脚本是
#   `set -eE` + ERR 陷阱，于是整次安装就此中止 —— 全新机器根本装不上。
#
# 做法：
#   1. 下载上游便携 CPython（地址与校验值在 configdata 的 pythondata/latest_python），
#      校验 sha256 后解到 $BASE_DIR/python/<版本>/，并建 current 符号链接；
#   2. 在安装根目录建私有 venv，把 requests / packaging / rich 装进去；
#   3. lib/wave 变成一个 sh 启动器，按「venv → 自带解释器 → 安装时的解释器 → PATH」
#      顺序挑选，并且只有能真正 import 到三个依赖时才使用。
#
# 下载失败（网络问题）时回退系统 python3，安装不因此中断。
#
# 注意：这一整段刻意放在「把所有权交还给用户」之前 —— 紧随其后的 chown -R /
# chmod -R a+rX / g+s 会一并覆盖新生成的 python/ 与 venv/，共享安装的组员才用得了。
# 也正因为此时 BASE_DIR 可能还不属于当前用户，写操作统一走 run_cmd（必要时 sudo）。

portable_python_arch() {
    case "$(uname -m)" in
        arm64|aarch64) echo "arm64" ;;
        x86_64|amd64)  echo "amd64" ;;
        *)             echo "" ;;
    esac
}

portable_python_binary() {
    # 不同构建产物的目录布局不同，这里按常见位置逐个试探。
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
    # 把各种布局归一化成 <target>/bin/python3。
    # 启动器只认 python/current/bin/python3，不归一化的话自带解释器在第 2 层永远命中不了。
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

    # 用相对链接：整个 python/ 目录搬走以后仍然有效
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
    local attempt

    [[ -n "$arch" ]] || return 1

    # 不下载 30MB+ 的解释器的两种情形：
    #   LINUXWAVE_TEST              → 隔离测试根，离线，装完也跑不出真实安装流程
    #   LINUXWAVE_SKIP_PORTABLE_PYTHON → 沙箱测试要真装到真路径，但同样不该联网
    # 真实产物的校验与功能由 .github/workflows/portable-python.yml 负责。
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
    lw_say_err "🌊 Fetching the bundled Python definition..." "🌊 正在获取自带解释器的版本信息……"
    data_file="$(mktemp)"
    if ! curl -fsSL --max-time 30 -o "$data_file" "$data_url" 2>/dev/null; then
        rm -f "$data_file"
        return 1
    fi
    version="$(sed -n 's/^version:[[:space:]]*"\(.*\)"/\1/p' "$data_file" | head -n 1)"
    url="$(sed -n "s/^${arch}_url:[[:space:]]*\"\(.*\)\"/\1/p" "$data_file" | head -n 1)"
    sha="$(sed -n "s/^${arch}_sha256:[[:space:]]*\"\(.*\)\"/\1/p" "$data_file" | head -n 1)"
    rm -f "$data_file"

    if [[ -z "$version" || -z "$url" || -z "$sha" ]]; then
        return 1
    fi

    target="$base_dir/python/$version"
    current="$base_dir/python/current"

    if py="$(portable_python_binary "$target" 2>/dev/null)"; then
        :
    else
        lw_say_err "🌊 Downloading the bundled Python $version (about 30 MB)..." \
            "🌊 正在下载自带解释器 $version（约 30 MB）……"
        archive="$base_dir/downloads/tmp/portable-python-$version.tar.gz"
        run_cmd mkdir -p "$base_dir/downloads/tmp" 2>/dev/null || true
        # 默认先试我们自己托管的 `pythondata/<版本>/<文件名>`（镜像直连，省一次境外下载）；
        # 没有就回落到数据里写的上游地址。--install-python-from-source 直接从上游取。
        # 路径形状由 lib/domains.py 的 python_archive_url 定义，scripts/python_source_test.sh 会比对。
        # 自家存储只试一次：它不通就该立刻回上游，而不是在这里重试三次。
        if [[ -z "${LINUXWAVE_PYTHON_FROM_SOURCE:-}" ]]; then
            if run_cmd curl -fsSL --connect-timeout 20 --max-time 600 -o "$archive" \
                   "$PYTHON_DATA_URL/pythondata/$version/$(basename "$url")" 2>/dev/null; then
                :
            else
                run_cmd rm -f "$archive" 2>/dev/null || true
                lw_say_err "${YELLOW}🌊 No hosted copy of the bundled Python; using the upstream URL.${RESET}" \
                    "${YELLOW}🌊 自有存储里没有这份解释器，改从上游地址取。${RESET}"
            fi
        fi

        if [[ ! -f "$archive" ]]; then
        # 30~36MB 的下载在烂链路上很容易断，重试几次比让用户重装划算。
        for attempt in 1 2 3; do
            # 每次重试前清掉上次的半截文件：否则「文件存在」会被当成下载成功，
            # 最后倒在 sha256 比对那一步，报错方向就错了。
            run_cmd rm -f "$archive" 2>/dev/null || true
            if run_cmd curl -fsSL --retry 2 --retry-all-errors --retry-delay 3 \
                   --connect-timeout 20 --max-time 600 -o "$archive" "$url" 2>/dev/null; then
                break
            fi
            if [[ "$attempt" -lt 3 ]]; then
                lw_say_err "${YELLOW}🌊 Retrying the bundled Python download ($((attempt + 1))/3)...${RESET}" \
                    "${YELLOW}🌊 正在重试下载自带解释器（$((attempt + 1))/3）……${RESET}"
                sleep 3
            fi
        done
        fi
        if [[ ! -f "$archive" ]]; then
            return 1
        fi
        actual="$(sha256sum "$archive" 2>/dev/null | awk '{print $1}')"
        if [[ -z "$actual" && -n "$(command -v shasum)" ]]; then
            actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
        fi
        if [[ "$actual" != "$sha" ]]; then
            run_cmd rm -f "$archive" 2>/dev/null || true
            lw_say_err "${RED_BOLD}🌊 Error: the bundled Python download failed its checksum check.${RESET}" \
                "${RED_BOLD}🌊 错误：自带解释器下载后校验值不符。${RESET}"
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
    # 生成 lib/wave 启动器：把「当前选定的解释器」烘进去作为 venv 失效时的第二选择。
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

# `wave shellenv` 由 shell 直接回答，不启动 Python：这一行每次开终端都要跑。
# 输出必须与 lib/shellenv.py **逐字一致** —— scripts/shellenv_test.sh 会比对两份。
if [ "$#" -eq 1 ] && [ "$1" = "shellenv" ]; then
    printf 'case ":$PATH:" in\n  *":%s:"*) ;;\n  *) export PATH="%s:%s:%s${PATH:+:$PATH}" ;;\nesac\n' \
        "$root_dir/lib" "$root_dir/bin" "$root_dir/links" "$root_dir/lib"
    exit 0
fi

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

lw_say "🌊 Preparing the Python runtime..." "🌊 正在准备 Python 运行环境……"
lw_try ensure_portable_python "$BASE_DIR" "$(portable_python_arch)"
BUNDLED_PY="$LW_OPTIONAL_RESULT"

if [[ -n "$BUNDLED_PY" ]]; then
    PYTHON_BIN="$BUNDLED_PY"
    PYTHON_SOURCE="bundled"
    lw_say "🌊 Using the bundled Python: ${BUNDLED_PY#"$BASE_DIR"/}" \
        "🌊 使用自带解释器：${BUNDLED_PY#"$BASE_DIR"/}"
else
    PYTHON_BIN="$(command -v python3 || true)"
    PYTHON_SOURCE="system"
    if [[ -z "$PYTHON_BIN" ]]; then
        lw_say_err "${RED_BOLD}🌊 Error: no Python 3 interpreter is available.${RESET}" \
            "${RED_BOLD}🌊 错误：没有可用的 Python 3 解释器。${RESET}"
        lw_say_err "${RED_BOLD}🌊 The bundled Python could not be downloaded and python3 is not in PATH.${RESET}" \
            "${RED_BOLD}🌊 自带解释器下载失败，PATH 上也没有 python3。${RESET}"
        exit 1
    fi
    lw_say "${YELLOW}🌊 Warning: could not prepare the bundled Python; using $PYTHON_BIN instead.${RESET}" \
        "${YELLOW}🌊 警告：没能准备好自带解释器，改用 $PYTHON_BIN。${RESET}"
    lw_say "${YELLOW}🌊 Re-run the installer when the network is available to make this installation self-contained.${RESET}" \
        "${YELLOW}🌊 网络可用时重跑一次安装器，就能把这次安装补齐成自带环境的形态。${RESET}"
fi

run_cmd mkdir -p "$VENV_DIR" 2>/dev/null || true

if run_cmd "$PYTHON_BIN" -m venv "$VENV_DIR" >/dev/null 2>&1; then
    VENV_PY="$VENV_DIR/bin/python3"
    [[ -x "$VENV_PY" ]] || VENV_PY="$VENV_DIR/bin/python"
    lw_say "🌊 Private Python environment ready: ${VENV_DIR#"$BASE_DIR"/}" \
        "🌊 私有 Python 环境已就绪：${VENV_DIR#"$BASE_DIR"/}"
else
    VENV_PY=""
    lw_say "${YELLOW}🌊 Warning: could not create a private virtualenv; using the ${PYTHON_SOURCE} interpreter directly.${RESET}" \
        "${YELLOW}🌊 警告：无法创建私有 venv，直接使用 ${PYTHON_SOURCE} 解释器。${RESET}"
fi

deps_present() {
    # 判断一个解释器是否真的能 import 到三个依赖（启动器用的是同一条判据）
    [[ -n "$1" ]] || return 1
    "$1" -c 'import requests, packaging, rich' >/dev/null 2>&1
}

if [[ -n "$VENV_PY" && -x "$VENV_PY" ]]; then
    lw_say "🌊 Installing Python dependencies into the private environment..." \
        "🌊 正在把 Python 依赖装进私有环境……"
    # --timeout/--retries 收小：离线环境里让 pip 尽快失败，好走到下面的降级分支，
    # 而不是死等默认的长超时（隔离测试根里每次安装都会走一遍）。
    run_cmd "$VENV_PY" -m pip install --quiet --timeout 10 --retries 1 --upgrade pip >/dev/null 2>&1 || true
    run_cmd "$VENV_PY" -m pip install --quiet --timeout 10 --retries 1 requests packaging rich >/dev/null 2>&1 || true

    if deps_present "$VENV_PY"; then
        :
    else
        # 拿不到 PyPI 时（离线安装、镜像不可达），退回「继承父解释器 site-packages」
        # 的 venv —— 系统 python3 上通常已经有这三个包（apt 的 python3-requests 等），
        # 这样离线环境也能装完并跑起来，而不是直接失败。
        lw_say "${YELLOW}🌊 Could not install the dependencies into the venv; retrying with the parent's packages.${RESET}" \
            "${YELLOW}🌊 依赖没能装进 venv，改用继承父解释器 site-packages 的方式重试。${RESET}"
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
    lw_say "${YELLOW}🌊 Warning: no private environment with the dependencies; using $PYTHON_BIN directly.${RESET}" \
        "${YELLOW}🌊 警告：没有带依赖的私有环境，直接使用 $PYTHON_BIN。${RESET}"
fi

# 最后一道判据：选定解释器必须真的能 import。给不出可用的解释器就不要谎报安装成功。
if ! deps_present "$VENV_PY" && ! deps_present "$PYTHON_BIN"; then
    lw_say_err "${RED_BOLD}🌊 Error: no Python interpreter with requests/packaging/rich is available.${RESET}" \
        "${RED_BOLD}🌊 错误：没有哪个 Python 解释器能 import requests/packaging/rich。${RESET}"
    lw_say_err "${RED_BOLD}🌊 Install them for one interpreter and re-run, or retry when the network is up.${RESET}" \
        "${RED_BOLD}🌊 请给其中一个解释器装上这三个包后重跑，或等网络恢复再试。${RESET}"
    lw_say_err "${RED_BOLD}🌊   python3 -m pip install requests packaging rich${RESET}"
    exit 1
fi

write_launcher "$BASE_DIR" "$PYTHON_BIN"

# ==========================================
# 最后一步：确定安装树的属主
# ==========================================
#
# 共享安装交给 `$SHARED_USER`（组可写，装包不需要 sudo）。
#
# 非共享的系统级安装交给 root:root、权限 755：树在系统 PATH 上，若归安装者
# 所有，任何以该用户身份运行的进程都能替换 links/<名>，而它可能被别的用户、
# 脚本甚至 root 执行 —— 本地提权。代价是装包要 `sudo wave install`，这一点
# 在 pkg/pkginstaller.py 里有对应的前置检查与提示。
#
# 前面所有写操作（下载、落盘、写 launcher）都在这一步之前完成，所以这里改成
# 只读不会卡住本次安装。

if [[ "$NEED_SUDO" == "true" ]]; then
    if [[ "$SHARED_INSTALL" == "true" ]]; then
        lw_privileged chown -R "$SHARED_USER:$SHARED_USER" "$BASE_DIR"
    else
        lw_privileged chown -R root:root "$BASE_DIR"
        lw_privileged chmod -R u+rwX,go+rX,go-w "$BASE_DIR"
        echo ""
        lw_say "🌊 Ownership: $BASE_DIR -> root:root, mode 755" \
            "🌊 属主：$BASE_DIR -> root:root，权限 755"
        lw_say "🌊 Changing packages (install / upgrade / uninstall) needs sudo," \
            "🌊 改动软件包（安装 / 升级 / 卸载）需要 sudo，"
        lw_say "🌊 and sudo has its own PATH, so give the full path:" \
            "🌊 而 sudo 有自己的 PATH，所以要写全路径："
        lw_say "🌊   sudo $BASE_DIR/lib/wave install <package>"
        lw_say "🌊 Everyone else can still run the installed packages." \
            "🌊 其他用户仍可直接运行已安装的软件包。"
    fi
fi

if [[ "$SHARED_INSTALL" == "true" ]]; then
    # useradd -m 建出的家目录默认是 750，其他用户连进入都不行；
    # a+rX 里大写的 X 只给目录和原本可执行的文件加 x，不会误改普通文件。
    lw_say "🌊 Opening $SHARED_HOME and $BASE_DIR to all users..." \
        "🌊 正在把 $SHARED_HOME 与 $BASE_DIR 开放给所有用户……"
    lw_privileged chmod 755 "$SHARED_HOME"
    lw_privileged chmod -R a+rX "$BASE_DIR"

    # Linuxbrew 式共享写：整棵树交给 '$SHARED_USER' 组，调用者入组。
    # 只给读 + 执行是不够的——组员连 downloads/tmp 都建不出来，装包必然失败，
    # 所以这里把组写位打开。代价是组员能改动整棵树，包括 lib/wave 本体
    # （见 .templates/SPECIAL/INSTALL_BY_INTERNET.md 末尾对这一点说明）。
    lw_say "🌊 Setting up the '$SHARED_USER' group for shared installs..." \
        "🌊 正在为共享安装配置 '$SHARED_USER' 组……"
    lw_privileged groupadd -f "$SHARED_USER"

    RELOGIN_NEEDED=false
    # 这两个判断不能混用（实测过 `id` 的两种语义）：
    #   · `id -G <用户名>` 查的是 /etc 数据库 —— 回答「这个人配在组里了吗」，
    #     用来决定要不要跑 usermod；
    #   · `id -G`（不带参数）读的是**当前会话**的进程组 —— 回答「这个 shell 真的
    #     具备该组身份了吗」。刚写进 /etc/group 而还没重登时，前者为真、后者为假，
    #     所以「要不要重新登录」只能用后者，否则会把待重登的用户谎报成已生效。
    SHARED_GID="$(getent group "$SHARED_USER" 2>/dev/null | cut -d: -f3)"
    if [[ "$CURRENT_USER" != "$SHARED_USER" ]] \
        && ! id -G "$CURRENT_USER" 2>/dev/null | tr ' ' '\n' | grep -qx "$SHARED_GID"; then
        # 加组失败不该让整个安装失败：树本身已经装好、也仍然能用，
        # 用户只是暂时还得按提示用 sudo 装包。失败要说清楚，不能吞掉。
        if lw_privileged usermod -aG "$SHARED_USER" "$CURRENT_USER"; then
            RELOGIN_NEEDED=true
        else
            lw_say "${YELLOW}🌊 Could not add '$CURRENT_USER' to '$SHARED_USER' automatically.${RESET}" \
                "${YELLOW}🌊 没能自动把 '$CURRENT_USER' 加进 '$SHARED_USER' 组。${RESET}"
            lw_say "${YELLOW}🌊 Add it by hand: sudo usermod -aG $SHARED_USER $CURRENT_USER${RESET}" \
                "${YELLOW}🌊 请手工执行：sudo usermod -aG $SHARED_USER $CURRENT_USER${RESET}"
        fi
    fi

    lw_privileged chgrp -R "$SHARED_USER" "$BASE_DIR"
    lw_privileged chmod -R g+w "$BASE_DIR"
    # setgid 必须加在目录上：否则组员新建的文件会落回他自己的主组，
    # 下一个组员就写不进去了。
    lw_privileged find "$BASE_DIR" -type d -exec chmod g+s {} +

    # 会话里还没有这个组的身份 -> 也要提示（加过组但一直没重登就是这种）。
    # 权限位本身是立即生效的，只有「你个人的组身份」要等新登录会话。
    # 这里刻意用不带参数的 `id -G`：具名那种是查 /etc 数据库，会把「已写进库、
    # 但当前 shell 还没这个组」误判成已生效。
    if ! id -G 2>/dev/null | tr ' ' '\n' | grep -qx "$SHARED_GID"; then
        RELOGIN_NEEDED=true
    fi
fi

# ==========================================
# 添加到 PATH
# ==========================================

if [[ "$SHELL" == *"zsh"* ]]; then
    RC_FILE="$HOME/.zshrc"
elif [[ "$SHELL" == *"bash"* ]]; then
    RC_FILE="$HOME/.bashrc"
else
    RC_FILE="$HOME/.profile"
fi

# 旧版本直接往 rc 里 append 一整行 PATH；新版只写一行 eval，归用户自己管：
# 升级换目录、卸载，都不必再去猜用户文件里哪一行是自己写的。
PATH_LINE="export PATH=\"$INSTALL_DIR:$LINKS_DIR:$LIB_DIR:\$PATH\""
SHELLENV_LINE="eval \"\$(\"$LIB_DIR/wave\" shellenv)\""
LEGACY_PREFIX="export PATH=\"$INSTALL_DIR"

# 从 rc 文件里摘掉我们写入的行（各自的写法 + 标记行）。
# 安装回滚时要靠它，否则会留下一个指向已删除目录的 PATH。
remove_lw_path_entries() {
    local rc="$1"
    [[ -f "$rc" ]] || return 0
    grep -qF -e "$PATH_LINE" -e "$SHELLENV_LINE" -e "# LinuxWave" "$rc" 2>/dev/null || return 0
    grep -v -F -e "$PATH_LINE" -e "$SHELLENV_LINE" -e "# LinuxWave" "$rc" > "$rc.linuxwave.tmp" || true
    cat "$rc.linuxwave.tmp" > "$rc"
    rm -f "$rc.linuxwave.tmp"
    lw_say "🌊 Removed LinuxWave PATH entries from $rc" \
        "🌊 已从 $rc 移除 LinuxWave 的 PATH 条目"
}

# 旧版本那行 PATH 不再需要：告诉用户怎么删、以及为什么该删。
# 刻意不替用户删 —— 那是他的文件，猜错就是删掉别人的行。
report_legacy_path_line() {
    local rc="$1"
    grep -qF "$LEGACY_PREFIX" "$rc" 2>/dev/null || return 0
    lw_say "${YELLOW}🌊 Note: an older version of LinuxWave wrote this line into $rc:${RESET}" \
        "${YELLOW}🌊 注意：旧版 LinuxWave 往 $rc 里写过这一行：${RESET}"
    lw_say "     $PATH_LINE" "     $PATH_LINE"
    lw_say "${YELLOW}🌊 It is no longer needed — this install writes a single line instead.${RESET}" \
        "${YELLOW}🌊 它已经不需要了 —— 本次安装改成只写一行。${RESET}"
    lw_say "🌊 Two lines would set PATH from two places, and after an upgrade the old one still${RESET}" \
        "🌊 两行会让 PATH 有两个来源；升级之后旧那行还指着上一个安装目录。${RESET}"
    lw_say "🌊 points at the previous install directory. Removing it is safe; run:${RESET}" \
        "🌊 删掉是安全的，运行这一条即可：${RESET}"
    lw_say "     sed -i.linuxwave.bak '/^export PATH=\".*linuxwave/d' $rc"
    lw_say "🌊 (The backup is $rc.linuxwave.bak, in case you want the line back.)" \
        "🌊 （备份是 $rc.linuxwave.bak，想要回那行时用得着。）"
}

if [[ "$SHARED_INSTALL" == "true" ]]; then
    # 共享安装：$SHARED_USER 自己的 shell 也要能直接用 wave
    SHARED_RC="$SHARED_HOME/.bashrc"
    if sudo grep -qF "$SHELLENV_LINE" "$SHARED_RC" 2>/dev/null; then
        lw_say "🌊 LinuxWave is already in $SHARED_RC." "🌊 $SHARED_RC 里已经有 LinuxWave 了。"
    elif sudo test -f "$SHARED_RC"; then
        lw_say "🌊 Adding LinuxWave to PATH in $SHARED_RC..." \
            "🌊 正在把 LinuxWave 写进 $SHARED_RC 的 PATH……"
        printf '\n# LinuxWave\n%s\n' "$SHELLENV_LINE" | lw_privileged tee -a "$SHARED_RC" > /dev/null
        lw_privileged chown "$SHARED_USER:$SHARED_USER" "$SHARED_RC"
    elif printf '# LinuxWave\n%s\n' "$SHELLENV_LINE" | lw_privileged tee "$SHARED_RC" > /dev/null; then
        # 账号预存、或 /etc/skel 里没有 .bashrc 时文件不存在。
        # 建出来，否则这个账号反而跑不了 wave，而安装却自称已完成。
        lw_say "🌊 Created $SHARED_RC with LinuxWave in PATH." \
            "🌊 已创建 $SHARED_RC，并在其中写好 LinuxWave 的 PATH。"
        lw_privileged chmod 644 "$SHARED_RC"
        lw_privileged chown "$SHARED_USER:$SHARED_USER" "$SHARED_RC"
    else
        lw_say "${YELLOW}🌊 Warning: could not write $SHARED_RC.${RESET}" \
            "${YELLOW}🌊 警告：没能写入 $SHARED_RC。${RESET}"
        lw_say "🌊 '$SHARED_USER' can add it manually with:" \
            "🌊 '$SHARED_USER' 可以手工加上这一行："
        lw_say "     echo '$SHELLENV_LINE' >> ~/.bashrc"
    fi
fi

if grep -qF "$SHELLENV_LINE" "$RC_FILE" 2>/dev/null; then
    lw_say "🌊 LinuxWave is already in your PATH." "🌊 你的 PATH 里已经有 LinuxWave 了。"
else
    lw_say "🌊 Adding LinuxWave to PATH in $RC_FILE..." \
        "🌊 正在把 LinuxWave 写进 $RC_FILE 的 PATH……"
    echo "" >> "$RC_FILE"
    echo "# LinuxWave" >> "$RC_FILE"
    echo "$SHELLENV_LINE" >> "$RC_FILE"
fi
report_legacy_path_line "$RC_FILE"

# ==========================================
# 同意记录
# ==========================================
# 协议标识的唯一来源是装好的 lib/selfupdate.py（AGREEMENT_ID），这里不再抄一份日期：
# 抄两份必然漂移，而漂移的后果是「以为用户同意过新版协议」。

agreement_id() {
    local source="$LIB_DIR/selfupdate.py"
    [[ -f "$source" ]] || return 1
    sed -n 's/^AGREEMENT_ID = "\([^"]*\)"$/\1/p' "$source" | head -n 1
}

record_agreement() {
    local id
    id="$(agreement_id || true)"
    if [[ -z "$id" ]]; then
        lw_say "${YELLOW}🌊 Note: cannot read AGREEMENT_ID from ${LIB_DIR}/selfupdate.py; the acceptance was not recorded.${RESET}" \
            "${YELLOW}🌊 注意：读不到 ${LIB_DIR}/selfupdate.py 里的 AGREEMENT_ID，本次同意未被记录。${RESET}"
        return 0
    fi
    if [[ "$CLI_DRY_RUN" == "true" ]]; then
        lw_say "${YELLOW}🌊 Dry run: would record the agreement (\"$id\") in $AGREEMENT_FILE.${RESET}" \
            "${YELLOW}🌊 试运行：本该把同意（\"$id\"）记进 $AGREEMENT_FILE。${RESET}"
        return 0
    fi
    lw_write_state "$AGREEMENT_FILE" || return 0
    if ! printf '{\n  "agreement": "%s"\n}\n' "$id" | run_cmd tee "$AGREEMENT_FILE" > /dev/null 2>&1; then
        lw_say "${YELLOW}🌊 Note: could not record the agreement in $AGREEMENT_FILE.${RESET}" \
            "${YELLOW}🌊 注意：未能把同意写进 $AGREEMENT_FILE。${RESET}"
        return 0
    fi
    run_cmd chmod 644 "$AGREEMENT_FILE" > /dev/null 2>&1 || true
    return 0
}

# ==========================================
# 许可协议确认
# ==========================================
# 必须放在「安装完成」之前：否则先告诉用户已经装好，随后又因为不同意而全部删除。

echo ""
lw_say "${YELLOW}Please read the agreement before use (see bottom of https://linuxwave.org).${RESET}" \
    "${YELLOW}使用前请先阅读用户协议（见 https://linuxwave.org 页面底部）。${RESET}"
if [[ "$CLI_CI" == "true" ]]; then
    lw_say "🌊 --ci: the agreement is accepted automatically." "🌊 --ci：自动接受用户协议。"
    agreement="yes"
else
    # 应答归一化：去空白、转小写后再判断。空 / y / yes → 同意，n / no → 拒绝，
    # 其它输入重新提问，连续 3 次无法识别就按拒绝处理 —— 不能把「没听懂」
    # 当成「同意」，也不能无限问下去。
    agreement=""
    _agreement_tries=0
    while [[ -z "$agreement" ]]; do
        _agreement_tries=$((_agreement_tries + 1))
        lw_say "${YELLOW}Have you read and agreed to the agreement? [Y/n]${RESET}" \
            "${YELLOW}你是否已阅读并同意该协议？[Y/n]${RESET}"
        _answer=""
        # 读失败 = /dev/tty 没给东西（EOF / 被关掉），**不是**「直接回车」。
        # 直接回车表示同意（默认 Y），但 EOF 表示「没人回答」——把它当同意等于
        # 替用户签了协议。这里明确终止，并说清什么都没装。
        if ! read -r _answer < /dev/tty; then
            lw_say_err "${RED_BOLD}🌊 Error: no answer was given (end of input). Nothing was installed.${RESET}" \
                "${RED_BOLD}🌊 错误：没有收到回答（输入已结束）。什么都没装。${RESET}"
            lw_say_err "🌊 Re-run the installer and answer the prompt." \
                "🌊 请重新运行安装器，并在提示处作答。"
            exit 1
        fi
        _answer="${_answer//[[:space:]]/}"
        _answer="${_answer,,}"
        case "$_answer" in
            ""|y|yes)
                agreement="yes"
                ;;
            n|no)
                agreement="no"
                ;;
            *)
                if [[ "$_agreement_tries" -ge 3 ]]; then
                    lw_say_err "${YELLOW}Unrecognized answer, treating it as \"no\".${RESET}" \
                        "${YELLOW}无法识别的回答，按「不同意」处理。${RESET}"
                    agreement="no"
                else
                    lw_say_err "${YELLOW}Please answer y (agree) or n (do not agree).${RESET}" \
                        "${YELLOW}请回答 y（同意）或 n（不同意）。${RESET}"
                fi
                ;;
        esac
    done
fi
if [[ "$agreement" == "yes" ]]; then
    # CI 的自动同意也要记下来：否则装完再跑 `wave selfupdate` 会卡在协议询问上。
    record_agreement
    lw_say "${GREEN}You have agreed to the agreement.${RESET}" "${GREEN}已记录你的同意。${RESET}"
else
    lw_say "${RED_BOLD}You do not agree to the agreement. Installation stopped.${RESET}" \
        "${RED_BOLD}你未同意该协议，安装已停止。${RESET}"
    if [[ "$TREE_PREEXISTED" == "0" ]]; then
        # 回滚要连 rc 里的 PATH 一起清掉，否则会留下指向已删除目录的一行。
        # 这里不写死 sudo：用户级安装全程无需提权，回滚也不该突然要密码。
        lw_say "${RED_BOLD}🌊 Cleaning up downloaded files...${RESET}" "${RED_BOLD}🌊 正在清理已下载的文件……${RESET}"
        run_cmd rm -rf "$BASE_DIR"
        run_cmd rm -rf "$CONFIG_DIR"
        remove_lw_path_entries "$RC_FILE"
        if [[ "$SHARED_INSTALL" == "true" ]] && sudo test -f "$SHARED_HOME/.bashrc"; then
            lw_privileged python3 - "$SHARED_HOME/.bashrc" "$PATH_LINE" << 'PYEOF'
import sys
from pathlib import Path

rc_file = Path(sys.argv[1])
path_line = sys.argv[2]
kept = [line for line in rc_file.read_text().splitlines()
        if line.strip() != "# LinuxWave" and line != path_line]
rc_file.write_text("\n".join(kept) + ("\n" if kept else ""))
PYEOF
            lw_say "🌊 Removed LinuxWave PATH entries from $SHARED_HOME/.bashrc" \
                "🌊 已从 $SHARED_HOME/.bashrc 移除 LinuxWave 的 PATH 条目"
        fi
        lw_say "${RED_BOLD}🌊 All files have been deleted.${RESET}" "${RED_BOLD}🌊 所有文件已删除。${RESET}"
    else
        # 升级覆盖时这棵树本来就是用户的，不能替人删。
        lw_say "${YELLOW}🌊 Existing installation left untouched; run the installer again to continue.${RESET}" \
            "${YELLOW}🌊 已有安装保持原样，重新运行安装器可继续。${RESET}"
    fi
    exit 1
fi

# ==========================================
# 完成信息
# ==========================================

echo ""
lw_say "🌊 Installation complete!" "🌊 安装完成！"
lw_say "🌊 LinuxWave installed to: $DISPLAY_DIR" "🌊 LinuxWave 已安装到：$DISPLAY_DIR"
lw_say "🌊 Architecture: $ARCH" "🌊 架构：$ARCH"
echo ""

if [[ "$SHARED_INSTALL" == "true" ]]; then
    lw_say "🌊 Shared install ready." "🌊 共享安装已就绪。"
    lw_say "🌊 Config   : $CONFIG_DIR  (system-level, every user resolves it)" \
        "🌊 配置目录：$CONFIG_DIR（系统级，所有用户都解析到它）"
    lw_say "🌊 Owner    : $SHARED_USER:$SHARED_USER  (shared write via the '$SHARED_USER' group)" \
        "🌊 属主    ：$SHARED_USER:$SHARED_USER（通过 '$SHARED_USER' 组共享写）"
    lw_say "🌊 Other users can enable 'wave' with:" "🌊 其他用户这样启用 'wave'："
    lw_say "${YELLOW}    echo 'export PATH=\"$INSTALL_DIR:$LINKS_DIR:$LIB_DIR:\$PATH\"' >> ~/.bashrc${RESET}"
    if [[ "$RELOGIN_NEEDED" == "true" ]]; then
        lw_say "${YELLOW}🌊 '$CURRENT_USER' is now in the '$SHARED_USER' group, but this shell does${RESET}" \
            "${YELLOW}🌊 '$CURRENT_USER' 已在 '$SHARED_USER' 组里，但当前这个 shell 还没有该身份：${RESET}"
        lw_say "${YELLOW}🌊 not have it yet: log out and back in (or run 'newgrp $SHARED_USER') before${RESET}" \
            "${YELLOW}🌊 装包之前请注销重登（或运行 'newgrp $SHARED_USER'）。${RESET}"
        lw_say "${YELLOW}🌊 installing packages. A group only takes effect in a new login session -${RESET}" \
            "${YELLOW}🌊 组身份只在下一次登录会话里生效 —— 在那之前安装树对你仍不可写，${RESET}"
        lw_say "${YELLOW}🌊 until then the tree is still unwritable, and 'wave' will say so.${RESET}" \
            "${YELLOW}🌊 'wave' 会如实告诉你这一点。${RESET}"
        lw_say "${YELLOW}🌊 If it is still unwritable after a re-login, the user manager started at${RESET}" \
            "${YELLOW}🌊 如果重登之后仍不可写，说明第一次登录时启动的 user manager 还握着旧凭据：${RESET}"
        lw_say "${YELLOW}🌊 your first login is holding the old credentials: run${RESET}" \
            "${YELLOW}🌊 请运行${RESET}"
        lw_say "${YELLOW}     systemctl --user exit${RESET}"
        lw_say "${YELLOW}🌊 then log in again (a reboot does the same).${RESET}" \
            "${YELLOW}🌊 然后再登录一次（重启等效）。${RESET}"
        lw_say "🌊 To install packages right now instead of re-logging in:" \
            "🌊 不想重登、现在就装包的话："
        lw_say "       newgrp $SHARED_USER           # new subshell with the group; 'exit' leaves it" \
            "       newgrp $SHARED_USER           # 进入带该组的子 shell，exit 退出"
        lw_say "       sg $SHARED_USER -c 'wave install <package>'    # one-off" \
            "       sg $SHARED_USER -c 'wave install <包名>'    # 只跑一次"
        lw_say "🌊 Run 'id -G' in that shell first: some newgrp implementations drop your other" \
            "🌊 进去之后先跑 'id -G'：某些 newgrp 实现会把你其他的组权限一并重置"
        lw_say "🌊 supplementary groups (docker, sudo, …) for that shell." \
            "🌊 （docker、sudo 之类），那一层 shell 里就没有它们了。"
    else
        lw_say "🌊 '$CURRENT_USER' already has the '$SHARED_USER' group; nothing to re-login for." \
            "🌊 '$CURRENT_USER' 已在 '$SHARED_USER' 组里，不需要为了它重新登录。"
    fi
    lw_say "🌊 Installs go through that group, so they need no sudo and no full path:" \
        "🌊 装包通过该组完成，所以既不需要 sudo，也不需要写全路径："
    lw_say "     wave install <package>"
    lw_say "🌊 To let more users install:" "🌊 想让更多用户也能装包："
    lw_say "     sudo usermod -aG $SHARED_USER <user>   (they re-login as well)" \
        "     sudo usermod -aG $SHARED_USER <用户名>（同样要重新登录）"
    lw_say "🌊 'wave selfupdate' still needs sudo: it rewrites $CONFIG_DIR, which is root-owned." \
        "🌊 'wave selfupdate' 仍然需要 sudo：它要重写 $CONFIG_DIR，那里属 root。"
    echo ""
fi
RC_DISPLAY=$(home_to_tilde_arg "$RC_FILE")   # 这一行会被用户直接复制执行，见函数注释
lw_say "🌊 To use 'wave' immediately in this terminal, run:" \
    "🌊 想在当前终端立刻用上 'wave'，请运行："
lw_say "${YELLOW}    source $RC_DISPLAY${RESET}"
lw_say "🌊 Or simply open a new terminal window." "🌊 或者直接开一个新终端窗口。"
echo ""