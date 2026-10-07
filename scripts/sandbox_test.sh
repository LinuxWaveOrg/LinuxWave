#!/bin/bash

# sandbox_test.sh
# 安装器 / 卸载器的端到端回归，全程跑在**隔离的命名空间**里：
# 宿主的 /etc、/home、/opt、/usr/local、/root、/var、/srv 一个字节都不会被写。
#
# 做法：
#   1. 在临时目录里搭一份离线镜像，只把 BASE_URL / CONFIGDATA_URL 两行改成
#      file:// 路径（也就是 .templates/SPECIAL/INSTALL-EXAMPLE.md 里的离线手法），
#      因此整个过程**不需要网络**；
#   2. unshare -rm 起一个用户 + 挂载命名空间，把上面那些系统目录换成影子副本；
#   3. 在命名空间里跑安装 / 卸载的各种路径，逐条断言。
#
# 覆盖：各安装目录选项 → 配置落位 → PATH 写入 / 协议拒绝后的完整回滚 /
#       卸载的确认语义（无终端、y、n、--force、--remove-user）/
#       安装中途失败时的指引 / 单文件下载重试 / 菜单无效输入不静默换目录 /
#       --silent 自动应答菜单 / 共用安装树不可写时的提示 / Ctrl-C 不打印 traceback /
#       Ctrl-C 停在重试提示上时不误报成下载失败 / 卸载器自删 / 软链接回归。
#
# 前置条件：util-linux 的 unshare（内核需允许非特权用户命名空间）、curl、python3，
# 且必须以**非 root** 用户运行（要用 unshare -r 把自己的 uid 映射成命名空间里的 0）。
#
# 已知限制：发行版一般没装 newuidmap，一个命名空间里只能映射调用者自己的那个 uid，
# 所以选项 4 没法真的建出一个不同 uid 的账号。这里改成「预置一个已存在的 linuxwave
# 账号，直接复用被映射的 uid」——除了 useradd 那一行，其余流程都真实执行。
# 同理，sudo / loginctl / systemctl 用替身：命名空间内本就是 uid 0，且真去调
# loginctl 会碰到宿主 systemd 的状态。

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'

PASSED=0
FAILED=0
SKIPPED=0

pass() {
    echo -e "${GREEN}🌊 PASS: $1${RESET}"
    PASSED=$((PASSED + 1))
}

fail() {
    echo -e "${RED_BOLD}🌊 FAIL: $1${RESET}"
    FAILED=$((FAILED + 1))
}

skip() {
    echo -e "${YELLOW}🌊 SKIP: $1${RESET}"
    SKIPPED=$((SKIPPED + 1))
}

# check <描述> <实际> <期望>
check() {
    if [[ "$2" == "$3" ]]; then
        pass "$1"
    else
        fail "$1 (expected '$3', got '$2')"
    fi
}

# contains <描述> <文件> <关键字>
contains() {
    if grep -qF -- "$3" "$2" 2>/dev/null; then
        pass "$1"
    else
        fail "$1 ('$3' not found in output)"
    fi
}

# count_in <文件> <关键字> —— grep -c 无匹配时会同时输出 0 并返回 1，
# 直接接 `|| echo 0` 会拼出两行 "0"，所以统一走这里
count_in() {
    if [[ ! -f "$1" ]]; then
        echo 0
        return 0
    fi
    grep -cF -- "$2" "$1" 2>/dev/null || true
}


# ==========================================================
# 内层：已经在命名空间里，跑场景
# ==========================================================

install_run() {
    /bin/bash -c "$(cat "$OFFLINE_INSTALLER")" -- "$@" > "$OUT" 2>&1
    return $?
}

uninstall_run() {
    /bin/bash -c "$(cat "$SANDBOX_DIR/source-uninstall.sh")" -- "$@" > "$OUT" 2>&1
    return $?
}

# 卸载器成功时会自删，所以每次要以文件方式跑之前都重新放一份
uninstall_copy_fresh() {
    cp "$SANDBOX_DIR/source-uninstall.sh" /root/lw-uninstall.sh
}

# 清掉上一场景留下的安装痕迹
reset_state() {
    umount /srv/ro-lw 2>/dev/null || true
    rm -rf /root/.local/linuxwave /root/.config/linuxwave_config
    rm -rf /opt/linuxwave /usr/local/linuxwave /srv/mylw /etc/linuxwave_config
    rm -rf /home/linuxwave/.linuxwave /home/linuxwave/.config/linuxwave_config
    rm -rf /srv/ro-lw
    rm -f /root/.bashrc /root/.profile /root/.zshrc
    rm -f /home/linuxwave/.bashrc /root/lw-uninstall.sh
}

tree_version() {
    python3 -c "import json,sys;print(json.load(open('$1')).get('version',''))" 2>/dev/null
}

tree_base_dir() {
    python3 -c "import json,sys;print(json.load(open('$1')).get('base_dir',''))" 2>/dev/null
}

