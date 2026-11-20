#!/bin/bash
# LinuxWave Uninstaller
# 卸载 LinuxWave 及清理环境配置

# ==========================================
# 输出层：双语与呈现
# ==========================================
# 与 lib/install.sh 同一套。所有面向用户的话都过 lw_say / lw_say_err，三件事
# 因此只在这两个函数里做一次：
#   1. 双语：lw_say "<English>" "<中文>"；只给一句时两种语言共用。
#   2. --raw：去掉颜色与行首的 🌊（逐行过滤，见 lw_raw_filter）。
#   3. --zh：说中文。默认英文 —— 终端不一定有中文 locale。
#
# 卸载脚本多一个 lw_plan / lw_dry_run：`--dry-run` 只报告将要删什么，
# 一个字节都不动。删除不可逆，先看一遍再动手比事后恢复便宜。
RED_BOLD='\033[1;31m'
YELLOW='\033[33m'
RESET='\033[0m'

CLI_RAW=false
CLI_DRY_RUN=false
LW_LANG="en"
_PRESENTATION_APPLIED=false

lw_raw() { [[ "${CLI_RAW:-false}" == "true" ]]; }
lw_dry_run() { [[ "${CLI_DRY_RUN:-false}" == "true" ]]; }

# 逐行读 stdin，去掉行首的 🌊 与紧跟的一个空格。
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
    # 只给一句时两种语言都用它。注意是 `-` 不是 `:-`：显式传了空串必须打空行。
    if [[ "$LW_LANG" == "zh" ]]; then
        printf '%b\n' "${2-$1}"
    else
        printf '%b\n' "$1"
    fi
}

lw_say_err() {
    # 错误两边都打：英文给日志与工单，中文给用户。语言只决定先后。
    # 这里必须用 if 而不是 `[[ … ]] && printf`：本脚本是 set -e，条件为假时那条
    # 复合命令返回 1，会被当成一次失败把卸载**静默**终止。
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
    # lw_plan <English> <中文>：试运行时把「本来会发生什么」打出来。
    # 不在试运行时一个字都不输出，调用点因此不必套 if。
    lw_dry_run || return 0
    if [[ "$LW_LANG" == "zh" ]]; then
        printf '%b\n' "${2-$1}"
    else
        printf '%b\n' "$1"
    fi
}

# --raw 要关颜色、改输出管道，而参数是在后面才解析的。解析完之后再调一次，
# 把「还没开始说话之前」就已经定了的事补上。
lw_apply_presentation() {
    [[ "$_PRESENTATION_APPLIED" == "true" ]] && return 0
    if lw_raw; then
        RED_BOLD=""; YELLOW=""; RESET=""
        exec > >(lw_raw_filter) 2>&1
    fi
    _PRESENTATION_APPLIED=true
}

# 最早的参数预扫：下面两道闸门在正式解析之前就要说话，而它们该按 --zh / --raw
# 的样子说话。正式解析在「命令行参数」一节，两处认的是同一批旗标。
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
# 解释器版本闸门
# ==========================================
# 下面用到 bash 4.4 的展开（${var,,} 之类）。3.x 不会报错，只会静默算出错误
# 结果，所以门槛必须立在最前面。
# `-z $BASH_VERSION` 那半句同时挡住 `sh uninstall.sh` / dash：否则脚本会跑到一半
# 才炸在 [[ 上，报错还看不出真正原因。
if [ -z "${BASH_VERSION:-}" ]; then
    printf '%s\n' "🌊 Error: run this with bash, not sh. / 错误：请用 bash 运行，不要用 sh。" >&2
    exit 1
fi
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    printf '%s\n' "🌊 Error: LinuxWave needs bash 4.4 or newer; this is $BASH_VERSION. / 错误：LinuxWave 需要 bash 4.4 或更高，当前是 ${BASH_VERSION}。" >&2
    printf '%s\n' "🌊 Debian/Ubuntu: sudo apt install bash   Fedora/RHEL: sudo dnf install bash   macOS: brew install bash" >&2
    exit 1
fi

