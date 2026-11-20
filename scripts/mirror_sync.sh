#!/bin/bash

# mirror_sync.sh —— 把 LinuxWave / MacWave 的公开数据树同步到一台镜像站。
#
# 镜像站只需要复刻**上游的路径形状**，客户端就只用改域名：安装器把所有地址都拼成
# 「域 + 固定后缀」（`$CORE_URL/$BRANCH/lib/…`、`$SELFUPDATE/linuxwavedata/…`），
# 后缀与上游一致，镜像就能原样接住。
#
#   <root>/<Org>/<repo>/<ref>/<仓库内路径>      Org 取 LinuxWave / MacWave
#                                              （与 URL 第一段一一对应）
#
# 于是「程序树」里连 install.sh 自己都在内，不需要为它单开一条规则：
#
#   https://mirror.example.com/LinuxWave/LinuxWave/4.0/lib/install.sh
#   https://mirror.example.com/MacWave/MacWave/4.4/lib/install.sh
#
# 也就是「URL 去掉域名之后，正好是本脚本写下的路径」，没有额外映射规则。
#
# 两处例外，都因为上游本来就是「按名字平铺」而不是 git 树，镜像沿用现有布局即可：
#
#   <root>/MacWave/bottle/<包名>/<资产>    ← GitHub Releases 资产（Bottle / Deps）
#   <root>/MacWave/deps/<依赖名>/<资产>
#
# 另一件只有镜像能做的事：`versions` 清单。客户端设了 API 域（也就是在用镜像）时
# 只读 `<api>/pkg/pkginfo_<arch>/versions` 与 `<api>/pkg/pkginfo_<arch>/<包>/versions`，
# 而这两个文件上游没有 —— 由本脚本按目录内容生成（一行一条，版本那份给的是**文件名**
# `_jq@1.8.2`，客户端自己 split("@")）。
#
# 用法：
#   mirror_sync.sh [--root DIR] [--project linuxwave|macwave|all]
#                  [--extra <Org>/<repo>:<ref>]...  [-n|--dry-run]
#
# 默认 --root /srv/mirror、--project all。`--extra` 用来顺带镜像一个临时分支
# （例如演练 4.0 时的 `LinuxWaveOrg/LinuxWave:4.0-dev`），可以给多次。
#
# 建议 cron：*/15 * * * * /usr/local/bin/mirror_sync.sh >/dev/null 2>&1
#
# 注意：分支名会原样变成目录名。带斜杠的分支（如 `test/arglen`）会多一层目录，
# 客户端拼出来的 URL 也带同样的一段，两边一致，不需要特殊处理。

set -euo pipefail

ROOT=/srv/mirror
PROJECT=all
DRY_RUN=false
EXTRA=()

lw_say() { printf '🌊 %s\n' "$*"; }
die() { printf '🌊 Error: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --root)    ROOT="${2:?--root 需要一个目录}"; shift 2 ;;
        --root=*)  ROOT="${1#*=}"; shift ;;
        --project) PROJECT="${2:?--project 需要 linuxwave|macwave|all}"; shift 2 ;;
        --project=*) PROJECT="${1#*=}"; shift ;;
        --extra)   EXTRA+=("${2:?--extra 需要 <Org>/<repo>:<ref>}"); shift 2 ;;
        --extra=*) EXTRA+=("${1#*=}"); shift ;;
        -n|--dry-run) DRY_RUN=true; shift ;;
        -h|--help) sed -n '3,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "未知参数 $1（用 --help）" ;;
    esac
done

case "$PROJECT" in
    linuxwave|macwave|all) ;;
    *) die "--project 只能是 linuxwave / macwave / all（收到 ${PROJECT}）" ;;
esac

run() {
    if $DRY_RUN; then
        printf '    would: %s\n' "$*"
    else
        "$@"
    fi
}

# 取 TOML 里一个平铺的字符串字段（`key = "value"`，允许行尾注释）
toml_field() {
    # 取不到（网络、404）时给空串，由调用方决定怎么报错。这里必须 `|| true`：
    # `set -o pipefail` 之下，一次网络抖动会让整个脚本静默退出，连一句提示都没有。
    local text
    text="$(curl -fsSL --max-time 30 "$1" 2>/dev/null || true)"
    printf '%s\n' "$text" \
        | sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
        | head -n 1
}

# 目录里的 Org 段（LinuxWave / MacWave），与 GitHub 组织名（LinuxWaveOrg / MacWaveOrg）不同 ——
# 前者是 URL 的第一段，后者只用于 clone。
dir_org() {
    case "$1" in
        LinuxWaveOrg) echo LinuxWave ;;
        MacWaveOrg)   echo MacWave ;;
        *)            echo "$1" ;;
    esac
}