scenario_install_dirs() {
    echo ""
    echo "========== 1. 各安装目录选项（--silent + --dir-option） =========="

    local opt_arg rc
    while read -r opt dir cfg display; do
        reset_state
        opt_arg="--dir-option=$opt"
        # 自定义目录要由 --dir-option=5=<路径> 传入
        [[ "$opt" == "5" ]] && opt_arg="--dir-option=5=$dir"
        install_run --silent "$opt_arg"
        check "--dir-option=$opt 安装成功" "$?" "0"
        check "--dir-option=$opt 落到 $display" "$([[ -d "$dir" ]] && echo yes || echo no)" "yes"
        check "--dir-option=$opt 文件数 20" "$(find "$dir" -type f 2>/dev/null | wc -l | tr -d ' ')" "20"
        check "--dir-option=$opt 配置在 $cfg" "$(tree_base_dir "$cfg/config.json")" "$dir"
        check "--dir-option=$opt 入口可执行" "$([[ -x "$dir/lib/wave" ]] && echo yes || echo no)" "yes"
        check "--dir-option=$opt VERSION.json 版本与脚本一致" \
            "$(tree_version "$cfg/VERSION.json")" "$(sed -n 's/^LINUXWAVE_VERSION="\(.*\)"$/\1/p' "$OFFLINE_INSTALLER")"
        check "--dir-option=$opt 写入了 PATH" "$(count_in /root/.bashrc "$dir")" "1"
    done <<< "1 /root/.local/linuxwave /root/.config/linuxwave_config ~/.local/linuxwave
2 /opt/linuxwave /etc/linuxwave_config /opt/linuxwave
3 /usr/local/linuxwave /etc/linuxwave_config /usr/local/linuxwave
5 /srv/mylw /etc/linuxwave_config /srv/mylw"

    # 用户级安装不该碰 /etc
    reset_state
    install_run --silent --dir-option=1
    rc=$?
    check "用户级安装成功" "$rc" "0"
    check "用户级安装不写 /etc/linuxwave_config" \
        "$([[ -e /etc/linuxwave_config ]] && echo yes || echo no)" "no"
}

scenario_cli_errors() {
    echo ""
    echo "========== 2. 参数校验 =========="

    reset_state
    install_run --silent --dir-option=5
    check "--silent 下 --dir-option=5 缺路径应报错" "$?" "1"

    reset_state
    install_run --silent --dir-option=9
    check "--dir-option=9 越界应报错" "$?" "1"

    reset_state
    install_run --bogus-flag
    check "未知参数应报错" "$?" "1"

    reset_state
    install_run --silent --dir-option=5=../evil
    check "--dir-option 拒绝路径穿越" "$?" "1"
}

scenario_agreement() {
    echo ""
    echo "========== 3. 许可协议：顺序与拒绝后的回滚 =========="

    reset_state
    install_run --silent --dir-option=1
    local n_agree n_done
    n_agree=$(grep -n "Please read the agreement" "$OUT" | head -1 | cut -d: -f1)
    n_done=$(grep -n "Installation complete" "$OUT" | head -1 | cut -d: -f1)
    # 先宣布「安装完成」再问协议，不同意的用户会看到自相矛盾的输出
    check "协议询问在「安装完成」之前" \
        "$([[ -n "$n_agree" && -n "$n_done" && "$n_agree" -lt "$n_done" ]] && echo yes || echo no)" "yes"

    if ! command -v script > /dev/null 2>&1; then
        skip "拒绝协议的回滚断言（缺 script，无法提供 pty）"
        return
    fi

    reset_state
    printf '1\nn\n' | script -qec "/bin/bash $OFFLINE_INSTALLER" /dev/null > "$OUT" 2>&1
    check "拒绝协议后退出码非 0" "$?" "1"
    check "拒绝协议后安装树被回滚" "$([[ -e /root/.local/linuxwave ]] && echo yes || echo no)" "no"
    check "拒绝协议后配置目录被回滚" "$([[ -e /root/.config/linuxwave_config ]] && echo yes || echo no)" "no"
    # 否则会留下一个指向已删除目录的 PATH
    check "拒绝协议后 rc 里的 PATH 被回滚" "$(count_in /root/.bashrc "linuxwave")" "0"
}

scenario_mid_failure() {
    echo ""
    echo "========== 4. 安装中途失败：给出指引且不误删 =========="

    local victim="$MIRROR_BASE/lib/help.py"
    local rc
    mv "$victim" "$victim.off"
    reset_state
    install_run --silent --dir-option=1
    rc=$?
    check "中途失败时退出码非 0" "$([[ "$rc" -ne 0 ]] && echo yes || echo no)" "yes"
    contains "失败时说明安装未完成" "$OUT" "Installation did not finish"
    contains "失败时给出实际路径" "$OUT" "/root/.local/linuxwave"
    contains "失败时说明没有删除任何东西" "$OUT" "Nothing was removed"
    contains "失败时给出重试指引" "$OUT" "run the installer again"
    check "失败时不自动删除配置（避免毁掉可用安装）" \
        "$([[ -d /root/.config/linuxwave_config ]] && echo yes || echo no)" "yes"
    mv "$victim.off" "$victim"

    reset_state
    install_run --silent --dir-option=1
    check "修好后重跑可自愈" "$?" "0"
    check "自愈后文件数 20" "$(find /root/.local/linuxwave -type f | wc -l | tr -d ' ')" "20"
    check "正常安装不误报失败指引" "$(count_in "$OUT" "did not finish")" "0"
}

