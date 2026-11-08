#!/bin/bash

# dir_guard_test.sh
# 安装目录的白名单校验，以及两处「按路径递归改权限 / 删目录」的防护。
#
# 为什么单独测：装到系统目录时，install.sh 会
#
#   sudo chown -R root:root "$BASE_DIR"      # 非共享的系统级安装
#   rm -rf "$BASE_DIR"                       # 拒绝协议时的回滚
#
# 而 uninstall.sh 会把 config.json 里的 base_dir 直接交给 `sudo rm -rf`。
# 如果 BASE_DIR 是 /usr/local 这种「别的软件的家」，这两件事分别是**把整个系统
# 目录接管过来**和**删掉它**。旧版 validate_custom_dir 只挡了 `..`、控制字符、
# 非 ASCII、相对路径、`//` 和 `/` —— `--dir-option=5=/usr/local` 能一路通过。
#
# 只测纯函数与脚本结构：不跑安装、不联网、不需要 sandbox，所以任何机器上都能跑。
#
# 全程离线，秒级。

set -u
set +e

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
INSTALL_SH="$REPO_DIR/lib/install.sh"
UNINSTALL_SH="$REPO_DIR/lib/uninstall.sh"

if [[ ! -f "$INSTALL_SH" ]]; then
    echo -e "${RED_BOLD}🌊 Error: install.sh not found at $INSTALL_SH${RESET}"
    exit 1
fi

PASSED=0
FAILED=0

pass() { echo -e "${GREEN}🌊 PASS: $1${RESET}"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED_BOLD}🌊 FAIL: $1${RESET}"; FAILED=$((FAILED + 1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# 从 install.sh 里只抽这一个函数。整个文件的顶层会执行安装流程，不能 source。
extract() { sed -n "/^$1() {/,/^}/p" "$INSTALL_SH"; }

BODY="$(extract validate_custom_dir)"

if [[ -z "$BODY" ]]; then
    echo -e "${RED_BOLD}🌊 Error: 没能从 install.sh 抽出 validate_custom_dir${RESET}"
    exit 1
fi

# 校验函数依赖 $HOME 与几个颜色变量；颜色给空串即可，断言比对的是退出码。
probe() {
    bash -c 'RED_BOLD=""; YELLOW=""; RESET=""; source /dev/stdin <<< "$1"; validate_custom_dir "$2"' \
        _ "$BODY" "$1" >/dev/null 2>&1
}

expect_reject() {
    local dir="$1" label="${2:-$1}"
    if probe "$dir"; then
        fail "${label} 被放行了（应当拒绝）"
    else
        pass "${label} 被拒绝"
    fi
}

expect_accept() {
    local dir="$1" label="${2:-$1}"
    if probe "$dir"; then
        pass "${label} 被放行"
    else
        fail "${label} 被拒绝了（应当放行）"
    fi
}

echo "========== 1. 系统目录本身：一律拒绝 =========="

# 这些是「别的软件的家」。chown -R 到这里 = 接管别人的文件；
# rm -rf 到这里 = 删掉别人的软件。
for dir in /bin /sbin /usr /usr/bin /usr/sbin /usr/lib /usr/lib64 /usr/libexec \
           /usr/local /usr/share /opt /etc /var /tmp /boot /dev /proc /sys \
           /run /srv /mnt /media /root /home /lib /lib64; do
    expect_reject "$dir"
done

echo
echo "========== 2. 家目录本身：拒绝 =========="

expect_reject "$HOME" '$HOME'

echo
echo "========== 3. 系统目录的子目录：放行 =========="

# 按完全相等判、不用前缀，正是为了保住这几个默认选项。
expect_accept /opt/linuxwave
expect_accept /usr/local/linuxwave
expect_accept "$HOME/.local/linuxwave"

echo
echo "========== 4. 已存在且非空、又不是 LinuxWave 的目录：拒绝 =========="

mkdir -p "$WORK/someone-else"
touch "$WORK/someone-else/their-file"
expect_reject "$WORK/someone-else"

mkdir -p "$WORK/empty"
expect_accept "$WORK/empty"

# 已有的安装要能重装/升级 —— 判据是 lib/wave.py
mkdir -p "$WORK/linuxwave/lib"
touch "$WORK/linuxwave/lib/wave.py"
expect_accept "$WORK/linuxwave" "已有 LinuxWave 安装的目录"

echo
echo "========== 5. 原有校验不能丢 =========="

expect_reject "" "空路径"
expect_reject "/tmp/../etc" "路径穿越"
expect_reject "relative/path" "相对路径"
expect_reject "/" "根目录"
expect_reject "/tmp//double" "连续斜杠"

