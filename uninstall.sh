#!/bin/bash
# LinuxWave Uninstaller
# 卸载 LinuxWave 及清理环境配置

SYSTEM_CONFIG_DIR="/etc/linuxwave_config"
USER_CONFIG_DIR="$HOME/.config/linuxwave_config"

# 共享安装（install.sh 的菜单选项 4）
SHARED_USER="linuxwave"
SHARED_HOME="/home/$SHARED_USER"
SHARED_BASE_DIR="$SHARED_HOME/.linuxwave"
SHARED_USER_CONFIG="$SHARED_HOME/.config/linuxwave_config"
SHARED_DETECTED=false

# ==========================================
# 命令行参数（批量 / 脚本化卸载）
# ==========================================

CLI_FORCE=false
CLI_REMOVE_USER=false

usage() {
    cat <<'USAGE_EOF'
LinuxWave uninstaller

Usage:
  uninstall.sh [options]

Options:
      --force         No confirmation prompts. Removes LinuxWave and its
                      configuration, but KEEPS the 'linuxwave' account.
      --remove-user   Also remove the 'linuxwave' account, without asking.
                      This deletes its home directory and everything in it.
      -h, --help      Show this help.

Without options the uninstaller asks twice: once before deleting, and once
before removing the 'linuxwave' account (a shared install only).
USAGE_EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)
            CLI_FORCE=true
            ;;
        --remove-user)
            CLI_REMOVE_USER=true
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "🌊 Error: unknown option '$1'. Try --help." >&2
            exit 1
            ;;
    esac
    shift
done

# 通过管道卸载时，选项容易被当成脚本名传进来（--force 会静默失效）
case "$0" in
    -*)
        echo "🌊 Warning: '$0' was treated as the script name, not as an option." >&2
        echo "🌊 When piping the uninstaller, pass options after 'bash -s --'." >&2
        echo "🌊   curl -fsSL <url> | bash -s -- $0" >&2
        ;;
esac

# 默认尝试删除的路径列表
BASE_DIRS=()

# 1. 如果配置文件存在，优先读取（系统级与用户级都读，两边都卸干净）
for CONFIG_DIR in "$SYSTEM_CONFIG_DIR" "$USER_CONFIG_DIR"; do
    if [ -f "$CONFIG_DIR/config.json" ]; then
        READ_DIR=$(python3 -c "import json; print(json.load(open('$CONFIG_DIR/config.json')).get('base_dir', ''))" 2>/dev/null)
        if [ -n "$READ_DIR" ]; then
            BASE_DIRS+=("$READ_DIR")
            if [ "$READ_DIR" = "$SHARED_BASE_DIR" ]; then
                SHARED_DETECTED=true
            fi
        fi
    fi
done

# 1b. 配置可能已被上一次卸载清掉；只要还有共享安装的痕迹，就按共享安装处理
if [ -d "$SHARED_BASE_DIR" ] || [ -d "$SHARED_USER_CONFIG" ]; then
    SHARED_DETECTED=true
fi

# 2. 如果读取失败（或文件不存在），把所有可能的路径都加入列表
if [ ${#BASE_DIRS[@]} -eq 0 ]; then
    BASE_DIRS+=("$HOME/.local/linuxwave")
    BASE_DIRS+=("/opt/linuxwave")
    BASE_DIRS+=("/usr/local/linuxwave")
    BASE_DIRS+=("$SHARED_BASE_DIR")
fi

if [[ "$CLI_FORCE" == "true" ]]; then
    echo "🌊 --force: uninstalling without confirmation."
else
    echo -e "\033[1;31mYou are deleting LinuxWave, are you sure? [Y/n]\033[0m"
    read -n 1 -r
    echo
    if [[ -n "$REPLY" && ! "$REPLY" =~ ^[Yy]$ ]]; then
        echo "🌊 Uninstall cancelled."
        exit 0
    fi
fi

# 逐个尝试删除所有可能的路径
for DIR in "${BASE_DIRS[@]}"; do
    if [ -d "$DIR" ]; then
        # 如果是系统级目录，需要 sudo
        if [[ "$DIR" == "$HOME"* ]]; then
            echo "🌊 Removing $DIR..."
            rm -rf "$DIR"
        else
            echo "🌊 Removing $DIR (with sudo)..."
            sudo rm -rf "$DIR"
        fi
    fi
done

# 删除配置目录（系统级与用户级都可能存在）
for CONFIG_DIR in "$SYSTEM_CONFIG_DIR" "$USER_CONFIG_DIR"; do
    if [ -d "$CONFIG_DIR" ]; then
        if [[ "$CONFIG_DIR" == "$HOME"* ]]; then
            echo "🌊 Removing $CONFIG_DIR..."
            rm -rf "$CONFIG_DIR"
        else
            echo "🌊 Removing $CONFIG_DIR (with sudo)..."
            sudo rm -rf "$CONFIG_DIR"
        fi
    fi
done

# 共享安装：安装时 HOME 指向过共享用户，配置可能写在它自己的家目录里
if [[ "$SHARED_DETECTED" == "true" ]] && [ -d "$SHARED_USER_CONFIG" ]; then
    echo "🌊 Removing $SHARED_USER_CONFIG (with sudo)..."
    sudo rm -rf "$SHARED_USER_CONFIG"
fi

# 3. 共享安装树可能没被任何配置指向（上一次卸载已把配置清掉），补进待删列表，
#    与「检测到共享安装就询问是否删除用户」的判断保持一致
if [[ "$SHARED_DETECTED" == "true" ]] && [ -d "$SHARED_BASE_DIR" ]; then
    case " ${BASE_DIRS[*]} " in
        *" $SHARED_BASE_DIR "*) ;;
        *) BASE_DIRS+=("$SHARED_BASE_DIR") ;;
    esac