# ==========================================
# 平台闸门：LinuxWave 只装 Linux
# ==========================================
if [[ "$(uname -s 2>/dev/null)" != "Linux" ]]; then
    printf '%s\n' "🌊 Error: this uninstaller is for Linux; this system is $(uname -s 2>/dev/null). / 错误：这个卸载器只用于 Linux，本机是 $(uname -s 2>/dev/null)。" >&2
    printf '%s\n' "🌊 On macOS use MacWave instead: https://macwave.org / macOS 请改用 MacWave：https://macwave.org" >&2
    exit 1
fi

# 与 lib/install.sh 同一套严格模式，一条都不省：
#   -e        任一条命令失败就停
#   -E        ERR 陷阱继承进函数 —— 否则函数中途失败只剩一个光秃秃的退出码
#   -u        读未定义变量即中止（脚本里所有可选项都写成 ${VAR:-}）
#   pipefail  管道中任一段失败都算失败（`cmd | grep …` 吞掉 cmd 的错最容易漏）
#
# 卸载脚本尤其需要 -e：中途失败却继续往下删，会把安装树删成半成品 —— 那时用户
# 既没有完整的 LinuxWave，也拿不回已经删掉的那部分。
set -eE
set -u
set -o pipefail

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
    SYS_ROOT="$(cd "$_lw_root" && pwd)"
    export HOME="$SYS_ROOT${HOME}"
    export LINUXWAVE_TEST_ROOT="$SYS_ROOT"
    mkdir -p "$HOME"
    # 不带 🌊：这行在呈现层（--raw 的过滤器）装好之前就打，带了也过滤不掉。
    printf '%s\n' "Test root: $SYS_ROOT"
fi

SYSTEM_CONFIG_DIR="$SYS_ROOT/etc/linuxwave_config"
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
      --dry-run       Print what would be removed and change nothing.
      --raw           Plain output for logs and scripts: no emoji, no colour.
      --zh            Speak Chinese (English by default).
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
        --dry-run|--DRY-RUN)
            CLI_DRY_RUN=true
            ;;
        --raw|--RAW)
            CLI_RAW=true
            ;;
        --zh|--ZH)
            LW_LANG="zh"
            ;;
        --remove-user)
            CLI_REMOVE_USER=true
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            lw_say_err "🌊 Error: unknown option '$1'. Try --help." "🌊 错误：未知选项 '$1'。可试 --help。"
            exit 1
            ;;
    esac
    shift
done

# 用 `/bin/bash -c "$(curl ...)"` 运行时，第一个参数会变成脚本名（$0），
# 选项会被静默丢掉（--force 失效）。正确写法是加 `--`。
case "$0" in
    --) ;;              # 正确写法：`--` 之后的参数才轮到脚本
    -*)
        lw_say_err "🌊 Warning: '$0' was treated as the script name, not as an option." \
                   "🌊 警告：'$0' 被当成了脚本名，而不是选项。"
        lw_say_err "🌊 Put uninstaller options after '--', which ends bash's own options." \
                   "🌊 请把卸载器的选项写在 '--' 之后 —— 那是 bash 自身选项的结束符。"
        lw_say_err "🌊   /bin/bash -c \"\$(curl -fsSL <url>)\" -- $0" ""
        ;;
esac

lw_remove_tree() {
    # lw_remove_tree <路径> [sudo]
    # 删一棵树。试运行（--dry-run）时只报告，一个字节都不动 —— 删除不可逆，
    # 先让人看一眼再动手。
    local dir="$1" how="${2:-auto}"
    if lw_dry_run; then
        lw_plan "Would remove $dir" "将删除 $dir"
        return 0
    fi
    if [[ "$how" == "sudo" ]]         || { [[ "$how" == "auto" ]] && [[ "$dir" != "$HOME"* ]]; }; then
        lw_say "🌊 Removing $dir (with sudo)..." "🌊 正在删除 ${dir}（需要 sudo）……"
        sudo rm -rf "$dir"
    else
        lw_say "🌊 Removing $dir..." "🌊 正在删除 ${dir}……"
        rm -rf "$dir"
    fi
}

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
    BASE_DIRS+=("$SYS_ROOT/opt/linuxwave")
    BASE_DIRS+=("$SYS_ROOT/usr/local/linuxwave")
    BASE_DIRS+=("$SHARED_BASE_DIR")
fi

