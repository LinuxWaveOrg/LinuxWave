#!/bin/bash

# LinuxWave 🌊 Official Installer
# This script downloads wave.py, installs dependencies, and configures PATH.
# Usage: /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Sha0huaZhang/LinuxWave/HEAD/lib/install.sh)"

set -e

BRANCH="HEAD"

# 版本号只在这里定义：欢迎语与写入 VERSION.json 都引用它
LINUXWAVE_VERSION="2.5.1"

BASE_URL="https://raw.githubusercontent.com/Sha0huaZhang/LinuxWave/$BRANCH"

# ==========================================
# 颜色定义
# ==========================================

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'

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
    echo "🌊 The '$SHARED_USER' account is created automatically if missing."
    echo "🌊 Every user on this machine will be able to run 'wave'."
    echo "🌊 To let several users install packages, see the group setup in"
    echo "🌊 .templates/SPECIAL/INSTALL_BY_INTERNET.md."
    echo ""
}

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

if [[ "$ARCH" == "x86_64" ]] || [[ "$ARCH" == "amd64" ]]; then
    echo -e "${YELLOW}Where do you want to install LinuxWave? (Enter the number)${RESET}"
    echo "1. ~/.local/linuxwave"
    echo "2. /opt/linuxwave"
    echo "3. /usr/local/linuxwave"
    echo "4. $SHARED_BASE_DIR (shared, all users)"
    echo "5. other (enter custom directory)"
    echo ""
    echo -e "${YELLOW}Enter your choice:${RESET}"

    read -r choice < /dev/tty

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
            echo -e "${YELLOW}Please enter the installation directory:${RESET}"
            read -r custom_dir < /dev/tty
            validated=$(validate_custom_dir "$custom_dir") || exit 1
            BASE_DIR="$validated"
            ;;
        *)
            echo -e "${RED_BOLD}🌊 Invalid choice. Using default: ~/.local/linuxwave${RESET}"
            BASE_DIR="$HOME/.local/linuxwave"
            ;;
    esac
else
    echo -e "${YELLOW}Where do you want to install LinuxWave? (Enter the number)${RESET}"
    echo "1. ~/.local/linuxwave"
    echo "2. /opt/linuxwave"
    echo "3. $SHARED_BASE_DIR (shared, all users)"
    echo "4. other (enter custom directory)"
    echo ""
    echo -e "${YELLOW}Enter your choice:${RESET}"

    read -r choice < /dev/tty

    case "$choice" in
        1)
            BASE_DIR="$HOME/.local/linuxwave"
            ;;
        2)
            BASE_DIR="/opt/linuxwave"
            ;;
        3)
            SHARED_INSTALL=true
            BASE_DIR="$SHARED_BASE_DIR"
            ;;
        4)
            echo -e "${YELLOW}Please enter the installation directory:${RESET}"
            read -r custom_dir < /dev/tty
            validated=$(validate_custom_dir "$custom_dir") || exit 1
            BASE_DIR="$validated"
            ;;
        *)
            echo -e "${RED_BOLD}🌊 Invalid choice. Using default: ~/.local/linuxwave${RESET}"
            BASE_DIR="$HOME/.local/linuxwave"
            ;;
    esac
fi

DISPLAY_DIR=$(home_to_tilde "$BASE_DIR")

if [[ "$SHARED_INSTALL" == "true" ]]; then
    print_shared_install_notes
fi

# ==========================================
# 判断是否需要 sudo
# ==========================================

CURRENT_USER=$(whoami)

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
    echo -e "${YELLOW}🌊 Granting temporary administrator access for installation...${RESET}"
    sudo -v
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

CONFIGDATA_URL="https://raw.githubusercontent.com/Sha0huaZhang/LinuxWave/configdata"
FILES_INFO_URL="$CONFIGDATA_URL/versiondata/files_info"
FILES_INFO_TMP="$(mktemp)"
FILES_INFO_ATTEMPTS=3

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

    echo "🌊 Downloading $repo_path..."
    run_cmd mkdir -p "$(dirname "$BASE_DIR/$local_path")"
    run_cmd curl -fsSL -o "$BASE_DIR/$local_path" "$BASE_URL/$repo_path"

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

if [[ "$SHARED_INSTALL" == "true" ]]; then
    # 共享安装：$SHARED_USER 自己的 shell 也要能直接用 wave
    SHARED_RC="$SHARED_HOME/.bashrc"
    if sudo test -f "$SHARED_RC"; then
        if sudo grep -qF "$PATH_LINE" "$SHARED_RC" 2>/dev/null; then
            echo "🌊 LinuxWave is already in $SHARED_RC."
        else
            echo "🌊 Adding LinuxWave to PATH in $SHARED_RC..."
            printf '\n# LinuxWave\n%s\n' "$PATH_LINE" | sudo tee -a "$SHARED_RC" > /dev/null
            sudo chown "$SHARED_USER:$SHARED_USER" "$SHARED_RC"
        fi
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
    echo "🌊 Owner    : $SHARED_USER"
    echo "🌊 Other users can enable 'wave' with:"
    echo -e "${YELLOW}    echo 'export PATH=\"$INSTALL_DIR:$LINKS_DIR:$LIB_DIR:\$PATH\"' >> ~/.bashrc${RESET}"
    echo "🌊 Only '$SHARED_USER' and root can install packages; see"
    echo "🌊 .templates/SPECIAL/INSTALL_BY_INTERNET.md for the shared-write group setup."
    echo ""
fi
RC_DISPLAY=$(home_to_tilde "$RC_FILE")
echo "🌊 To use 'wave' immediately in this terminal, run:"
echo -e "${YELLOW}    source $RC_DISPLAY${RESET}"
echo "🌊 Or simply open a new terminal window."
echo ""

# ==========================================
# 许可协议确认
# ==========================================

echo ""
echo -e "${YELLOW}Please read the agreement before use (see bottom of https://linuxwave.macwave.org).${RESET}"
echo -e "${YELLOW}Have you read and agreed to the agreement? [Y/n]${RESET}"
read -r agreement < /dev/tty
if [[ -z "$agreement" || "$agreement" =~ ^[Yy]$ ]]; then
    echo -e "${GREEN}You have agreed to the agreement. Installation continues.${RESET}"
else
    echo -e "${RED_BOLD}You do not agree to the agreement. Installation stopped.${RESET}"
    echo -e "${RED_BOLD}🌊 Cleaning up downloaded files...${RESET}"
    run_cmd rm -rf "$BASE_DIR"
    sudo rm -rf "$CONFIG_DIR"
    echo -e "${RED_BOLD}🌊 All files have been deleted.${RESET}"
    exit 1
fi