scenario_uninstall_confirm() {
    echo ""
    echo "========== 5. 卸载确认语义 =========="

    # 5.1 无终端：必须拒绝，不能把 EOF 当成同意
    reset_state
    install_run --silent --dir-option=1
    uninstall_copy_fresh
    /bin/bash /root/lw-uninstall.sh < /dev/null > "$OUT" 2>&1
    check "无终端时退出码非 0" "$([[ "$?" -ne 0 ]] && echo yes || echo no)" "yes"
    check "无终端时什么都不删" \
        "$([[ -e /root/.local/linuxwave ]] && echo yes || echo no)" "yes"
    contains "无终端时提示改用 --force" "$OUT" "--force"

    if command -v script > /dev/null 2>&1; then
        # 5.2 回答 n → 取消
        install_run --silent --dir-option=1
        uninstall_copy_fresh
        printf 'n' | script -qec "/bin/bash /root/lw-uninstall.sh" /dev/null > "$OUT" 2>&1
        check "答 n 时取消卸载" "$([[ -e /root/.local/linuxwave ]] && echo yes || echo no)" "yes"
        contains "答 n 时输出已取消" "$OUT" "Uninstall cancelled"

        # 5.3 回答 y → 删除
        install_run --silent --dir-option=1
        uninstall_copy_fresh
        printf 'y' | script -qec "/bin/bash /root/lw-uninstall.sh" /dev/null > "$OUT" 2>&1
        check "答 y 时卸载完成" "$([[ -e /root/.local/linuxwave ]] && echo no || echo yes)" "yes"
    else
        skip "答 n / 答 y 的断言（缺 script，无法提供 pty）"
    fi

    # 5.4 --force：无需终端
    reset_state
    install_run --silent --dir-option=1
    uninstall_run --force
    check "--force 无人值守卸载成功" "$?" "0"
    check "--force 后安装树已删" "$([[ -e /root/.local/linuxwave ]] && echo yes || echo no)" "no"
    check "--force 后配置已删" "$([[ -e /root/.config/linuxwave_config ]] && echo yes || echo no)" "no"
    check "--force 后 rc 里的 PATH 已清" "$(count_in /root/.bashrc "linuxwave")" "0"
}

scenario_self_delete() {
    echo ""
    echo "========== 6. 卸载器自删（\$0 的取值） =========="

    reset_state
    install_run --silent --dir-option=1
    check "安装成功（自删场景前置）" "$?" "0"
    uninstall_copy_fresh
    /bin/bash /root/lw-uninstall.sh --force > "$OUT" 2>&1
    check "以文件方式运行后自删" "$([[ -e /root/lw-uninstall.sh ]] && echo yes || echo no)" "no"

    # 用 /bin/bash -c 运行时 $0 是解释器自身；曾经这里会把 /bin/bash 删掉
    reset_state
    install_run --silent --dir-option=1
    uninstall_run --force
    local rc=$?
    check "以 /bin/bash -c 运行卸载成功" "$rc" "0"
    check "以 /bin/bash -c 运行不误删解释器" "$([[ -x /bin/bash ]] && echo yes || echo no)" "yes"
}

scenario_shared() {
    echo ""
    echo "========== 7. 共享安装（选项 4）与账号处理 =========="

    reset_state
    install_run --silent --dir-option=4
    check "共享安装成功" "$?" "0"
    check "共享安装树就位" "$([[ -d /home/linuxwave/.linuxwave ]] && echo yes || echo no)" "yes"
    check "共享安装配置在 /etc/linuxwave_config" \
        "$(tree_base_dir /etc/linuxwave_config/config.json)" "/home/linuxwave/.linuxwave"
    # 共享用户的 rc 不存在时会建出来，否则该账号反而跑不了 wave
    check "共享用户的 rc 拿到 PATH" \
        "$(count_in /home/linuxwave/.bashrc "linuxwave/.linuxwave")" "1"
    check "调用者的 rc 也拿到 PATH" "$(count_in /root/.bashrc "linuxwave/.linuxwave")" "1"
    check "家目录放开到 755" "$(stat -c '%a' /home/linuxwave)" "755"

    uninstall_run --force
    check "共享卸载成功" "$?" "0"
    check "共享卸载删掉安装树" "$([[ -e /home/linuxwave/.linuxwave ]] && echo yes || echo no)" "no"
    check "共享卸载删掉 /etc 配置" "$([[ -e /etc/linuxwave_config ]] && echo yes || echo no)" "no"
    check "共享卸载清掉共享用户的 PATH" \
        "$(count_in /home/linuxwave/.bashrc "linuxwave/.linuxwave")" "0"
    check "--force 保留 linuxwave 账号" "$(id linuxwave > /dev/null 2>&1 && echo yes || echo no)" "yes"

    # 配置已被上一次卸载清掉、只剩共享安装树的场景（2.5.2 修过这里）
    reset_state
    install_run --silent --dir-option=4
    rm -rf /etc/linuxwave_config
    mkdir -p /home/linuxwave/.config/linuxwave_config
    echo '{"base_dir":"/home/linuxwave/.linuxwave"}' > /home/linuxwave/.config/linuxwave_config/config.json
    uninstall_run --force
    check "只剩共享树时仍能识别并清理" \
        "$([[ -e /home/linuxwave/.linuxwave ]] && echo yes || echo no)" "no"
    check "顺手清掉共享用户的用户级配置" \
        "$([[ -e /home/linuxwave/.config/linuxwave_config ]] && echo yes || echo no)" "no"

    # --remove-user：调用序列 + 失败时不谎报
    reset_state
    install_run --silent --dir-option=4
    rm -f /root/calls.txt
    uninstall_run --force --remove-user
    check "userdel 失败时退出码为 1" "$?" "1"
    contains "失败时提示账号仍被占用" "$OUT" "still using"
    check "先停 user manager 再 userdel" \
        "$(sed -n '1p' /root/calls.txt 2>/dev/null | grep -c "^loginctl disable-linger")" "1"
    check "随后停 user@<uid> 服务" \
        "$(sed -n '2p' /root/calls.txt 2>/dev/null | grep -c "^systemctl stop user@")" "1"
    # 沙箱里 userdel 必然失败（真正要删的账号是命名空间里唯一被映射的那个 uid），
    # 所以这里只断言「如实报告」，不断言删除成功
    check "失败时不谎报已删除" "$(count_in "$OUT" "User 'linuxwave' removed")" "0"
}