if lw_dry_run; then
    lw_plan "🌊 Dry run: nothing will be removed." "🌊 试运行：什么都不会删。"
elif [[ "$CLI_FORCE" == "true" ]]; then
    lw_say "🌊 --force: uninstalling without confirmation." "🌊 --force：不再确认，直接卸载。"
else
    lw_say "${RED_BOLD}You are deleting LinuxWave, are you sure? [Y/n]${RESET}" \
           "${RED_BOLD}你正在删除 LinuxWave，确定吗？[Y/n]${RESET}"
    # 从 /dev/tty 读，且读不到就**中止**：
    # 删除是不可逆的，stdin 是 EOF（< /dev/null、CI、被别的命令吃掉输入）时
    # 绝不能默认当成「同意」。无人值守的场景请显式用 --force。
    # `2>/dev/null` 写在输入重定向之前：没有控制终端时打开 /dev/tty 会失败，
    # 重定向按从左到右处理，先屏蔽 stderr 才不会喷出那行原始报错。
    if ! read -n 1 -r 2>/dev/null < /dev/tty; then
        echo
        lw_say_err "${RED_BOLD}🌊 No terminal available to confirm on. Nothing was deleted.${RESET}" \
                   "${RED_BOLD}🌊 没有可用来确认的终端，什么都没有删。${RESET}"
        lw_say_err "🌊 To uninstall non-interactively, run again with --force." \
                   "🌊 要免交互卸载，请加 --force 再跑一次。"
        exit 1
    fi
    echo
    if [[ -n "${REPLY:-}" && "${REPLY,,}" != "y" ]]; then
        lw_say "🌊 Uninstall cancelled." "🌊 已取消卸载。"
        exit 0
    fi
fi

