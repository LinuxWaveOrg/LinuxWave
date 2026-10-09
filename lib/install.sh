#!/bin/bash

# LinuxWave 🌊 Official Installer
# This script downloads wave.py, installs dependencies, and configures PATH.
# Usage: /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/LinuxWaveOrg/LinuxWave/HEAD/lib/install.sh)"

# -E（errtrace）让下面那个 ERR 陷阱能看见 run_cmd 等**函数内部**的失败：
# 默认情况下陷阱不继承进函数，中途失败就只剩一个光秃秃的 curl 退出码。
# 显式 `return 1`、调用方用 `||` 容忍的失败、`if` 条件里的失败都不会误触发。
set -eE

# 数据仓库：版本号、代码分支与文件清单都从这里读
CONFIGDATA_URL="https://raw.githubusercontent.com/LinuxWaveOrg/configdata/main"

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
BASE_URL="https://raw.githubusercontent.com/LinuxWaveOrg/LinuxWave/$BRANCH"

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
SHARED_CONFIG_DIR="/etc/linuxwave_config"

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
        BASE_DIR="/opt/linuxwave"
        ;;
    3)
        BASE_DIR="/usr/local/linuxwave"
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
        sudo "$@"
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
# 唯一的特例：lib/wave.py 装成可执行的 lib/wave（它是 PATH 里的入口名）。
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
    CONFIG_DIR="/etc/linuxwave_config"
else
    CONFIG_DIR="$HOME/.config/linuxwave_config"
fi
CONFIG_FILE="$CONFIG_DIR/config.json"
VERSION_FILE="$CONFIG_DIR/VERSION.json"

# 中途失败时给出明确指引。刻意**不自动删除**已下载的内容：升级安装时
# 删掉安装树会把用户原有的可用安装一起毁掉，重跑安装器才是安全的做法。
install_failed() {
    local code=$?
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
# 安装 Python 依赖
# ==========================================

echo "🌊 Checking Python dependencies..."
if ! python3 -c "import requests" 2>/dev/null; then
    echo "🌊 Installing 'requests' library..."
    pip3 install requests --quiet
else
    echo "🌊 'requests' library is already installed."
fi

if ! python3 -c "from packaging.version import parse" 2>/dev/null; then
    echo "🌊 Installing 'packaging' library..."
    pip3 install packaging --quiet
else
    echo "🌊 'packaging' library is already installed."
fi

if ! python3 -c "import rich" 2>/dev/null; then
    echo "🌊 Installing 'rich' library for progress bar..."
    if pip3 install rich --quiet; then
        echo "🌊 'rich' installed successfully."
    else
        echo -e "${RED_BOLD}🌊 Warning: 'rich' installation failed. Progress bar will not be available.${RESET}"
        echo "🌊 You can install it manually later: pip3 install rich"
    fi
else
    echo "🌊 'rich' library is already installed."
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