scenario_link_regression() {
    echo ""
    echo "========== 8. 软链接回归（复用 link_test.sh） =========="

    reset_state
    install_run --silent --dir-option=1
    if [[ ! -f "$MIRROR_BASE/scripts/link_test.sh" ]]; then
        skip "link_test.sh 不在镜像里"
        return
    fi
    (
        cd "$MIRROR_BASE"
        bash scripts/link_test.sh
    ) > "$OUT" 2>&1
    check "link_test.sh 全部通过" "$(count_in "$OUT" "FAIL")" "0"
    check "link_test.sh 有跑过断言" "$([[ "$(count_in "$OUT" "PASS")" -gt 0 ]] && echo yes || echo no)" "yes"
}

scenario_install_menu() {
    echo ""
    echo "========== 9. 安装目录菜单与 --silent =========="

    if command -v script > /dev/null 2>&1; then
        # 9.1 无效输入：绝不能静默装到别的目录去（用户明确没选那里）
        reset_state
        printf '9\n9\n9\n' | script -qec "/bin/bash $OFFLINE_INSTALLER" /dev/null > "$OUT" 2>&1
        local rc=$?
        check "连续无效输入后退出码非 0" "$([[ "$rc" -ne 0 ]] && echo yes || echo no)" "yes"
        contains "无效输入被明确指出" "$OUT" "is not one of 1-5"
        contains "放弃时说明什么都没装" "$OUT" "Nothing was installed"
        check "无效输入没有装到任何目录" \
            "$([[ -e /root/.local/linuxwave || -e /opt/linuxwave || -e /usr/local/linuxwave ]] && echo yes || echo no)" "no"
        check "无效输入时配置也没留下" \
            "$([[ -e /root/.config/linuxwave_config || -e /etc/linuxwave_config ]] && echo yes || echo no)" "no"

        # 9.2 有效输入照常工作（菜单 → 协议）
        reset_state
        printf '2\ny\n' | script -qec "/bin/bash $OFFLINE_INSTALLER" /dev/null > "$OUT" 2>&1
        check "菜单选 2 能装成功" "$([[ -d /opt/linuxwave ]] && echo yes || echo no)" "yes"
    else
        skip "菜单场景（缺 script，无法提供 pty）"
    fi

    # 9.3 --silent 单独使用：按 README 承诺自动应答菜单，且必须说出来用了哪个默认值
    reset_state
    install_run --silent
    check "--silent 单独使用能装成功" "$?" "0"
    check "--silent 不打印菜单" "$(count_in "$OUT" "Where do you want to install")" "0"
    contains "--silent 说明使用了默认目录" "$OUT" "using the default"
    check "--silent 装到默认目录" "$([[ -d /root/.local/linuxwave ]] && echo yes || echo no)" "yes"
    check "--silent 不再泄漏 /dev/tty 原始报错" "$(count_in "$OUT" "No such device")" "0"
}

scenario_download_retry() {
    echo ""
    echo "========== 10. 单文件下载重试 =========="

    local victim="$MIRROR_BASE/lib/help.py"
    local rc

    # 10.1 文件短暂缺失（模拟传输被重置）：重试应能自愈，用户不必手工重跑
    reset_state
    mv "$victim" "$victim.hold"
    ( sleep 2; mv "$victim.hold" "$victim" ) &
    install_run --silent --dir-option=1
    rc=$?
    wait
    check "短暂失败后重试成功" "$rc" "0"
    contains "打印了重试提示" "$OUT" "Retrying lib/help.py"
    check "自愈后 20 个文件齐备" "$(find /root/.local/linuxwave -type f | wc -l | tr -d ' ')" "20"
    # 自愈那次失败发生在 if 条件里，ERR 陷阱不该开火——
    # 否则一次已经自己恢复的抖动会留下「未完成」的误导说明
    check "自愈后不谎报未完成" "$(count_in "$OUT" "did not finish")" "0"

    # 10.2 一直失败：重试到底后明确报错，不谎报成功
    reset_state
    mv "$victim" "$victim.hold"
    install_run --silent --dir-option=1
    rc=$?
    check "持续失败后退出码非 0" "$([[ "$rc" -ne 0 ]] && echo yes || echo no)" "yes"
    contains "说明尝试了几次" "$OUT" "after 5 attempts"
    contains "给出未完成的指引" "$OUT" "Installation did not finish"
    mv "$victim.hold" "$victim"
}