# 逐个尝试删除所有可能的路径
#
# 只删「看起来确实是 LinuxWave 安装」的目录：base_dir 来自 config.json，而用户级
# 配置对任何以该用户身份运行的进程都可写。不校验就拿去 `sudo rm -rf`，一条被改过
# 的 base_dir 就能把 /usr/local 或家目录整片删掉 —— 与 MacWave 4.3.1 修掉的是
# 同一类问题。
#
# 判据是 lib/wave.py：只有安装树有它。判不出来就不删，并说清是哪一条挡住的。
skip_reason() {
    # 返回一句短语，由调用方拼进「Skipping <目录>：<短语>」。短语要跟着 --zh 走，
    # 否则中文句子里会夹一段英文。
    local dir="$1"
    _r() { if [[ "$LW_LANG" == "zh" ]]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }
    if [[ -z "$dir" ]]; then
        _r "empty path" "路径为空"
    elif [[ "$dir" != /* ]]; then
        _r "not an absolute path" "不是绝对路径"
    else
        case "$dir" in
            /|/bin|/sbin|/usr|/usr/bin|/usr/sbin|/usr/lib|/usr/lib64|/usr/libexec|/usr/local|/usr/share|/opt|/etc|/var|/tmp|/boot|/dev|/proc|/sys|/run|/srv|/mnt|/media|/root|/home|/lib|/lib64)
                _r "a system directory" "一个系统目录" ;;
            "$HOME"|"$HOME"/)
                _r "your home directory" "你的家目录" ;;
            *)
                [[ -f "$dir/lib/wave.py" ]] || _r "not a LinuxWave install (no lib/wave.py)" "不是 LinuxWave 安装（没有 lib/wave.py）" ;;
        esac
    fi
}

for DIR in "${BASE_DIRS[@]}"; do
    if [ ! -d "$DIR" ]; then
        continue
    fi
    REASON="$(skip_reason "$DIR")"
    if [[ -n "$REASON" ]]; then
        lw_say_err "${YELLOW}🌊 Skipping $DIR: $REASON.${RESET}" \
                   "${YELLOW}🌊 跳过 ${DIR}：${REASON}。${RESET}"
        lw_say_err "🌊 Nothing was deleted there. If you are sure, remove it yourself." \
                   "🌊 那里一个字节都没删。如果你确认要删，请自己动手。"
        continue
    fi
    # 系统级目录要 sudo；lw_remove_tree 自己判断，--dry-run 时只报告
    lw_remove_tree "$DIR"
done

# 删除配置目录（系统级与用户级都可能存在）
for CONFIG_DIR in "$SYSTEM_CONFIG_DIR" "$USER_CONFIG_DIR"; do
    if [ -d "$CONFIG_DIR" ]; then
        lw_remove_tree "$CONFIG_DIR"
    fi
done

# 共享安装：安装时 HOME 指向过共享用户，配置可能写在它自己的家目录里
if [[ "$SHARED_DETECTED" == "true" ]] && [ -d "$SHARED_USER_CONFIG" ]; then
    lw_remove_tree "$SHARED_USER_CONFIG" sudo
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
        if lw_dry_run; then
            lw_plan "Would remove LinuxWave PATH entries from $RC_FILE" \
                    "将从 $RC_FILE 删除 LinuxWave 的 PATH 行"
            continue
        fi
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
    # 新版写的是 `eval "$(… wave shellenv)"`，旧版写的是 `export PATH="…"`；
    # 两种都得认，否则升级过一版的用户卸不干净。
    if skip_next and (line.startswith("export PATH=")
                      or (line.startswith("eval ") and "shellenv" in line)):
        skip_next = False
        continue
    skip_next = False
    kept.append(line)
rc_file.write_text("\n".join(kept) + ("\n" if kept else ""))
PYEOF
        # 兜底：注释行缺失时，仍按旧版写法删掉 linuxwave 的 PATH 行
        sed -i -e '/export PATH=".*linuxwave\//d' -e '/^eval .*linuxwave.*shellenv.*/d' "$RC_FILE" 2>/dev/null || true
        lw_say "🌊 Removed LinuxWave PATH entries from $RC_FILE" \
               "🌊 已从 $RC_FILE 删除 LinuxWave 的 PATH 行"
    fi
done

# 共享安装：$SHARED_USER 的 rc 里也写入了 PATH
if [[ "$SHARED_DETECTED" == "true" ]] && sudo test -f "$SHARED_HOME/.bashrc"; then
    if lw_dry_run; then
        lw_plan "Would remove LinuxWave PATH entries from $SHARED_HOME/.bashrc" \
                "将从 $SHARED_HOME/.bashrc 删除 LinuxWave 的 PATH 行"
    else
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
    # 新版写的是 `eval "$(… wave shellenv)"`，旧版写的是 `export PATH="…"`；
    # 两种都得认，否则升级过一版的用户卸不干净。
    if skip_next and (line.startswith("export PATH=")
                      or (line.startswith("eval ") and "shellenv" in line)):
        skip_next = False
        continue
    skip_next = False
    kept.append(line)
rc_file.write_text("\n".join(kept) + ("\n" if kept else ""))
PYEOF
    lw_say "🌊 Removed LinuxWave PATH entries from $SHARED_HOME/.bashrc" \
           "🌊 已从 $SHARED_HOME/.bashrc 删除 LinuxWave 的 PATH 行"
    fi
fi

# ========== 共享安装：删除专用用户（会连带删除家目录） ==========
remove_shared_user() {
    local uid err
    if lw_dry_run; then
        lw_plan "Would remove user '$SHARED_USER' and its home directory" \
                "将删除用户 '$SHARED_USER' 及其家目录"
        return 0
    fi
    uid=$(id -u "$SHARED_USER" 2> /dev/null)

    lw_say "🌊 Removing user '$SHARED_USER' (with sudo)..." "🌊 正在删除用户 '$SHARED_USER'（需要 sudo）……"
    # 该用户一旦建立过会话，systemd 会为其启动 user manager，
    # userdel 会以「用户当前被进程使用」拒绝删除。先把它停掉再删。
    sudo loginctl disable-linger "$SHARED_USER" > /dev/null 2>&1 || true
    sudo systemctl stop "user@$uid.service" > /dev/null 2>&1 || true

    if err=$(sudo userdel -r "$SHARED_USER" 2>&1); then
        lw_say "🌊 User '$SHARED_USER' removed." "🌊 用户 '$SHARED_USER' 已删除。"
        return 0
    fi

    lw_say_err "${RED_BOLD}🌊 Error: could not remove user '$SHARED_USER'.${RESET}" \
               "${RED_BOLD}🌊 错误：没能删除用户 '$SHARED_USER'。${RESET}"
    [ -n "$err" ] && lw_say_err "🌊 $err" ""
    lw_say_err "🌊 Something is still using that account. Check with:" \
               "🌊 还有进程在用这个账号。先看："
    lw_say_err "     ps -u $SHARED_USER" ""
    lw_say_err "🌊 Then remove it manually with:" "🌊 然后手工删掉："
    lw_say_err "     sudo systemctl stop user@$uid.service" ""
    lw_say_err "     sudo userdel -r $SHARED_USER" ""
    return 1
}

REMOVE_USER_FAILED=false
if [[ "$SHARED_DETECTED" == "true" ]] && id "$SHARED_USER" > /dev/null 2>&1; then
    if [[ "$CLI_REMOVE_USER" == "true" ]]; then
        echo ""
        lw_say "${RED_BOLD}🌊 --remove-user: deleting the '$SHARED_USER' account and its home directory.${RESET}" \
               "${RED_BOLD}🌊 --remove-user：正在删除 '$SHARED_USER' 账号及其家目录。${RESET}"
        remove_shared_user || REMOVE_USER_FAILED=true
    elif [[ "$CLI_FORCE" == "true" ]]; then
        echo ""
        lw_say "🌊 --force: keeping the '$SHARED_USER' user." \
               "🌊 --force：保留 '$SHARED_USER' 用户。"
        lw_say "🌊 Remove it later with:  sudo userdel -r $SHARED_USER" \
               "🌊 以后要删：sudo userdel -r $SHARED_USER"
        lw_say "🌊 Or run this script again with --remove-user." \
               "🌊 或者加 --remove-user 再跑一次本脚本。"
    else
        echo ""
        lw_say "${RED_BOLD}🌊 Warning: this was a shared install.${RESET}" \
               "${RED_BOLD}🌊 警告：这是一次共享安装。${RESET}"
        lw_say "🌊 Removing the '$SHARED_USER' account also deletes its home directory" \
               "🌊 删除 '$SHARED_USER' 账号会连带删掉它的家目录"
        lw_say "🌊 ($SHARED_HOME) and everything else stored in it, not just LinuxWave." \
               "🌊 （${SHARED_HOME}）以及里面的一切，不只是 LinuxWave。"
        lw_say "🌊 It is a dedicated account created for LinuxWave, so this is normally safe." \
               "🌊 那是为 LinuxWave 专门建的账号，所以通常安全。"
        echo ""
        lw_say "${RED_BOLD}Also remove the '$SHARED_USER' user? [y/N]${RESET}" \
               "${RED_BOLD}也要删除 '$SHARED_USER' 用户吗？[y/N]${RESET}"
        read -n 1 -r < /dev/tty
        echo
        if [[ "${REPLY,,}" == "y" ]]; then
            remove_shared_user || REMOVE_USER_FAILED=true
        else
            lw_say "🌊 Kept the '$SHARED_USER' user. Remove it later with:" \
                   "🌊 保留 '$SHARED_USER' 用户。以后要删："
            lw_say "     sudo userdel -r $SHARED_USER" ""
        fi
    fi
fi

echo ""
if lw_dry_run; then
    lw_plan "🌊 Dry run finished: nothing was removed." "🌊 试运行结束：什么都没删。"
else
    lw_say "🌊 LinuxWave has been uninstalled." "🌊 LinuxWave 已卸载。"
    lw_say "🌊 Please restart your terminal to apply changes." "🌊 请重启终端让改动生效。"
fi

# ========== 删除自身脚本 ==========
# 只有「脚本确实来自一个文件」时才有自己可删。用文档推荐的
# `/bin/bash -c "$(curl ...)"` 运行时，$0 是解释器路径（无参数）或 `--`（带参数），
# 直接 rm 会把 /bin/bash 删掉，所以这里逐条排除后再按内容确认一次。
if [[ -f "$0" && "$0" != "$BASH" && "$0" != --* ]] \
   && grep -q "LinuxWave Uninstaller" "$0" 2>/dev/null; then
    rm -f "$0"
fi

if [[ "$REMOVE_USER_FAILED" == "true" ]]; then
    exit 1
fi
exit 0