fi

# 清理 PATH 配置（含自定义安装目录：删掉“# LinuxWave”注释行与紧跟在它后面的 PATH 行）
for RC_FILE in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.profile"; do
    if [ -f "$RC_FILE" ]; then
        python3 - "$RC_FILE" << 'PYEOF'
import sys
from pathlib import Path

rc_file = Path(sys.argv[1])
kept = []
skip_next = False
for line in rc_file.read_text().splitlines():
    if line.strip() == "# LinuxWave":
        skip_next = True
        continue
    if skip_next and line.startswith("export PATH="):
        skip_next = False
        continue
    skip_next = False
    kept.append(line)
rc_file.write_text("\n".join(kept) + ("\n" if kept else ""))
PYEOF
        # 兜底：注释行缺失时，仍按旧版写法删掉 linuxwave 的 PATH 行
        sed -i '/export PATH=".*linuxwave\//d' "$RC_FILE" 2>/dev/null || true
        echo "🌊 Removed LinuxWave PATH entries from $RC_FILE"
    fi
done

# 共享安装：$SHARED_USER 的 rc 里也写入了 PATH
if [[ "$SHARED_DETECTED" == "true" ]] && sudo test -f "$SHARED_HOME/.bashrc"; then
    python3 - "$SHARED_HOME/.bashrc" << 'PYEOF'
import sys
from pathlib import Path

rc_file = Path(sys.argv[1])
kept = []
skip_next = False
for line in rc_file.read_text().splitlines():
    if line.strip() == "# LinuxWave":
        skip_next = True
        continue
    if skip_next and line.startswith("export PATH="):
        skip_next = False
        continue
    skip_next = False
    kept.append(line)
rc_file.write_text("\n".join(kept) + ("\n" if kept else ""))
PYEOF
    echo "🌊 Removed LinuxWave PATH entries from $SHARED_HOME/.bashrc"
fi

# ========== 共享安装：删除专用用户（会连带删除家目录） ==========
remove_shared_user() {
    local uid err
    uid=$(id -u "$SHARED_USER" 2> /dev/null)

    echo "🌊 Removing user '$SHARED_USER' (with sudo)..."
    # 该用户一旦建立过会话，systemd 会为其启动 user manager，
    # userdel 会以「用户当前被进程使用」拒绝删除。先把它停掉再删。
    sudo loginctl disable-linger "$SHARED_USER" > /dev/null 2>&1 || true
    sudo systemctl stop "user@$uid.service" > /dev/null 2>&1 || true

    if err=$(sudo userdel -r "$SHARED_USER" 2>&1); then
        echo "🌊 User '$SHARED_USER' removed."
        return 0
    fi

    echo -e "\033[1;31m🌊 Error: could not remove user '$SHARED_USER'.${RESET}"
    [ -n "$err" ] && echo "🌊 $err"
    echo "🌊 Something is still using that account. Check with:"
    echo "     ps -u $SHARED_USER"
    echo "🌊 Then remove it manually with:"
    echo "     sudo systemctl stop user@$uid.service"
    echo "     sudo userdel -r $SHARED_USER"
    return 1
}

REMOVE_USER_FAILED=false
if [[ "$SHARED_DETECTED" == "true" ]] && id "$SHARED_USER" > /dev/null 2>&1; then
    if [[ "$CLI_REMOVE_USER" == "true" ]]; then
        echo ""
        echo -e "\033[1;31m🌊 --remove-user: deleting the '$SHARED_USER' account and its home directory.${RESET}"
        remove_shared_user || REMOVE_USER_FAILED=true
    elif [[ "$CLI_FORCE" == "true" ]]; then
        echo ""
        echo "🌊 --force: keeping the '$SHARED_USER' user."
        echo "🌊 Remove it later with:  sudo userdel -r $SHARED_USER"
        echo "🌊 Or run this script again with --remove-user."
    else
        echo ""
        echo -e "\033[1;31m🌊 Warning: this was a shared install.${RESET}"
        echo "🌊 Removing the '$SHARED_USER' account also deletes its home directory"
        echo "🌊 ($SHARED_HOME) and everything else stored in it, not just LinuxWave."
        echo "🌊 It is a dedicated account created for LinuxWave, so this is normally safe."
        echo ""
        echo -e "\033[1;31mAlso remove the '$SHARED_USER' user? [y/N]\033[0m"
        read -n 1 -r < /dev/tty
        echo
        if [[ "$REPLY" =~ ^[Yy]$ ]]; then
            remove_shared_user || REMOVE_USER_FAILED=true
        else
            echo "🌊 Kept the '$SHARED_USER' user. Remove it later with:"
            echo "     sudo userdel -r $SHARED_USER"
        fi
    fi
fi

echo ""
echo "🌊 LinuxWave has been uninstalled."
echo "🌊 Please restart your terminal to apply changes."

# ========== 删除自身脚本 ==========
rm -f "$0"

if [[ "$REMOVE_USER_FAILED" == "true" ]]; then
    exit 1
fi
exit 0