scenario_write_permission() {
    echo ""
    echo "========== 11. 共用安装树的写入权限提示 =========="

    # 用一个只读挂载来真实复现「树属于别人、自己写不进去」——
    # 只读挂载连 uid 0 也会被判为不可写，因此在沙箱里能诚实测试。
    reset_state
    install_run --silent --dir-option=1
    check "准备阶段安装到默认目录" "$([[ -x /root/.local/linuxwave/lib/wave ]] && echo yes || echo no)" "yes"

    mkdir -p /srv/ro-lw/linuxwave
    if ! mount -t tmpfs tmpfs /srv/ro-lw 2>/dev/null; then
        skip "写入权限场景（无法挂载 tmpfs）"
        return
    fi
    cp -a /root/.local/linuxwave/. /srv/ro-lw/linuxwave/
    echo '{"base_dir":"/srv/ro-lw/linuxwave"}' > /root/.config/linuxwave_config/config.json
    if ! mount -t tmpfs -o remount,ro tmpfs /srv/ro-lw 2>/dev/null; then
        skip "写入权限场景（无法 remount 成只读）"
        umount /srv/ro-lw 2>/dev/null || true
        return
    fi

    /srv/ro-lw/linuxwave/lib/wave install jq > "$OUT" 2>&1
    local rc=$?
    check "不可写时退出码为 1" "$rc" "1"
    contains "指出没有写入权限" "$OUT" "No write permission"
    contains "给出可执行的 sudo 全路径命令" "$OUT" "sudo /srv/ro-lw/linuxwave/lib/wave install"
    # 关键：必须在联网取版本之前就失败，而不是下载到一半才炸
    check "在取版本信息之前就失败" "$(count_in "$OUT" "Fetching version info")" "0"
    check "不再抛原始 errno" "$(count_in "$OUT" "[Errno 13]")" "0"

    # 11.2 安装器的共用提示也要给出可用命令（sudo wave 因 secure_path 必然找不到）
    reset_state
    install_run --silent --dir-option=4
    check "共用安装成功" "$?" "0"
    contains "共用提示给出 sudo 全路径命令" "$OUT" "sudo /home/linuxwave/.linuxwave/lib/wave install"
}

scenario_interrupt() {
    echo ""
    echo "========== 12. Ctrl-C 不再打印 traceback =========="

    reset_state
    install_run --silent --dir-option=1
    local W="/root/.local/linuxwave/lib/wave"

    # 用本地「挂起」代理让下载稳定地卡在读取上：接受连接但永不回应。
    # 不用黑洞地址——它在不同机器上可能立即失败而不是挂起，那样进程会在
    # 发 SIGINT 之前就退出，测不到想测的路径。
    #
    # 端口交给内核挑（bind 到 0）再经文件回传：写死端口会撞上开发机上别的
    # 进程，代理起不来时 requests 会改走直连，测出来的就不是这条路径了。
    local PORT_FILE="$SANDBOX_DIR/proxy_port"
    rm -f "$PORT_FILE"
    python3 - "$PORT_FILE" << 'PY' &
import socket
import sys

server = socket.socket()
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", 0))
server.listen(8)
with open(sys.argv[1], "w") as handle:
    handle.write(str(server.getsockname()[1]))

held = []
while True:
    conn, _ = server.accept()
    held.append(conn)
PY
    local proxy_pid=$!

    # 起始后必须确认真的在听，否则立刻收摊——不能拿「代理没起来」的结果当通过
    local waited=0
    while [[ ! -s "$PORT_FILE" && $waited -lt 50 ]]; do
        sleep 0.2
        waited=$((waited + 1))
    done
    if [[ ! -s "$PORT_FILE" ]]; then
        kill "$proxy_pid" 2> /dev/null || true
        wait "$proxy_pid" 2> /dev/null || true
        fail "Ctrl-C 场景：本地代理无法启动，无法复现传输中打断"
        return
    fi
    local proxy_url="http://127.0.0.1:$(< "$PORT_FILE")"

    # 带上 @版本号 跳过「取最新版本」这一步，尽快走到下载。
    #
    # 注意：元数据是几个小文件，这台机器上 raw.githubusercontent 抖动很厉害，
    # 若在按 Ctrl-C 之前进程就已经退出，说明这一轮根本没走到下载阶段——
    # 那种情况如实记为 SKIP，不能算通过，也不能算失败。
    local attempt rc reached=false
    for attempt in 1 2 3 4 5; do
        : > "$OUT"
        # 必须开 job control：非交互 shell 的后台任务会把 SIGINT 设成 SIG_IGN，
        # python 继承到 SIG_IGN 就不会装 default_int_handler，kill -INT 完全无效，
        # 进程只会一直等到 requests 自己超时。set -m 让子进程回到默认处置，
        # 这也正是真实终端里 Ctrl-C 生效的前提。
        set -m
        "$W" install jq@1.8.2 --proxy "$proxy_url" > "$OUT" 2>&1 &
        local pid=$!
        set +m
        sleep 4
        if ! kill -0 "$pid" 2> /dev/null; then
            wait "$pid" 2> /dev/null
            continue
        fi
        reached=true
        kill -INT "$pid" 2> /dev/null
        wait "$pid"
        rc=$?
        break
    done

    kill "$proxy_pid" 2> /dev/null || true
    wait "$proxy_pid" 2> /dev/null || true

    if [[ "$reached" != "true" ]]; then
        skip "Ctrl-C 场景（网络抖动，未能走到下载阶段）"
        return
    fi

    check "Ctrl-C 后退出码为 130" "$rc" "130"
    contains "给出简短的中止提示" "$OUT" "Interrupted"
    check "输出中没有 Traceback" "$(count_in "$OUT" "Traceback")" "0"
    check "没有打印调用栈帧" "$(count_in "$OUT" 'File "')" "0"
    # 打断不该被说成「下载失败」
    check "没有把它说成下载失败" "$(count_in "$OUT" "Failed to download package")" "0"

    scenario_interrupt_at_prompt
}