# sync_tree <GitHub 组织> <repo> <ref>
#   ref=HEAD 表示「该仓库的默认分支」：克隆时不带 -b，之后跟着 @{u} 走。
sync_tree() {
    local gh_org=$1 repo=$2 ref=$3
    local org dir
    org="$(dir_org "$gh_org")"
    dir="$ROOT/$org/$repo/$ref"

    if [[ -d "$dir/.git" ]]; then
        lw_say "更新 $org/$repo@$ref"
        run git -C "$dir" fetch -q --depth 1 origin
        run git -C "$dir" reset -q --hard '@{u}'
        return 0
    fi

    lw_say "克隆 $org/$repo@$ref → $dir"
    run mkdir -p "$ROOT/$org/$repo"
    if [[ "$ref" == HEAD ]]; then
        run git clone -q --depth 1 "https://github.com/$gh_org/$repo" "$dir"
    else
        run git clone -q --depth 1 -b "$ref" "https://github.com/$gh_org/$repo" "$dir"
    fi
}

# gen_index <infosource 目录>
#   生成 pkg/pkginfo_<arch>/versions 与 pkg/pkginfo_<arch>/<包>/versions。
#   目录名里的 arch 原样沿用（LinuxWave 与 MacWave 都是 amd64 / arm64）。
gen_index() {
    local api=$1 base arch p
    [[ -d "$api/pkg" ]] || return 0
    for base in "$api"/pkg/pkginfo_*; do
        [[ -d "$base" ]] || continue
        arch="${base##*/pkginfo_}"
        lw_say "生成索引 $arch"
        if $DRY_RUN; then
            printf '    would: write %s/versions and %s/*/versions\n' "$base" "$base"
            continue
        fi
        ( cd "$base" && ls -1d */ 2>/dev/null | sed 's:/$::' ) > "$base/versions"
        for p in "$base"/*/; do
            [[ -d "$p" ]] || continue
            # 客户端要的是文件名（_jq@1.8.2 / _jq@common），它自己 split("@")。
            # 排除刚写进去的 versions，否则会把自己列成一条。
            ( cd "$p" && ls -1 | grep -vx versions ) > "$p/versions"
        done
    done
}

# -------------------- LinuxWave --------------------
#
#   configdata                                    自更新数据与解释器数据（main）
#   LinuxWave/<发布分支>                           程序文件（main 另外留一份）
#   infosource                                    索引（main）
#   Bottle / Deps / Python                         暂无独立仓库，不需要镜像

sync_linuxwave() {
    local cfg=https://raw.githubusercontent.com/LinuxWaveOrg/configdata/main/linuxwavedata/latest.toml
    local branch

    sync_tree LinuxWaveOrg configdata main

    branch="$(toml_field "$cfg" branch)"
    [[ -n "$branch" ]] || die "读不到 LinuxWave 的发布分支（${cfg}）"
    sync_tree LinuxWaveOrg LinuxWave "$branch"
    [[ "$branch" == main ]] || sync_tree LinuxWaveOrg LinuxWave main

    sync_tree LinuxWaveOrg infosource main

    if $DRY_RUN; then
        lw_say "索引：$ROOT/LinuxWave/infosource/main（试运行，不生成）"
    else
        gen_index "$ROOT/LinuxWave/infosource/main"
    fi
}

# -------------------- MacWave --------------------
#
#   Selfupdate    自更新数据（默认分支，客户端 URL 里就写作 /HEAD）
#   MacWave/<发布分支> + main
#   Python        便携解释器
#   infosource    索引
#   bottle / deps Release 资产：不在这里同步（见文档）

sync_macwave() {
    local st=https://raw.githubusercontent.com/MacWaveOrg/Selfupdate/HEAD/macwavedata/latest.toml
    local branch

    sync_tree MacWaveOrg Selfupdate HEAD

    branch="$(toml_field "$st" branch)"
    [[ -n "$branch" ]] || die "读不到 MacWave 的发布分支（${st}）"
    sync_tree MacWaveOrg MacWave "$branch"
    [[ "$branch" == main ]] || sync_tree MacWaveOrg MacWave main

    sync_tree MacWaveOrg Python HEAD
    sync_tree MacWaveOrg infosource HEAD

    if $DRY_RUN; then
        lw_say "索引：$ROOT/MacWave/infosource/HEAD（试运行，不生成）"
    else
        gen_index "$ROOT/MacWave/infosource/HEAD"
    fi
}

export GIT_TERMINAL_PROMPT=0

case "$PROJECT" in
    linuxwave) sync_linuxwave ;;
    macwave)   sync_macwave ;;
    all)       sync_linuxwave; sync_macwave ;;
esac

# --extra <GitHub 组织>/<repo>:<ref>，例如 LinuxWaveOrg/LinuxWave:4.0-dev
for spec in ${EXTRA[@]+"${EXTRA[@]}"}; do
    gh_org="${spec%%/*}"
    rest="${spec#*/}"
    sync_tree "$gh_org" "${rest%%:*}" "${rest##*:}"
done

lw_say "完成。根目录：$ROOT"
