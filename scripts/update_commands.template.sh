#!/bin/bash

# LinuxWave update commands — @@VERSION@@
#
# 这个文件由 LinuxWave 仓库的 scripts/build_update_commands.py 生成，请勿手工编辑。
# 它取代了以前的 files_info：不再由客户端解析「要下载哪些文件」，而是由这里自己
# 完成下载与落盘。好处是只列出真正变动的文件 —— 这次没碰 help.py，就不必再下一遍。
# 目录结构变更的迁移也写在这个脚本里。
#
# 客户端保证以下环境变量：
#
#   LINUXWAVE_INSTALL_DIR      安装根目录
#   LINUXWAVE_CORE_URL         LinuxWave 代码的地址前缀（不含分支）
#   LINUXWAVE_BRANCH           代码分支
#   LINUXWAVE_CURRENT_VERSION  当前已装版本；首次安装时为空
#   LINUXWAVE_FILE_TIMEOUT     单个文件的超时秒数
#   LINUXWAVE_NEED_SUDO        1 = 安装目录需要 sudo 才能写
#   LINUXWAVE_LANG             zh = 中文输出；未设置或其它值 = 英文
#
# 约定：
#   - 任何一步失败都要 exit 非零；客户端据此判定「什么都没更新」，不写 VERSION.json
#   - 必须幂等：重跑一次不能把已经就位的东西弄坏

set -u

: "${LINUXWAVE_INSTALL_DIR:?LINUXWAVE_INSTALL_DIR is required}"
: "${LINUXWAVE_CORE_URL:?LINUXWAVE_CORE_URL is required}"

# 语言：install.sh 通过 LINUXWAVE_LANG 传进来。老版本客户端不会传，所以默认英文。
# 与 lib/install.sh 用同一套约定（lw_say "<English>" "<中文>"），不引 gettext。
LW_LANG="${LINUXWAVE_LANG:-en}"
lw_strip_item() {
    # --raw（install.sh 传下来的 LINUXWAVE_RAW=1）：去掉行首的 🌊 与紧跟的一个空格。
    # 与 `wave install --raw` 同一条规则；本脚本的几条提示都带 🌊，落进日志会脏。
    # 🌊 用 printf 的字节写：$'\U0001F30A' 在 bash 3.2 上不支持。
    local line="$1" item
    [[ "${LINUXWAVE_RAW:-}" == "1" ]] || { printf '%s' "$line"; return 0; }
    item="$(printf '\xf0\x9f\x8c\x8a')"
    case "$line" in
        "$item "*) line="${line#"$item "}" ;;
        "$item"*) line="${line#"$item"}" ;;
    esac
    printf '%s' "$line"
}
lw_say() {
    if [[ "$LW_LANG" == "zh" ]]; then printf '%b\n' "$(lw_strip_item "$2")"; else printf '%b\n' "$(lw_strip_item "$1")"; fi
}
lw_say_err() {
    if [[ "$LW_LANG" == "zh" ]]; then printf '%b\n' "$(lw_strip_item "$2")" >&2; else printf '%b\n' "$(lw_strip_item "$1")" >&2; fi
}
: "${LINUXWAVE_BRANCH:?LINUXWAVE_BRANCH is required}"

VERSION="@@VERSION@@"
BRANCH="@@BRANCH@@"
FILE_TIMEOUT="${LINUXWAVE_FILE_TIMEOUT:-180}"
ATTEMPTS=3

# 额外根证书（LINUXWAVE_CACERT）：企业网络里 TLS 会被重签，自建镜像也可能用私有 CA。
# 这个脚本是客户端调起来的，环境变量直接继承；没设时行为不变。
# 设了却读不到就报错退出 —— 静默忽略会让人以为已经信任了那家 CA。
CURL_CACERT=""
if [[ -n "${LINUXWAVE_CACERT:-}" ]]; then
    _cacert="${LINUXWAVE_CACERT/#\~/$HOME}"
    if [[ ! -f "$_cacert" || ! -r "$_cacert" ]]; then
        lw_say_err "🌊 Error: LINUXWAVE_CACERT is not a readable file: $_cacert" "🌊 错误：LINUXWAVE_CACERT 不是一个可读的文件：$_cacert"
        lw_say_err "🌊 Next      export LINUXWAVE_CACERT=/path/to/root.pem (or unset it)" "🌊 下一步     export LINUXWAVE_CACERT=/path/to/root.pem（或取消这个变量）"
        exit 1
    fi
    CURL_CACERT="$_cacert"
fi

run() {
    if [ "${LINUXWAVE_NEED_SUDO:-}" = "1" ]; then
        sudo "$@"
    else
        "$@"
    fi
}