# Ctrl-C 停在「Do you want to retry?」提示上。
#
# 这条路径和上面那条不同：异常是从 input() 里抛出来的，最容易被顺手写成
# 「用户不想重试」，于是把「打断」谎报成「下载失败」。
#
# 真实网络里要走到这个提示，得先让元数据下载成功、只有包文件那一步失败，
# 而元数据来自 api.github.com / raw.githubusercontent.com——离线又确定地做不到。
# 所以这里直接调用真正下载用的那个函数，只给它一个真实的失败：本机一个
# 没人监听的端口。requests 抛出来的就是货真价实的 ConnectionError，
# 走的是和线上完全一样的那条 except 分支，只是不必经过网络。
scenario_interrupt_at_prompt() {
    local OUT2="$SANDBOX_DIR/output-prompt.txt"
    local FIFO="$SANDBOX_DIR/stdin.fifo"
    local DRIVER="$SANDBOX_DIR/retry_prompt_driver.py"
    local TREE
    TREE="$(dirname "$(dirname "$W")")"
    rm -f "$FIFO"
    : > "$OUT2"

    cat > "$DRIVER" << 'PY'
import pathlib
import sys

import pkginstaller

config = {
    "skip_ssl_verify": False,
    "proxy": None,
    "resume": False,
    "limit_rate": 0,
    "verbose": False,
}

try:
    pkginstaller.download_file(
        "http://127.0.0.1:1/victim.bin",
        pathlib.Path(sys.argv[1]),
        config,
        "",
        "jq",
    )
except KeyboardInterrupt:
    # 提示那里若把它吞掉，就走不到这里，会径直打印「下载失败」
    print("LW_INTERRUPT_PROPAGATED")
    sys.exit(130)

print("LW_INTERRUPT_SWALLOWED")
sys.exit(3)
PY

    # 这个 FIFO 只用来把 stdin 撑住不 EOF，不会往里写任何东西
    mkfifo "$FIFO"
    sleep 120 > "$FIFO" &
    local holder_pid=$!

    set -m
    PYTHONPATH="$TREE/lib:$TREE/pkg:$TREE/surfboard" \
        python3 "$DRIVER" "$SANDBOX_DIR/victim.bin" < "$FIFO" > "$OUT2" 2>&1 &
    local pid=$!
    set +m

    local waited=0
    while [[ $waited -lt 50 ]] && ! grep -qF "Do you want to retry?" "$OUT2" 2> /dev/null; do
        sleep 0.2
        waited=$((waited + 1))
    done

    if ! grep -qF "Do you want to retry?" "$OUT2" 2> /dev/null; then
        kill -INT "$pid" 2> /dev/null
        wait "$pid"
        local early_rc=$?
        kill "$holder_pid" 2> /dev/null
        wait "$holder_pid" 2> /dev/null
        rm -f "$FIFO" "$DRIVER"
        fail "重试提示处 Ctrl-C：未能走到重试提示（退出码 $early_rc），输出："
        sed 's/^/    | /' "$OUT2" >&2
        return
    fi

    kill -INT "$pid" 2> /dev/null
    wait "$pid"
    local rc=$?

    kill "$holder_pid" 2> /dev/null
    wait "$holder_pid" 2> /dev/null
    rm -f "$FIFO" "$DRIVER"

    check "重试提示处 Ctrl-C 后退出码为 130" "$rc" "130"
    contains "重试提示处 KeyboardInterrupt 被原样抛出" "$OUT2" "LW_INTERRUPT_PROPAGATED"
    check "重试提示处没有 Traceback" "$(count_in "$OUT2" "Traceback")" "0"
    # 关键：用户按的是 Ctrl-C，不是「不重试」
    check "重试提示处没有说成下载失败" "$(count_in "$OUT2" "Failed to download package")" "0"
}

