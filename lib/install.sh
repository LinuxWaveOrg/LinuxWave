#!/bin/bash

# LinuxWave 🌊 Official Installer
# This script downloads wave.py, installs dependencies, and configures PATH.
# Usage: /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/LinuxWaveOrg/LinuxWave/HEAD/lib/install.sh)"

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

# -E（errtrace）让下面那个 ERR 陷阱能看见 run_cmd 等**函数内部**的失败：
# 默认情况下陷阱不继承进函数，中途失败就只剩一个光秃秃的 curl 退出码。
# 显式 `return 1`、调用方用 `||` 容忍的失败、`if` 条件里的失败都不会误触发。
set -eE

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

mw_sudo() {
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

# 数据仓库：版本号、代码分支与文件清单都从这里读
CONFIGDATA_URL="$SELFUPDATE_URL"   # 版本数据与自更新数据同源，见下方域名块

# ==========================================
# 颜色定义
# ==========================================

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'

# ==========================================
# 版本号与代码分支（从 configdata 读取，不写死在脚本里）
# ==========================================
#
# latest_version 里的 version 是这次要安装的版本，branch 是配套的代码分支：
# 两者一起读，保证「下载的代码」和「写进 VERSION.json 的版本号」对应同一个版本。

LATEST_VERSION_DATA="$(curl -fsSL --max-time 30 "$CONFIGDATA_URL/versiondata/latest_version" 2>/dev/null)"

LINUXWAVE_VERSION="$(printf '%s\n' "$LATEST_VERSION_DATA" | sed -n 's/^version:[[:space:]]*"\(.*\)"/\1/p' | head -n 1)"
LATEST_BRANCH="$(printf '%s\n' "$LATEST_VERSION_DATA" | sed -n 's/^branch:[[:space:]]*"\(.*\)"/\1/p' | head -n 1)"

if [[ -z "$LINUXWAVE_VERSION" || -z "$LATEST_BRANCH" ]]; then
    echo -e "${RED_BOLD}🌊 Error: Cannot read the latest version from configdata.${RESET}" >&2
    echo -e "${RED_BOLD}🌊 Check your network or proxy, then run the installer again.${RESET}" >&2
    exit 1
fi

BRANCH="$LATEST_BRANCH"
BASE_URL="$CORE_URL/$BRANCH"

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

# ==========================================
# 辅助函数：校验自定义目录，防止路径穿越
# ==========================================

validate_custom_dir() {
    local dir="$1"

    if [[ -z "$dir" ]]; then
        echo -e "${RED_BOLD}🌊 Error: Empty path is not allowed.${RESET}" >&2
        return 1
    fi

    if [[ "$dir" == *".."* ]]; then
        echo -e "${RED_BOLD}🌊 Error: Path traversal ('..') is not allowed.${RESET}" >&2
        return 1
    fi

    if [[ "$dir" == *$'\n'* ]] || [[ "$dir" == *$'\r'* ]] || [[ "$dir" == *$'\t'* ]]; then
        echo -e "${RED_BOLD}🌊 Error: Invalid control characters in path.${RESET}" >&2
        return 1
    fi

    if LC_ALL=C grep -q '[^a-zA-Z0-9/_.~ -]' <<< "$dir"; then
        echo -e "${RED_BOLD}🌊 Error: Path contains non-ASCII or invalid characters.${RESET}" >&2
        echo -e "${RED_BOLD}🌊 Only ASCII letters, digits, '/', '-', '_', '.', '~', and spaces are allowed.${RESET}" >&2
        return 1
    fi

    local expanded="${dir/#\~/$HOME}"

    if [[ "$expanded" != /* ]]; then
        echo -e "${RED_BOLD}🌊 Error: Please use an absolute path (starting with / or ~).${RESET}" >&2
        return 1
    fi

    if [[ "$expanded" == *"//"* ]]; then
        echo -e "${RED_BOLD}🌊 Error: Path contains consecutive slashes.${RESET}" >&2
        return 1
    fi

    if [[ "$expanded" == "/" ]]; then
        echo -e "${RED_BOLD}🌊 Error: Cannot install to root directory.${RESET}" >&2
        return 1
    fi

    echo "$expanded"
    return 0
}

# ==========================================
# 共享安装：前置准备清单
# ==========================================

print_shared_install_notes() {
    echo ""
    echo -e "${YELLOW}🌊 Shared install (Linuxbrew style)${RESET}"
    echo "🌊 Install directory : $SHARED_BASE_DIR"
    echo "🌊 Config directory  : $SHARED_CONFIG_DIR  (system-level, shared by every user)"
    echo "🌊 Owner             : $SHARED_USER"
    echo ""
    echo -e "${YELLOW}🌊 Make sure these are ready before continuing:${RESET}"
    echo "   1. sudo - needed once, to create $SHARED_HOME and write $SHARED_CONFIG_DIR"
    echo "   2. patchelf - dependency libraries cannot be relocated without it:"
    echo "        Debian/Ubuntu : sudo apt install patchelf"
    echo "        Fedora/RHEL   : sudo dnf install patchelf"
    echo "        Arch          : sudo pacman -S patchelf"
    echo "   3. Python 3.14 or above - required by LinuxWave and by .conda packages"
    echo ""
    echo -e "${YELLOW}🌊 4. One thing you must do afterwards: log out and back in.${RESET}"
    echo -e "${YELLOW}🌊    Packages are installed through the '$SHARED_USER' group, and '$CURRENT_USER'${RESET}"
    echo -e "${YELLOW}🌊    is added to it by this install - but a group only takes effect in a new${RESET}"
    echo -e "${YELLOW}🌊    login session. Until you re-login the tree is still unwritable and 'wave'${RESET}"
    echo -e "${YELLOW}🌊    will say so. Nothing is broken; just log out and back in (or run${RESET}"
    echo -e "${YELLOW}🌊    'newgrp $SHARED_USER' in this shell).${RESET}"
    echo ""
    echo "🌊 The '$SHARED_USER' account is created automatically if missing."
    echo "🌊 Every user on this machine will be able to run 'wave'."
    echo "🌊 Installs are shared through that group, so they need neither sudo nor a full"
    echo "🌊 path:"
    echo "     wave install <package>"
    echo "🌊 More users: sudo usermod -aG $SHARED_USER <user>   (they re-login as well)"
    echo ""
}

# ==========================================
# 命令行参数（批量 / 脚本化安装）
# ==========================================

CLI_SILENT=false
CLI_DIR_OPTION=""
CLI_CUSTOM_DIR=""

usage() {
    cat <<'USAGE_EOF'
LinuxWave installer

Usage:
  install.sh [options]

Options:
  --install-python-from-source
                         Fetch the bundled Python from its upstream URL instead of
                         our own store (same meaning as on `wave selfupdate`)
  -S, --silent            No interaction at all: the directory menu and the
                          agreement are answered automatically. Without
                          --dir-option the default (option 1) is used.
                          Requires passwordless sudo when privilege is needed.
      --dir-option=N      Pick menu entry N without prompting (1-5).
      --dir-option=DIR    Use DIR as the installation directory (shorthand for
                          --dir-option=5=DIR).
      --dir-option=N=DIR  Pick entry N and, for the custom entry (5), use DIR
                          as the installation directory.
  -h, --help              Show this help.

Directory menu:
  1. ~/.local/linuxwave
  2. /opt/linuxwave
  3. /usr/local/linuxwave
  4. /home/linuxwave/.linuxwave (shared, all users)
  5. other (enter custom directory)

Examples:
  install.sh --silent --dir-option=4
  install.sh -S --dir-option=1
  install.sh --silent --dir-option=5=/opt/mylw
  install.sh --silent --dir-option=/opt/mylw
USAGE_EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -S|--silent)
            CLI_SILENT=true
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
            usage
            exit 0
            ;;
        *)
            echo -e "${RED_BOLD}🌊 Error: unknown option '$1'. Try --help.${RESET}" >&2
            exit 1
            ;;
    esac
    shift
done

# 用 `/bin/bash -c "$(curl ...)"` 运行时，第一个参数会变成脚本名（$0）：
#   /bin/bash -c "$(curl ...)" --silent    ← --silent 成了 $0，被静默丢掉
# 正确写法是加 `--`：它结束 bash 自身的选项，后面的参数才会传进脚本。
# 这里明确提示，避免「静默模式没生效、脚本却卡在交互上」。
case "$0" in
    --) ;;              # 正确写法：`--` 之后的参数才轮到脚本
    -*)
        echo -e "${YELLOW}🌊 Warning: '$0' was treated as the script name, not as an option.${RESET}" >&2
        echo -e "${YELLOW}🌊 Put installer options after '--', which ends bash's own options.${RESET}" >&2
        echo "🌊   /bin/bash -c \"\$(curl -fsSL <url>)\" -- $0" >&2
        ;;
esac

# --dir-option=<路径> 是 --dir-option=5=<路径> 的简写：值不是纯数字时，
# 直接把该值当作自定义安装目录（纯数字仍走下面的 1-5 校验，超范围会报错）。
if [[ -n "$CLI_DIR_OPTION" && ! "$CLI_DIR_OPTION" =~ ^[0-9]+$ ]]; then
    CLI_CUSTOM_DIR="$CLI_DIR_OPTION"
    CLI_DIR_OPTION="5"
fi

if [[ -n "$CLI_DIR_OPTION" && ! "$CLI_DIR_OPTION" =~ ^[1-5]$ ]]; then
    echo -e "${RED_BOLD}🌊 Error: --dir-option must be 1-5, got '$CLI_DIR_OPTION'.${RESET}" >&2
    exit 1
fi

if [[ "$CLI_DIR_OPTION" == "5" && -z "$CLI_CUSTOM_DIR" && "$CLI_SILENT" == "true" ]]; then
    echo -e "${RED_BOLD}🌊 Error: --dir-option=5 needs a directory in --silent mode.${RESET}" >&2
    echo -e "${RED_BOLD}🌊 Use --dir-option=5=/some/dir${RESET}" >&2
    exit 1
fi

# ==========================================
# 显示欢迎信息
# ==========================================

echo "🌊 Welcome to LinuxWave $LINUXWAVE_VERSION!"

# 用了镜像就明说一句。装完遇到问题，第一件事是确认自己连的到底是谁 —— 而镜像地址里
# 可能带凭据，所以过一遍 mw_redact。
if [[ "$CORE_URL" != "$CORE_DEFAULT_URL" ]]; then
    echo "🌊 Core files come from a mirror: $(mw_redact "$CORE_URL")"
fi

echo ""

# ==========================================
# 检测系统架构
# ==========================================

ARCH=$(uname -m)
echo "🌊 Detected architecture: $ARCH"

# ==========================================
# 共享安装（x86_64 选项 4 / arm64 选项 3）相关常量
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
    echo -e "${YELLOW}Where do you want to install LinuxWave? (Enter the number)${RESET}"
    echo "1. ~/.local/linuxwave"
    echo "2. /opt/linuxwave"
    echo "3. /usr/local/linuxwave"
    echo "4. $SHARED_BASE_DIR (shared, all users)"
    echo "5. other (enter custom directory)"
    echo ""
    echo -e "${YELLOW}Enter your choice:${RESET}"
}

# 目录菜单对 x86_64 与 arm64 完全一致。
# MacWave 曾把 /usr/local 限制为 Intel Mac（Apple 芯片上不建议写入 /usr/local），
# Linux 没有这个限制，因此这里不做区分。
if [[ -n "$CLI_DIR_OPTION" ]]; then
    choice="$CLI_DIR_OPTION"
    echo "🌊 Directory option: $choice (from --dir-option)"
elif [[ "$CLI_SILENT" == "true" ]]; then
    # --silent 承诺「自动应答目录菜单」，那就明确地选默认项并说出来，
    # 而不是去读一个可能不存在的终端、再靠「无效输入」兜底。
    choice="1"
    echo "🌊 --silent without --dir-option: using the default, \$HOME/.local/linuxwave"
else
    MENU_ATTEMPTS=3
    menu_try=0
    while true; do
        print_dir_menu
        # `2>/dev/null` 写在输入重定向之前：没有控制终端时打开 /dev/tty 会失败，
        # 重定向按从左到右处理，先屏蔽 stderr 才不会喷出原始报错。
        read -r 2>/dev/null choice < /dev/tty || choice=""
        case "$choice" in
            1|2|3|4|5)
                break
                ;;
            *)
                menu_try=$((menu_try + 1))
                echo ""
                echo -e "${RED_BOLD}🌊 Error: '$choice' is not one of 1-5.${RESET}" >&2
                # 绝不静默换到别的目录：那等于把东西装到用户没选的位置。
                if [[ "$menu_try" -ge "$MENU_ATTEMPTS" ]]; then
                    echo -e "${RED_BOLD}🌊 Gave up after $MENU_ATTEMPTS attempts. Nothing was installed.${RESET}" >&2
                    echo "🌊 Re-run the installer, or pass --dir-option=N (see --help)." >&2
                    exit 1
                fi
                echo -e "${YELLOW}🌊 Please enter a number from 1 to 5.${RESET}" >&2
                echo ""
                ;;
        esac
    done
fi

case "$choice" in
    1)
        BASE_DIR="$HOME/.local/linuxwave"
        ;;
    2)
        BASE_DIR="$SYS_ROOT/opt/linuxwave"
        ;;
    3)
        BASE_DIR="$SYS_ROOT/usr/local/linuxwave"
        ;;
    4)
        SHARED_INSTALL=true
        BASE_DIR="$SHARED_BASE_DIR"
        ;;
    5)
        if [[ -n "$CLI_CUSTOM_DIR" ]]; then
            custom_dir="$CLI_CUSTOM_DIR"
            echo "🌊 Installation directory: $custom_dir (from --dir-option)"
        else
            echo -e "${YELLOW}Please enter the installation directory:${RESET}"
            read -r custom_dir < /dev/tty
        fi
        validated=$(validate_custom_dir "$custom_dir") || exit 1
        BASE_DIR="$validated"
        ;;
    *)
        # 上面已把选择校验到 1-5，这里只是兜底；
        # 无论如何都不静默换成别的目录。
        echo -e "${RED_BOLD}🌊 Error: unsupported directory choice '$choice'. Nothing was installed.${RESET}" >&2
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

run_cmd() {
    if [[ "$NEED_SUDO" == "true" ]]; then
        mw_sudo "$@"
    else
        "$@"
    fi
}

if [[ "$NEED_SUDO" == "true" ]]; then
    if [[ "$CLI_SILENT" == "true" ]]; then
        # --silent 不能停下来等密码：要么已经是 root，要么已有免密 sudo
        if ! sudo -n true 2> /dev/null; then
            echo -e "${RED_BOLD}🌊 Error: this install needs privilege, but --silent cannot ask for a password.${RESET}" >&2
            echo -e "${RED_BOLD}🌊 Run as root, or configure passwordless sudo for the install user.${RESET}" >&2
            exit 1
        fi
    else
        echo -e "${YELLOW}🌊 Granting temporary administrator access for installation...${RESET}"
        sudo -v
    fi
fi

if [[ "$SHARED_INSTALL" == "true" ]]; then
    if id "$SHARED_USER" >/dev/null 2>&1; then
        echo "🌊 User '$SHARED_USER' already exists."
    else
        echo "🌊 Creating user '$SHARED_USER'..."
        sudo useradd -m -d "$SHARED_HOME" -s /bin/bash "$SHARED_USER"
    fi

    sudo mkdir -p "$BASE_DIR"
    sudo chown "$SHARED_USER:$SHARED_USER" "$SHARED_HOME" "$BASE_DIR"
fi

# ==========================================
# 文件清单（configdata/versiondata/files_info）
# ==========================================
#
# 要下载哪些文件不写死在本脚本里，而是去 configdata 分支读一份清单，
# 这样新增文件只要改那份清单，不必再同步修改安装脚本与自更新脚本。
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
#
# 这一步刻意放在「建目录 / 写配置 / 清旧版」之前：连不上 configdata 就直接退出，
# 不会留下一个配置已写好、文件却一个都没下的半成品安装。

FILES_INFO_URL="$CONFIGDATA_URL/versiondata/files_info"
FILES_INFO_TMP="$(mktemp)"
FILES_INFO_ATTEMPTS=3

# 每个文件的重试次数。实测网络（尤其是 raw.githubusercontent）经常
# 在传输中途被重置，而这里只要有一个文件失败，整轮安装就前功尽弃——
# 不加这一层，用户就得手工重跑很多遍。
DOWNLOAD_ATTEMPTS=5

cleanup_files_info() {
    rm -f "$FILES_INFO_TMP"
}
trap cleanup_files_info EXIT

echo "🌊 Fetching the file list..."

FILES_INFO_OK=false
for attempt in $(seq 1 "$FILES_INFO_ATTEMPTS"); do
    if curl -fsSL --max-time 60 -o "$FILES_INFO_TMP" "$FILES_INFO_URL"; then
        FILES_INFO_OK=true
        break
    fi
    if [[ "$attempt" -lt "$FILES_INFO_ATTEMPTS" ]]; then
        echo -e "${YELLOW}🌊 Retrying the file list ($((attempt + 1))/$FILES_INFO_ATTEMPTS)...${RESET}"
    fi
done

if [[ "$FILES_INFO_OK" != "true" ]]; then
    echo -e "${RED_BOLD}🌊 Error: Cannot fetch versiondata/files_info from the configdata branch.${RESET}"
    echo -e "${RED_BOLD}🌊 Nothing was installed. Check your network or proxy, then run the installer again.${RESET}"
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

# 中途失败时给出明确指引。刻意**不自动删除**已下载的内容：升级安装时
# 删掉安装树会把用户原有的可用安装一起毁掉，重跑安装器才是安全的做法。
MW_OPTIONAL_RESULT=""

mw_try() {
    # mw_try <命令...>：跑一个「失败也无所谓」的命令，stdout 存进 MW_OPTIONAL_RESULT。
    # 失败时不惊动 ERR 陷阱 —— 否则用户会先看到「Installation did not finish」，
    # 几百行之后再看到「Installation complete!」，比不提示更糟。
    #
    # 旗标必须在**命令替换的整个生命周期内**保持设置：`set -E` 让 ERR 陷阱传进
    # 子 shell，而子 shell 退出时如果那条命令返回非零，陷阱照样会响。
    local output
    MW_FAILURE_HANDLED=1
    output="$("$@")" && MW_OPTIONAL_RESULT="$output" || MW_OPTIONAL_RESULT=""
    unset MW_FAILURE_HANDLED
    return 0
}

install_failed() {
    local code=$?

    # 有些失败是**预期之内**的：自带解释器取不到时会回落到系统 python3，安装照常完成。
    # 那些地方用 mw_try 包着，会临时立这个旗标，于是这里不报「安装未完成」。
    if [[ -n "${MW_FAILURE_HANDLED:-}" ]]; then
        return 0
    fi
    echo "" >&2
    echo -e "${RED_BOLD}🌊 Installation did not finish (exit $code).${RESET}" >&2
    echo "🌊 Nothing was removed. Files already downloaded may be left in:" >&2
    echo "     ${BASE_DIR:-<not chosen yet>}" >&2
    echo "     ${CONFIG_DIR:-<not chosen yet>}" >&2
    echo "🌊 Fix the cause (network, permissions, disk space) and run the installer again;" >&2
    echo "🌊 a repeated install overwrites what it downloaded and is safe to rerun." >&2
}
trap install_failed ERR

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
    echo -e "${YELLOW}🌊 Directory structure changed in $LINUXWAVE_VERSION, running migration...${RESET}"

    TRANSFER_COMMANDS="$(curl -fsSL --max-time 60 "$UPDATEDATA_URL/transfer_commands" 2>/dev/null)" || TRANSFER_COMMANDS=""
    if [[ -z "$TRANSFER_COMMANDS" ]]; then
        echo -e "${RED_BOLD}🌊 Error: Cannot fetch the migration script for $LINUXWAVE_VERSION.${RESET}"
        echo -e "${RED_BOLD}🌊 Nothing was installed. Check your network, then run the installer again.${RESET}"
        exit 1
    fi

    # 把本次安装的位置与配置目录告诉迁移脚本，由它自己判断该不该搬
    export LINUXWAVE_INSTALL_DIR="$BASE_DIR"
    export LINUXWAVE_CONFIG_DIR="$CONFIG_DIR"
    export LINUXWAVE_TARGET_VERSION="$LINUXWAVE_VERSION"

    if ! bash -c "$TRANSFER_COMMANDS"; then
        echo -e "${RED_BOLD}🌊 Error: The migration for $LINUXWAVE_VERSION failed.${RESET}"
        echo -e "${RED_BOLD}🌊 Nothing was installed. Fix the issue above, then run the installer again.${RESET}"
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
# 把所有权交还给当前真实用户
# ==========================================

if [[ "$NEED_SUDO" == "true" ]]; then
    if [[ "$SHARED_INSTALL" == "true" ]]; then
        sudo chown -R "$SHARED_USER:$SHARED_USER" "$BASE_DIR"
    else
        sudo chown -R "$CURRENT_USER": "$BASE_DIR"
    fi
fi

# 共享安装的配置保持 root:root 644：全体用户可读，但只有 root 能改
if [[ "$NEED_SUDO" == "true" ]]; then
    if [[ "$SHARED_INSTALL" == "true" ]]; then
        sudo chown -R root:root "$CONFIG_DIR"
    else
        sudo chown -R "$CURRENT_USER": "$CONFIG_DIR"
    fi
fi
run_cmd chmod 755 "$CONFIG_DIR"
run_cmd chmod 644 "$CONFIG_FILE"
run_cmd chmod 644 "$VERSION_FILE"

echo "🌊 Configuration saved to $CONFIG_FILE"
echo "🌊 Version saved to $VERSION_FILE"

# ==========================================
# 删除旧版 repo.json
# ==========================================

OLD_JSON="$REPO_DIR/repo.json"
if [ -f "$OLD_JSON" ]; then
    echo "🌊 Removing old repo.json (legacy format)..."
    run_cmd rm -f "$OLD_JSON"
fi

# ==========================================
# 清理旧版（2.1.0）遗留的平铺 bin/ 文件
# ==========================================

LEGACY_BINS=$(find "$INSTALL_DIR" -maxdepth 1 -type f 2>/dev/null || true)
if [[ -n "$LEGACY_BINS" ]]; then
    echo -e "${YELLOW}🌊 Removing files installed by an older version in $DISPLAY_DIR/bin:${RESET}"
    while IFS= read -r legacy_file; do
        echo -e "${YELLOW}    $(basename "$legacy_file")${RESET}"
    done <<< "$LEGACY_BINS"
    while IFS= read -r legacy_file; do
        run_cmd rm -f "$legacy_file"
    done <<< "$LEGACY_BINS"
    echo -e "${YELLOW}🌊 ${BRANCH} keeps packages in bin/{name}@{version}/ directories.${RESET}"
    echo -e "${YELLOW}🌊 Please reinstall the packages: wave install {name}${RESET}"
fi

# ==========================================
# 检查动态库路径替换所需的工具
# ==========================================

if command -v patchelf > /dev/null 2>&1; then
    echo "🌊 patchelf detected (dependency library relocation enabled)."
else
    echo -e "${YELLOW}🌊 Warning: patchelf not found.${RESET}"
    echo -e "${YELLOW}🌊 Dependency libraries cannot be relocated, so some packages may fail to run.${RESET}"
    echo "🌊 You can install it later with: sudo apt install patchelf   (or: sudo dnf install patchelf)"
fi

# ==========================================
# 解析文件清单
# ==========================================
# 清单已在上面取回（连不上就直接退出了，没动过任何东西），这里只做解析。

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
    echo -e "${RED_BOLD}🌊 Error: The file list is empty, nothing to download.${RESET}"
    exit 1
fi

FILE_COUNT=$(printf '%s\n' "$FILE_ENTRIES" | wc -l | tr -d ' ')
echo "🌊 Downloading $FILE_COUNT file(s) from branch: $BRANCH"
echo ""

# ==========================================
# 下载文件
# ==========================================

while IFS=$'\t' read -r repo_path local_path executable; do
    if [[ -z "$repo_path" ]]; then
        continue
    fi

    run_cmd mkdir -p "$(dirname "$BASE_DIR/$local_path")"

    file_ok=false
    for attempt in $(seq 1 "$DOWNLOAD_ATTEMPTS"); do
        if [[ "$attempt" -eq 1 ]]; then
            # --silent 只省交互，过程仍要留痕；逐文件进度才在 silent 下压掉
            if [[ "$CLI_SILENT" != "true" ]]; then
                echo "🌊 Downloading $repo_path..."
            fi
        else
            # 重试必须始终可见：它解释了这次安装为什么变慢
            echo -e "${YELLOW}🌊 Retrying $repo_path ($attempt/$DOWNLOAD_ATTEMPTS)...${RESET}"
        fi
        # 放在 if 条件里：失败不会被 set -e 直接带走（ERR 陷阱也不触发），
        # 由这里自己决定重试还是放弃。
        if run_cmd curl -fsSL --connect-timeout 20 --max-time 180 \
               -o "$BASE_DIR/$local_path" "$BASE_URL/$repo_path"; then
            file_ok=true
            break
        fi
        sleep "$attempt"
    done

    if [[ "$file_ok" != "true" ]]; then
        echo -e "${RED_BOLD}🌊 Error: Cannot download $repo_path after $DOWNLOAD_ATTEMPTS attempts.${RESET}" >&2
        # 交给 ERR 陷阱：它会打印「未完成 + 残留路径 + 重跑安全」的指引
        false
    fi

    if [[ "$executable" == "1" ]]; then
        run_cmd chmod +x "$BASE_DIR/$local_path"
    fi
done <<< "$FILE_ENTRIES"

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
    echo "🌊 Fetching the bundled Python definition..." >&2
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
        echo "🌊 Downloading the bundled Python $version (about 30 MB)..." >&2
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
                echo -e "${YELLOW}🌊 No hosted copy of the bundled Python; using the upstream URL.${RESET}" >&2
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
                echo -e "${YELLOW}🌊 Retrying the bundled Python download ($((attempt + 1))/3)...${RESET}"
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
mw_try ensure_portable_python "$BASE_DIR" "$(portable_python_arch)"
BUNDLED_PY="$MW_OPTIONAL_RESULT"

if [[ -n "$BUNDLED_PY" ]]; then
    PYTHON_BIN="$BUNDLED_PY"
    PYTHON_SOURCE="bundled"
    echo "🌊 Using the bundled Python: ${BUNDLED_PY#"$BASE_DIR"/}"
else
    PYTHON_BIN="$(command -v python3 || true)"
    PYTHON_SOURCE="system"
    if [[ -z "$PYTHON_BIN" ]]; then
        echo -e "${RED_BOLD}🌊 Error: no Python 3 interpreter is available.${RESET}"
        echo -e "${RED_BOLD}🌊 The bundled Python could not be downloaded and python3 is not in PATH.${RESET}"
        exit 1
    fi
    echo -e "${YELLOW}🌊 Warning: could not prepare the bundled Python; using $PYTHON_BIN instead.${RESET}"
    echo -e "${YELLOW}🌊 Re-run the installer when the network is available to make this installation self-contained.${RESET}"
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

deps_present() {
    # 判断一个解释器是否真的能 import 到三个依赖（启动器用的是同一条判据）
    [[ -n "$1" ]] || return 1
    "$1" -c 'import requests, packaging, rich' >/dev/null 2>&1
}

if [[ -n "$VENV_PY" && -x "$VENV_PY" ]]; then
    echo "🌊 Installing Python dependencies into the private environment..."
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

# 最后一道判据：选定解释器必须真的能 import。给不出可用的解释器就不要谎报安装成功。
if ! deps_present "$VENV_PY" && ! deps_present "$PYTHON_BIN"; then
    echo -e "${RED_BOLD}🌊 Error: no Python interpreter with requests/packaging/rich is available.${RESET}"
    echo -e "${RED_BOLD}🌊 Install them for one interpreter and re-run, or retry when the network is up.${RESET}"
    echo -e "${RED_BOLD}🌊   python3 -m pip install requests packaging rich${RESET}"
    exit 1
fi

write_launcher "$BASE_DIR" "$PYTHON_BIN"

# ==========================================
# 把所有权交还给用户（下载后再次确保）
# ==========================================

if [[ "$NEED_SUDO" == "true" ]]; then
    if [[ "$SHARED_INSTALL" == "true" ]]; then
        sudo chown -R "$SHARED_USER:$SHARED_USER" "$BASE_DIR"
    else
        sudo chown -R "$CURRENT_USER": "$BASE_DIR"
    fi
fi

if [[ "$SHARED_INSTALL" == "true" ]]; then
    # useradd -m 建出的家目录默认是 750，其他用户连进入都不行；
    # a+rX 里大写的 X 只给目录和原本可执行的文件加 x，不会误改普通文件。
    echo "🌊 Opening $SHARED_HOME and $BASE_DIR to all users..."
    sudo chmod 755 "$SHARED_HOME"
    sudo chmod -R a+rX "$BASE_DIR"

    # Linuxbrew 式共享写：整棵树交给 '$SHARED_USER' 组，调用者入组。
    # 只给读 + 执行是不够的——组员连 downloads/tmp 都建不出来，装包必然失败，
    # 所以这里把组写位打开。代价是组员能改动整棵树，包括 lib/wave 本体
    # （见 .templates/SPECIAL/INSTALL_BY_INTERNET.md 末尾对这一点说明）。
    echo "🌊 Setting up the '$SHARED_USER' group for shared installs..."
    sudo groupadd -f "$SHARED_USER"

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
        if sudo usermod -aG "$SHARED_USER" "$CURRENT_USER"; then
            RELOGIN_NEEDED=true
        else
            echo -e "${YELLOW}🌊 Could not add '$CURRENT_USER' to '$SHARED_USER' automatically.${RESET}"
            echo -e "${YELLOW}🌊 Add it by hand: sudo usermod -aG $SHARED_USER $CURRENT_USER${RESET}"
        fi
    fi

    sudo chgrp -R "$SHARED_USER" "$BASE_DIR"
    sudo chmod -R g+w "$BASE_DIR"
    # setgid 必须加在目录上：否则组员新建的文件会落回他自己的主组，
    # 下一个组员就写不进去了。
    sudo find "$BASE_DIR" -type d -exec chmod g+s {} +

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

PATH_LINE="export PATH=\"$INSTALL_DIR:$LINKS_DIR:$LIB_DIR:\$PATH\""

# 从 rc 文件里摘掉我们写入的 PATH 行（连同标记行）。
# 安装回滚时要靠它，否则会留下一个指向已删除目录的 PATH。
remove_lw_path_entries() {
    local rc="$1"
    [[ -f "$rc" ]] || return 0
    grep -qF -e "$PATH_LINE" -e "# LinuxWave" "$rc" 2>/dev/null || return 0
    grep -v -F -e "$PATH_LINE" -e "# LinuxWave" "$rc" > "$rc.linuxwave.tmp" || true
    cat "$rc.linuxwave.tmp" > "$rc"
    rm -f "$rc.linuxwave.tmp"
    echo "🌊 Removed LinuxWave PATH entries from $rc"
}

if [[ "$SHARED_INSTALL" == "true" ]]; then
    # 共享安装：$SHARED_USER 自己的 shell 也要能直接用 wave
    SHARED_RC="$SHARED_HOME/.bashrc"
    if sudo grep -qF "$PATH_LINE" "$SHARED_RC" 2>/dev/null; then
        echo "🌊 LinuxWave is already in $SHARED_RC."
    elif sudo test -f "$SHARED_RC"; then
        echo "🌊 Adding LinuxWave to PATH in $SHARED_RC..."
        printf '\n# LinuxWave\n%s\n' "$PATH_LINE" | sudo tee -a "$SHARED_RC" > /dev/null
        sudo chown "$SHARED_USER:$SHARED_USER" "$SHARED_RC"
    elif printf '# LinuxWave\n%s\n' "$PATH_LINE" | sudo tee "$SHARED_RC" > /dev/null; then
        # 账号预存、或 /etc/skel 里没有 .bashrc 时文件不存在。
        # 建出来，否则这个账号反而跑不了 wave，而安装却自称已完成。
        echo "🌊 Created $SHARED_RC with LinuxWave in PATH."
        sudo chmod 644 "$SHARED_RC"
        sudo chown "$SHARED_USER:$SHARED_USER" "$SHARED_RC"
    else
        echo -e "${YELLOW}🌊 Warning: could not write $SHARED_RC.${RESET}"
        echo "🌊 '$SHARED_USER' can add it manually with:"
        echo "     echo 'export PATH=\"$INSTALL_DIR:$LINKS_DIR:$LIB_DIR:\$PATH\"' >> ~/.bashrc"
    fi
fi

if grep -qF "$PATH_LINE" "$RC_FILE" 2>/dev/null; then
    echo "🌊 LinuxWave is already in your PATH."
else
    if grep -qF "$INSTALL_DIR" "$RC_FILE" 2>/dev/null; then
        # 旧版本（如 2.1.0）的 PATH 行只有 bin/ 与 lib/，升级后需要换成含 links/ 的新行
        echo "🌊 Replacing old LinuxWave PATH entry in $RC_FILE..."
        grep -v -F "export PATH=\"$INSTALL_DIR" "$RC_FILE" > "$RC_FILE.linuxwave.tmp" || true
        cat "$RC_FILE.linuxwave.tmp" > "$RC_FILE"
        rm -f "$RC_FILE.linuxwave.tmp"
    else
        echo "🌊 Adding LinuxWave to PATH in $RC_FILE..."
        echo "" >> "$RC_FILE"
        echo "# LinuxWave" >> "$RC_FILE"
    fi

    echo "$PATH_LINE" >> "$RC_FILE"
fi

# ==========================================
# 许可协议确认
# ==========================================
# 必须放在「安装完成」之前：否则先告诉用户已经装好，随后又因为不同意而全部删除。

echo ""
echo -e "${YELLOW}Please read the agreement before use (see bottom of https://linuxwave.org).${RESET}"
if [[ "$CLI_SILENT" == "true" ]]; then
    echo "🌊 --silent: the agreement is accepted automatically."
    agreement="y"
else
    echo -e "${YELLOW}Have you read and agreed to the agreement? [Y/n]${RESET}"
    read -r agreement < /dev/tty
fi
if [[ -z "$agreement" || "$agreement" =~ ^[Yy]$ ]]; then
    echo -e "${GREEN}You have agreed to the agreement.${RESET}"
else
    # 回滚要连 rc 里的 PATH 一起清掉，否则会留下指向已删除目录的一行。
    # 这里不写死 sudo：用户级安装全程无需提权，回滚也不该突然要密码。
    echo -e "${RED_BOLD}You do not agree to the agreement. Installation stopped.${RESET}"
    echo -e "${RED_BOLD}🌊 Cleaning up downloaded files...${RESET}"
    run_cmd rm -rf "$BASE_DIR"
    run_cmd rm -rf "$CONFIG_DIR"
    remove_lw_path_entries "$RC_FILE"
    if [[ "$SHARED_INSTALL" == "true" ]] && sudo test -f "$SHARED_HOME/.bashrc"; then
        sudo python3 - "$SHARED_HOME/.bashrc" "$PATH_LINE" << 'PYEOF'
import sys
from pathlib import Path

rc_file = Path(sys.argv[1])
path_line = sys.argv[2]
kept = [line for line in rc_file.read_text().splitlines()
        if line.strip() != "# LinuxWave" and line != path_line]
rc_file.write_text("\n".join(kept) + ("\n" if kept else ""))
PYEOF
        echo "🌊 Removed LinuxWave PATH entries from $SHARED_HOME/.bashrc"
    fi
    echo -e "${RED_BOLD}🌊 All files have been deleted.${RESET}"
    exit 1
fi

# ==========================================
# 完成信息
# ==========================================

echo ""
echo "🌊 Installation complete!"
echo "🌊 LinuxWave installed to: $DISPLAY_DIR"
echo "🌊 Architecture: $ARCH"
echo ""

if [[ "$SHARED_INSTALL" == "true" ]]; then
    echo "🌊 Shared install ready."
    echo "🌊 Config   : $CONFIG_DIR  (system-level, every user resolves it)"
    echo "🌊 Owner    : $SHARED_USER:$SHARED_USER  (shared write via the '$SHARED_USER' group)"
    echo "🌊 Other users can enable 'wave' with:"
    echo -e "${YELLOW}    echo 'export PATH=\"$INSTALL_DIR:$LINKS_DIR:$LIB_DIR:\$PATH\"' >> ~/.bashrc${RESET}"
    if [[ "$RELOGIN_NEEDED" == "true" ]]; then
        echo -e "${YELLOW}🌊 '$CURRENT_USER' is now in the '$SHARED_USER' group, but this shell does${RESET}"
        echo -e "${YELLOW}🌊 not have it yet: log out and back in (or run 'newgrp $SHARED_USER') before${RESET}"
        echo -e "${YELLOW}🌊 installing packages. A group only takes effect in a new login session -${RESET}"
        echo -e "${YELLOW}🌊 until then the tree is still unwritable, and 'wave' will say so.${RESET}"
        echo -e "${YELLOW}🌊 If it is still unwritable after a re-login, the user manager started at${RESET}"
        echo -e "${YELLOW}🌊 your first login is holding the old credentials: run${RESET}"
        echo -e "${YELLOW}     systemctl --user exit${RESET}"
        echo -e "${YELLOW}🌊 then log in again (a reboot does the same).${RESET}"
    else
        echo "🌊 '$CURRENT_USER' already has the '$SHARED_USER' group; nothing to re-login for."
    fi
    echo "🌊 Installs go through that group, so they need no sudo and no full path:"
    echo "     wave install <package>"
    echo "🌊 To let more users install:"
    echo "     sudo usermod -aG $SHARED_USER <user>   (they re-login as well)"
    echo "🌊 'wave selfupdate' still needs sudo: it rewrites $CONFIG_DIR, which is root-owned."
    echo ""
fi
RC_DISPLAY=$(home_to_tilde "$RC_FILE")
echo "🌊 To use 'wave' immediately in this terminal, run:"
echo -e "${YELLOW}    source $RC_DISPLAY${RESET}"
echo "🌊 Or simply open a new terminal window."
echo ""