echo
echo "========== 6. 黑名单本身必须在（不能只靠「非空」兜底） =========="

# 第 1 组能过，可能只是因为那些目录恰好非空。空目录或不存在的系统目录只能靠
# 黑名单拦：`/opt` 在某些发行版上可能为空，`/usr/local` 也可能压根没有。
FLAT=$(printf '%s\n' "$BODY" | tr '\n' ' ' | tr -d '\\')
for dir in /usr /usr/local /opt /etc /bin /home /root; do
    if printf '%s' "$FLAT" | grep -qE "(^|[[:space:]])$dir([[:space:]]|$)"; then
        pass "黑名单包含 ${dir}"
    else
        fail "黑名单缺少 ${dir}（空目录时会被接管）"
    fi
done

echo
echo "========== 7. 安装树最终属主：非共享系统级安装归 root =========="

# 树在系统 PATH 上，若归安装者所有，任何以该用户身份运行的进程都能替换
# links/<名>，而它可能被别的用户、脚本甚至 root 执行 —— 本地提权。
if grep -q 'chown -R root:root "\$BASE_DIR"' "$INSTALL_SH"; then
    pass "非共享的系统级安装把树交给 root"
else
    fail "系统级安装仍然把树交给安装者"
fi

if grep -q 'chmod -R u+rwX,go+rX,go-w "\$BASE_DIR"' "$INSTALL_SH"; then
    pass "权限收敛成 755 语义"
else
    fail "权限没有收敛成 755 语义"
fi

# 顺序：交还必须在写 launcher 之后，否则本次安装自己就写不动了。
LAUNCHER_LINE=$(grep -n 'write_launcher "\$BASE_DIR"' "$INSTALL_SH" | tail -1 | cut -d: -f1)
ROOT_LINE=$(grep -n 'chown -R root:root "\$BASE_DIR"' "$INSTALL_SH" | tail -1 | cut -d: -f1)
if [[ -n "$LAUNCHER_LINE" && -n "$ROOT_LINE" && "$ROOT_LINE" -gt "$LAUNCHER_LINE" ]]; then
    pass "属主交还在写 launcher 之后（${LAUNCHER_LINE} < ${ROOT_LINE}）"
else
    fail "属主交还的位置不对（launcher=${LAUNCHER_LINE:-?}, root=${ROOT_LINE:-?}）"
fi

# 提示要能直接照抄：sudo 有自己的 PATH，只写 sudo wave install 是跑不通的。
if grep -q 'sudo \$BASE_DIR/lib/wave install' "$INSTALL_SH"; then
    pass "提示里给出可照抄的 sudo 命令"
else
    fail "提示里没有可照抄的 sudo 命令"
fi

# 共享安装不受这次改动影响
if grep -q 'chown -R "\$SHARED_USER:\$SHARED_USER" "\$BASE_DIR"' "$INSTALL_SH"; then
    pass "共享安装仍然交给 \$SHARED_USER"
else
    fail "共享安装的属主规则被改掉了"
fi

# 运行时（不是安装脚本）要能在下载之前就发现写不进去，并给出下一步
PY_INSTALLER="$REPO_DIR/pkg/pkginstaller.py"
if grep -q 'ensure_install_writable()' "$PY_INSTALLER" && \
   grep -q 'print_write_permission_advice' "$PY_INSTALLER"; then
    pass "运行时检查安装树可写性并给出提示"
else
    fail "运行时不检查可写性，只读树会在下载步骤报 Permission denied"
fi

echo
echo "========== 8. uninstall 只删真正的 LinuxWave 树 =========="

# base_dir 来自 config.json，而用户级配置对任何以该用户身份运行的进程都可写。
if grep -q 'skip_reason' "$UNINSTALL_SH" && grep -q 'lib/wave.py' "$UNINSTALL_SH"; then
    pass "uninstall 有「是不是 LinuxWave 树」的判据"
else
    fail "uninstall 仍然直接 rm -rf 配置里的 base_dir"
fi

# 必须跑副本，而且每次都要重新拷：卸载脚本收尾时会删掉自己（$0）。
run_uninstall() {   # run_uninstall <测试根>
    local copy="$WORK/uninstall-copy.sh"
    cp "$UNINSTALL_SH" "$copy"
    PATH="$WORK/bin:$PATH" SUDO_LOG="$SUDO_LOG" LINUXWAVE_TEST="$1" \
        bash "$copy" --force 2>&1
}

mkdir -p "$WORK/bin"
SUDO_LOG="$WORK/sudo.log"
cat > "$WORK/bin/sudo" <<'SHIM'
#!/bin/bash
# 记录调用；chown/chmod 只记录不执行（测试里没有 root），rm 照常执行。
printf '%s\n' "$*" >> "$SUDO_LOG"
case "$1" in
    chown|chmod) exit 0 ;;