run_scenarios() {
    reset_state
    scenario_install_dirs
    scenario_cli_errors
    scenario_agreement
    scenario_mid_failure
    scenario_uninstall_confirm
    scenario_self_delete
    scenario_shared
    scenario_link_regression
    scenario_install_menu
    scenario_download_retry
    scenario_write_permission
    scenario_interrupt

    echo ""
    echo "=========================================="
    echo "🌊 Passed: $PASSED"
    echo "🌊 Failed: $FAILED"
    echo "🌊 Skipped: $SKIPPED"
    echo "=========================================="

    [[ "$FAILED" -gt 0 ]] && exit 1
    exit 0
}

if [[ -n "${SANDBOX_INNER:-}" ]]; then
    OFFLINE_INSTALLER="$SANDBOX_DIR/install-offline.sh"
    MIRROR_BASE="$SANDBOX_DIR/mirror/base"
    OUT="$SANDBOX_DIR/output.txt"
    # 外层是 `exec unshare`，它自己的 EXIT 陷阱不会执行，所以清理要在这里挂
    trap 'rm -rf "$SANDBOX_DIR"' EXIT INT TERM
    run_scenarios
fi


# ==========================================================
# 外层：搭隔离环境，然后在内层重跑自己
# ==========================================================

if [[ "$(id -u)" == "0" ]]; then
    echo -e "${RED_BOLD}🌊 Run this as a normal user, not as root.${RESET}"
    echo "🌊 The sandbox maps your uid to 0 inside a user namespace; root would break that."
    exit 1
fi

for tool in unshare curl python3; do
    if ! command -v "$tool" > /dev/null 2>&1; then
        echo -e "${RED_BOLD}🌊 Error: '$tool' is required.${RESET}"
        exit 1
    fi
done

# 下面会把整个仓库拷进沙箱当离线镜像。脚本可能被复制到别处执行，
# 那时 REPO_DIR 会指向别的目录——不先确认身份，就会把一个无关（甚至巨大）
# 的目录整个打包进来。这里逐个检查仓库特有的文件。
for marker in lib/install.sh lib/uninstall.sh lib/wave.py scripts/link_test.sh; do
    if [[ ! -f "$REPO_DIR/$marker" ]]; then
        echo -e "${RED_BOLD}🌊 Error: $REPO_DIR does not look like the LinuxWave repository.${RESET}"
        echo "🌊 Missing: $marker"
        echo "🌊 Run it from the repository: bash scripts/sandbox_test.sh"
        exit 1
    fi
done

if ! unshare -rm true 2>/dev/null; then
    echo -e "${RED_BOLD}🌊 Error: user namespaces with mount are not available.${RESET}"
    echo "🌊 Needs util-linux unshare and an unrestricted kernel.unprivileged_userns_clone."
    exit 1
fi

SANDBOX_DIR="$(mktemp -d "${TMPDIR:-/tmp}/linuxwave-sandbox.XXXXXX")"
cleanup() {
    rm -rf "$SANDBOX_DIR"
}
# INT/TERM 也接上：中断留下的沙箱目录不小（镜像 + 影子 /etc），别攒着
trap cleanup EXIT INT TERM

echo "🌊 Sandbox: $SANDBOX_DIR"
echo "🌊 Nothing outside this directory will be written."
echo ""

# ---------- 1. 离线镜像 ----------
mkdir -p "$SANDBOX_DIR/mirror/base" "$SANDBOX_DIR/mirror/configdata"
tar -C "$REPO_DIR" -cf - \
    --exclude=.git --exclude=.github --exclude=.templates \
    --exclude=.vscode --exclude=.codex --exclude=__pycache__ . \
    | tar -C "$SANDBOX_DIR/mirror/base" -xf -

CONFIGDATA_SRC="${LINUXWAVE_CONFIGDATA:-$(dirname "$REPO_DIR")/configdata}"
if [[ -f "$CONFIGDATA_SRC/versiondata/files_info" ]]; then
    tar -C "$CONFIGDATA_SRC" -cf - --exclude=.git . | tar -C "$SANDBOX_DIR/mirror/configdata" -xf -
    echo "🌊 Using the real files_info from $CONFIGDATA_SRC"