redact_url() {
    # 报错里的地址要打码：用镜像时 LINUXWAVE_CORE_URL 是
    # https://<用户>:<密码>@mirror/...，原样打印等于把密码写进终端滚屏、
    # CI 日志和用户贴出来的求助截图。
    #
    # 只在 // 之后、第一个 / 之前找最后一个 @ —— 路径里带 @ 是正常的
    # （jq@1.8.2.arm64），拿整条串找 @ 会把包名当成密码位置，地址就改坏了。
    local url="$1" rest authority path userinfo host user
    rest=${url#*://}
    [ "$rest" = "$url" ] && { printf '%s' "$url"; return; }
    authority=${rest%%/*}
    case "$rest" in
        */*) path="/${rest#*/}" ;;
        *)   path="" ;;
    esac
    if [[ "$authority" != *@* ]]; then
        printf '%s' "$url"
        return
    fi
    userinfo=${authority%@*}
    host=${authority##*@}
    user=${userinfo%%:*}
    if [[ "$userinfo" == *:* ]]; then
        printf '%s://%s:***@%s%s' "${url%%://*}" "$user" "$host" "$path"
    else
        printf '%s://***@%s%s' "${url%%://*}" "$host" "$path"
    fi
}

fetch() {
    # fetch <url> <目标>：先写 .linuxwave-part 再 mv，重试期间目标位置不会出现半个文件
    local url="$1" destination="$2" attempt status partial
    partial="$destination.linuxwave-part"

    run mkdir -p "$(dirname "$destination")"
    for ((attempt = 1; attempt <= ATTEMPTS; attempt++)); do
        status=0
        run curl -fsSL --max-time "$FILE_TIMEOUT" ${CURL_CACERT:+--cacert "$CURL_CACERT"} -o "$partial" "$url" || status=$?
        if [ "$status" -eq 0 ]; then
            # mv 失败也要报：权限不足（sudo 没拿到）时文件还在 .linuxwave-part 里，
            # 目标位置是旧的甚至不存在。以前这里不看返回值，于是「下载成功但没就位」
            # 会被当成这一步成功 —— 和 want 里那个 return/exit 是同一类问题。
            if ! run mv -f "$partial" "$destination"; then
                lw_say_err "🌊 Error: cannot move $partial into place" "🌊 错误：无法把 $partial 移动到目标位置"
                run rm -f "$partial" 2>/dev/null || true
                return 1
            fi
            return 0
        fi
        run rm -f "$partial" 2>/dev/null || true
        if ((attempt < ATTEMPTS)); then
            sleep 2
        fi
    done
    return 1
}

file_sha256() {
    # 用 openssl 而不是 sha256sum：install.sh / selfupdate.sh 里验签名已经要用它，
    # 少一个依赖就少一种「某台机器上没有那个命令」的失败。
    openssl dgst -sha256 -r "$1" 2>/dev/null | awk '{print $1}'
}

verify_hash() {
    # verify_hash <仓库内路径> <已下载的文件> <期望哈希>
    #
    # 4.0 是**实验期**：默认只警告，装还是照装。理由是老客户端拿不到这份判断
    # （它们跑的是自己那份老脚本），真正的强制要等客户端版本铺开。开关：
    #   LINUXWAVE_WANT_HASHES=1   客户端要求校验（由 install.sh / selfupdate.sh 置）
    #   LINUXWAVE_STRICT_HASHES=1 不符即失败（未来的默认，现在不设）
    local repo_path="$1" file="$2" expect="$3" got
    got="$(file_sha256 "$file")"
    [ -n "$expect" ] || return 0
    [ "$got" = "$expect" ] && return 0

    if [ "${LINUXWAVE_STRICT_HASHES:-}" = "1" ]; then
        lw_say_err "🌊 Error: $repo_path does not match the signed manifest" \
                   "🌊 错误：$repo_path 与已签名清单不符"
        lw_say_err "🌊   expected $expect" "🌊   期望 $expect"
        lw_say_err "🌊   got      ${got:-<unreadable>}" "🌊   实际 ${got:-读不到}"
        exit 1
    fi

    lw_say_err "🌊 Warning: $repo_path does not match the signed manifest (continuing)" \
               "🌊 警告：$repo_path 与已签名清单不符（继续安装）"
    lw_say_err "🌊   expected $expect" "🌊   期望 $expect"
    lw_say_err "🌊   got      ${got:-<unreadable>}" "🌊   实际 ${got:-读不到}"
    return 0
}

want() {
    # want <仓库内路径> <是否 +x> [期望的 sha256]
    local repo_path="$1" exec_flag="${2:-0}" expect_sha="${3:-}"
    local destination="$LINUXWAVE_INSTALL_DIR/$repo_path"
    local url="$LINUXWAVE_CORE_URL/$LINUXWAVE_BRANCH/$repo_path"

    if [ "${LINUXWAVE_SILENT:-}" != "1" ]; then
        lw_say "🌊 Downloading $repo_path..." "🌊 正在下载 ${repo_path}……"
    fi
    if ! fetch "$url" "$destination"; then
        lw_say_err "🌊 Error: cannot download $repo_path" "🌊 错误：无法下载 $repo_path"
        echo "🌊   $(redact_url "$url")" >&2
        # 404 有两种完全不同的原因：单个文件被删了，或者整棵 core/<分支>/ 压根没同步。
        # 后者是新分支上线当天的常态（镜像一天只跑一次），而且症状看起来一模一样 ——
        # 日志里只说某一个文件下不到。
        lw_say_err "🌊 If every file fails like this, the mirror has not synced branch $LINUXWAVE_BRANCH yet." \
                   "🌊 如果每个文件都这样，说明镜像还没同步 ${LINUXWAVE_BRANCH} 这个分支。"
        lw_say_err "🌊 Run scripts/mirror_sync.sh on the mirror (see docs/mirror.md)." \
                   "🌊 在镜像机上跑 scripts/mirror_sync.sh（见 docs/mirror.md）。"
        # 必须 exit 而不是 return：install_fresh / install_delta 是一串裸的
        # `want ...`，没有 `|| exit`，脚本也没有 set -e。用 return 1 的话
        # 调用方不看返回值，于是「有文件没下到」会被当成更新成功，客户端照旧
        # 写 VERSION.json —— 安装树缺文件但版本号已经前进了，这种状态最难查。
        exit 1
    fi
    # 校验放在 chmod 之前：先确认字节对不对，再决定要不要给它执行位
    if [ "${LINUXWAVE_WANT_HASHES:-}" = "1" ] && [ -n "$expect_sha" ]; then
        verify_hash "$repo_path" "$destination" "$expect_sha"
    fi
    if [ "$exec_flag" = "1" ]; then
        # 加不上 +x 的后果是「命令找不到」，比下载失败更难懂，所以这里也要拦住
        if ! run chmod +x "$destination"; then
            lw_say_err "🌊 Error: cannot make $repo_path executable" "🌊 错误：无法把 $repo_path 设为可执行"
            exit 1
        fi
    fi
    return 0
}

install_fresh() {
    # 首次安装（或修复一棵不完整的安装树）：所有文件都要。
@@FULL@@
}

install_delta() {
    # 从上一版升级：只取这一版变动过的文件。
    # 没列出的文件保持不变 —— 它们的字节和上一版相同。
@@DELTA@@
}

# 本版安装树应有的全部文件（与 install_fresh 同一份清单，见生成器里的 list_lines）。
FULL_FILES="
@@FULL_FILES@@
"

tree_complete() {
    # 判断这棵安装树是不是「本版应有的文件一个不缺」。
    #
    # 为什么不能只看 lib/wave.py 在不在：那种判据会把三种坏树当成好树 ——
    #   1. 上一版留下的一半升级（下到第 20 个文件时断网 / Ctrl-C）
    #   2. 跨版本跳级升级：增量只含「上一版 → 本版」的差异，中间的版本没算
    #   3. 文件被手工删过
    # 缺一个就走全量，代价是多重下几个文件，换的是「永远能自愈」。
    local path
    for path in $FULL_FILES; do
        [ -e "$LINUXWAVE_INSTALL_DIR/$path" ] || return 1
    done
    return 0
}

main() {
    # 「已经是这个版本」也要先确认树是完整的。VERSION.json 只证明「上次跑完过」，
    # 不证明文件还在 —— 只信版本号的话，一棵坏树会永远停在 "Already at"，
    # 无论跑多少次都不会修好。
    if [ "${LINUXWAVE_FULL_INSTALL:-}" != "1" ] \
       && [ "${LINUXWAVE_CURRENT_VERSION:-}" = "$VERSION" ] \
       && tree_complete; then
        lw_say "🌊 Already at $VERSION; nothing to download." "🌊 已经是 ${VERSION}，无需下载。"
        return 0
    fi

    if [ "${LINUXWAVE_FULL_INSTALL:-}" = "1" ] || [ ! -f "$LINUXWAVE_INSTALL_DIR/lib/wave.py" ]; then
        lw_say "🌊 Installing LinuxWave $VERSION" "🌊 正在安装 LinuxWave $VERSION"
        install_fresh || return 1
    elif ! tree_complete; then
        # 树在那儿但不完整：增量的前提（「没变动的文件都是对的」）不成立，
        # 直接全量补齐。这里不先跑 delta —— 缺的文件正好可能就是它要留着的那些。
        lw_say "🌊 The installed tree is incomplete; reinstalling all of LinuxWave $VERSION" \
            "🌊 安装树不完整，正在重新安装 LinuxWave ${VERSION} 的全部文件"
        install_fresh || return 1
    else
        lw_say "🌊 Updating LinuxWave ${LINUXWAVE_CURRENT_VERSION:-unknown} -> $VERSION" "🌊 正在更新 LinuxWave ${LINUXWAVE_CURRENT_VERSION:-unknown} -> $VERSION"
        install_delta || return 1
        # 增量之后再确认一次：delta 只含「上一版 → 本版」的差异，跨版本跳级时
        # 会漏掉中间那些版本改过的文件。补全比报错好 —— 用户什么也没做错。
        if ! tree_complete; then
            lw_say "🌊 Some files are still missing after the update; fetching all of LinuxWave $VERSION" \
                "🌊 更新后仍有文件缺失，正在补齐 LinuxWave ${VERSION} 的全部文件"
            install_fresh || return 1
        fi
    fi

    # ── 目录结构变更的迁移写在这里 ──
    # 约束：以当前用户身份执行，需要管理员权限时自己 sudo，失败要 exit 非零，
    # 且必须幂等。

    return 0
}

main "$@"