esac
exec "$@"
SHIM
chmod 755 "$WORK/bin/sudo"

UBOX="$WORK/uninstall"
mkdir -p "$UBOX/etc/linuxwave_config"
DECOY="$UBOX/usr/local"
mkdir -p "$DECOY" && echo keep > "$DECOY/precious.txt"
REAL="$UBOX/opt/linuxwave"
mkdir -p "$REAL/lib" && echo x > "$REAL/lib/wave.py"

printf '{"base_dir": "%s"}\n' "$DECOY" > "$UBOX/etc/linuxwave_config/config.json"
OUT=$(run_uninstall "$UBOX")
if [[ -f "$DECOY/precious.txt" ]]; then
    pass "非 LinuxWave 目录没被删"
else
    fail "非 LinuxWave 目录被删掉了"
fi
if [[ "$OUT" == *"Skipping"* && "$OUT" == *"not a LinuxWave install"* ]]; then
    pass "跳过时点名了原因"
else
    fail "跳过了却没点名原因（实际：${OUT:0:200}）"
fi

# 系统目录那一条没法在真实路径上试（不能往 /usr/local 里放东西），
# 所以把 skip_reason 抽出来直接问它。
SKIP_BODY="$(sed -n '/^skip_reason() {/,/^}/p' "$UNINSTALL_SH")"
if [[ -z "$SKIP_BODY" ]]; then
    fail "没能从 uninstall.sh 抽出 skip_reason"
else
    ask_reason() { bash -c 'source /dev/stdin <<< "$1"; skip_reason "$2"' _ "$SKIP_BODY" "$1" 2>/dev/null; }
    if [[ "$(ask_reason /usr/local)" == "a system directory" ]]; then
        pass "/usr/local 的理由是「系统目录」"
    else
        fail "/usr/local 的理由不对：$(ask_reason /usr/local)"
    fi
    if [[ "$(ask_reason /opt)" == "a system directory" ]]; then
        pass "/opt 的理由是「系统目录」"
    else
        fail "/opt 的理由不对：$(ask_reason /opt)"
    fi
    # 子目录不能被「系统目录」这条误伤（不存在时会被「不是安装树」挡住，那是另一回事）
    if [[ "$(ask_reason /opt/linuxwave)" != "a system directory" ]]; then
        pass "/opt/linuxwave 不被当成系统目录"
    else
        fail "/opt/linuxwave 被当成系统目录拦掉了"
    fi
    # 真正存在的安装树必须放行
    if [[ "$(ask_reason "$WORK/linuxwave")" == "" ]]; then
        pass "真实的安装树不被拦"
    else
        fail "真实的安装树被拦了：$(ask_reason "$WORK/linuxwave")"
    fi
    if [[ "$(ask_reason relative/path)" == "not an absolute path" ]]; then
        pass "相对路径的理由正确"
    else
        fail "相对路径的理由不对：$(ask_reason relative/path)"
    fi
fi

mkdir -p "$UBOX/etc/linuxwave_config"
printf '{"base_dir": "%s"}\n' "$REAL" > "$UBOX/etc/linuxwave_config/config.json"
run_uninstall "$UBOX" >/dev/null 2>&1
if [[ ! -d "$REAL" ]]; then
    pass "真正的 LinuxWave 树照常卸载"
else
    fail "真正的 LinuxWave 树没被删掉（正常卸载被挡住了）"
fi

# 家目录本身永远不能删，哪怕它里面碰巧有 lib/wave.py。
# 沙箱里的家目录是 "$测试根$HOME"。
HOME_TREE="$UBOX$HOME"
mkdir -p "$HOME_TREE/lib" && echo x > "$HOME_TREE/lib/wave.py"
mkdir -p "$UBOX/etc/linuxwave_config"
printf '{"base_dir": "%s"}\n' "$HOME_TREE" > "$UBOX/etc/linuxwave_config/config.json"
HOME_OUT=$(run_uninstall "$UBOX")
if [[ -d "$HOME_TREE/lib" ]]; then
    pass "家目录本身不会被当成安装树删掉"
else
    fail "家目录被当安装树删掉了"
fi
if [[ "$HOME_OUT" == *"your home directory"* ]]; then
    pass "家目录被拒时说的是「家目录」"
else
    fail "家目录被拒的理由不对（实际：${HOME_OUT:0:200}）"
fi

echo
echo "=========================================="
echo -e "🌊 Passed: $PASSED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="

[[ "$FAILED" -eq 0 ]] || exit 1
echo -e "${GREEN}🌊 All directory-guard tests passed${RESET}"