else
    # 没有 configdata 分支时按仓库结构生成一份，好让脚本在单分支检出下也能跑
    mkdir -p "$SANDBOX_DIR/mirror/configdata/versiondata"
    {
        echo "/"
        for d in lib pkg surfboard; do
            echo "    $d/"
            for f in "$REPO_DIR/$d"/*; do
                [[ -f "$f" ]] || continue
                base="$(basename "$f")"
                # 安装器与卸载器不装自己——真实的 files_info 也是这样
                [[ "$base" == "install.sh" || "$base" == "uninstall.sh" ]] && continue
                echo "        $base"
            done
        done
    } > "$SANDBOX_DIR/mirror/configdata/versiondata/files_info"
    echo -e "${YELLOW}🌊 configdata branch not found; generated files_info from the repo tree.${RESET}"
    echo -e "${YELLOW}🌊 Set LINUXWAVE_CONFIGDATA=<path> to test the real one.${RESET}"
fi

# 只改两行 URL，其余与真实安装器逐字节一致
sed -e "s|^BASE_URL=.*|BASE_URL=\"file://$SANDBOX_DIR/mirror/base\"|" \
    -e "s|^CONFIGDATA_URL=.*|CONFIGDATA_URL=\"file://$SANDBOX_DIR/mirror/configdata\"|" \
    "$REPO_DIR/lib/install.sh" > "$SANDBOX_DIR/install-offline.sh"
cp "$REPO_DIR/lib/uninstall.sh" "$SANDBOX_DIR/source-uninstall.sh"

if [[ "$(diff <(sed -e 's|^BASE_URL=.*|X|' -e 's|^CONFIGDATA_URL=.*|Y|' "$REPO_DIR/lib/install.sh") \
               <(sed -e 's|^BASE_URL=.*|X|' -e 's|^CONFIGDATA_URL=.*|Y|' "$SANDBOX_DIR/install-offline.sh") \
          | wc -l)" != "0" ]]; then
    echo -e "${RED_BOLD}🌊 Error: the offline installer differs from lib/install.sh beyond the URLs.${RESET}"
    exit 1
fi

# ---------- 2. 影子目录 ----------
R="$SANDBOX_DIR/run"
mkdir -p "$R"/home "$R"/opt "$R"/usrlocal "$R"/root "$R"/var/tmp "$R"/srv
chmod 1777 "$R"/var/tmp
cp -a /etc "$R"/etc 2>/dev/null || true

# 开发机上可能真的装着 LinuxWave。把它的系统级配置从影子副本里去掉，
# 否则 configpaths 会优先选中那份（指向真实安装树），用例就跑到别处去了。
rm -rf "$R"/etc/linuxwave_config

# 宿主只有 root 能读的这几份，用最小内容补齐：
# 沙箱内 uid=0，足够 sudo 与 useradd 使用
[[ -f "$R/etc/shadow" ]] || printf 'root:*:19000:0:99999:7:::\n' > "$R/etc/shadow"
[[ -f "$R/etc/gshadow" ]] || printf 'root:*::\n' > "$R/etc/gshadow"
mkdir -p "$R/etc/sudoers.d"
printf 'root ALL=(ALL:ALL) ALL\n' > "$R/etc/sudoers"
chmod 0440 "$R/etc/sudoers" 2>/dev/null || true

# 预置 linuxwave 账号：复用命名空间里唯一被映射的 uid（见文件头「已知限制」）
if grep -q '^linuxwave:' "$R/etc/passwd"; then
    sed -i 's|^linuxwave:[^:]*:[0-9]*:[0-9]*:[^:]*:[^:]*:[^:]*|linuxwave:x:0:0:LinuxWave:/home/linuxwave:/bin/bash|' "$R/etc/passwd"
else
    echo 'linuxwave:x:0:0:LinuxWave:/home/linuxwave:/bin/bash' >> "$R/etc/passwd"
fi
if grep -q '^linuxwave:' "$R/etc/group"; then
    sed -i 's|^linuxwave:[^:]*:[0-9]*:|linuxwave:x:0:|' "$R/etc/group"
else
    echo 'linuxwave:x:0:' >> "$R/etc/group"
fi
mkdir -p "$R/home/linuxwave"

# 替身：命名空间内本就是 uid 0；真调 loginctl 会去改宿主 systemd 的状态
mkdir -p "$R/root/bin"
cat > "$R/root/bin/sudo" << 'STUB'
#!/bin/sh
while [ $# -gt 0 ]; do
    case "$1" in
        -v|-n|--non-interactive|--validate) shift ;;
        --) shift; break ;;
        *) break ;;
    esac
done
exec "$@"
STUB
cat > "$R/root/bin/loginctl" << 'STUB'
#!/bin/sh
echo "loginctl $*" >> /root/calls.txt
exit 0
STUB
cat > "$R/root/bin/systemctl" << 'STUB'
#!/bin/sh
echo "systemctl $*" >> /root/calls.txt
exit 0
STUB
chmod +x "$R/root/bin/sudo" "$R/root/bin/loginctl" "$R/root/bin/systemctl"

# ---------- 3. 进命名空间跑 ----------
cp "${BASH_SOURCE[0]}" "$SANDBOX_DIR/sandbox_test.sh"

export SANDBOX_DIR R
exec unshare -rm /bin/bash -c '
    mount --bind "$R/etc"      /etc
    mount --bind "$R/home"     /home
    mount --bind "$R/opt"      /opt
    mount --bind "$R/usrlocal" /usr/local
    mount --bind "$R/root"     /root
    mount --bind "$R/var"      /var
    mount --bind "$R/srv"      /srv
    export HOME=/root
    export SANDBOX_INNER=1
    export PATH="/root/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    export LC_ALL=C.UTF-8
    cd /root
    exec /bin/bash "$SANDBOX_DIR/sandbox_test.sh"
'
