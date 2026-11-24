#!/bin/bash

# install_flags_test.sh
# `--help` 与 `--print-usage` 的分工，以及 --help 的连用规则。
#
# 两条命令长得像，做的事不一样：
#
#   --help          打用法，**停**在这里（不安装）
#   --print-usage   打用法，然后**继续**（真的安装，或继续 --dry-run）
#
# 而且 --help 只允许单独出现，或与 --dry-run 连用（先打用法、再走一遍流程）。
# 与其它安装参数连用要报错：`--help --ci --dir-option=2` 读起来像「按这些参数装」，
# 实际却只打帮助 —— 静默忽略比报错更容易让人以为装过了。
#
# 第 7 节另测「平台守卫」：非 macOS 时第一句就请用户去 LinuxWave，
# 连安装都不开始（给网站与安装命令，退出码 2）。
#
# 全程离线、隔离测试根、只用 --dry-run（或干脆什么都不做）。

set -u

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 安装器要 bash 4.4+，而 macOS 的 /bin/bash 是 3.2 —— 用 PATH 上的 bash（CI 与
# 各发行版都是 5.x），别把测试绑死在 /bin/bash 上。
BASH_BIN="${BASH_BIN:-bash}"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
INSTALL_SH="$REPO_DIR/lib/install.sh"

FAILED=0
PASSED=0

pass() { echo -e "${GREEN}🌊 PASS: $1${RESET}"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED_BOLD}🌊 FAIL: $1${RESET}"; FAILED=$((FAILED + 1)); }

if [[ ! -f "$INSTALL_SH" ]]; then
    echo -e "${RED_BOLD}🌊 Error: install.sh not found at $INSTALL_SH${RESET}"
    exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

has() { case "$1" in (*"$2"*) return 0 ;; (*) return 1 ;; esac; }
hasnt() { case "$1" in (*"$2"*) return 1 ;; (*) return 0 ;; esac; }

# 版本数据必须能读到：它在**参数解析之前**就会去取，读不到时安装器直接退出，
# 那样连 --help 都轮不到。这里用 file:// 指一份最小的 latest.toml —— 离线，
# 且不会因为线上换版本而变红。
SELFUPDATE_DIR="$WORK/selfupdate"
mkdir -p "$SELFUPDATE_DIR/linuxwavedata"
printf 'version = "9.9.9"\nrelease_date = "2026-01-01"\nbuild_number = "TEST"\nbranch = "9.9"\n' \
    > "$SELFUPDATE_DIR/linuxwavedata/latest.toml"

# run_raw <测试根名> [参数...]：原样调用安装器（不额外加旗标）。
run_raw() {
    local root="$WORK/$1"; shift
    mkdir -p "$root"
    OUT=$(LINUXWAVE_TEST="$root" \
          LINUXWAVE_SELFUPDATE_DOMAIN="file://$SELFUPDATE_DIR" \
          "$BASH_BIN" "$INSTALL_SH" "$@" < /dev/null 2>&1)
    RC=$?
}

# run_install：同上，但补 --skip-platform-check。
#
# 安装器有「只装 Linux」的闸门，而这份测试要在 macOS 与 Linux 两种机器上都跑；
# 平台闸门本身由下面单独一节用 run_raw 验证，其余各节关心的都是「参数怎么解析、
# 用法怎么呈现」—— 让平台差异把它们全变成红的没有意义。
run_install() {
    local root="$WORK/$1"; shift
    run_raw "$root" --skip-platform-check "$@"
}

# -------------------- 1. --help 单独：打用法就停 --------------------

run_install help-alone --help
if [[ "$RC" -eq 0 ]] && has "$OUT" "Usage:" && hasnt "$OUT" "Dry run"; then
    pass "--help：只打用法，rc=0"
else
    fail "--help 的行为不对（rc=${RC}）"
fi

# 「不安装」的证据：没有安装树、也没有写配置。
# 注意 LINUXWAVE_TEST 的测试根里会先建一个 <根><HOME> 的空目录（那是隔离机制本身），
# 所以这里查的是「安装的产物」，不是「目录是否为空」。
if [[ ! -e "$WORK/help-alone/base" ]] \
   && [[ -z "$(find "$WORK/help-alone" -name config.json 2>/dev/null)" ]]; then
    pass "--help：没有安装树、也没有写配置"
else
    fail "--help 竟然产生了安装产物"
fi

# --help 不该碰网络：版本号请求排在参数解析之后，所以连版本源都连不上时，
# 它也必须能照常打出用法。这条是结构保证，不是巧合 —— 早先的写法是先取版本、
# 再解析参数，`--help` 在断网机器上会直接报「读不到版本号」。
OUT=$(LINUXWAVE_TEST="$WORK/help-offline" \
      LINUXWAVE_SELFUPDATE_DOMAIN="http://127.0.0.1:1" \
      "$BASH_BIN" "$INSTALL_SH" --help < /dev/null 2>&1)
RC=$?
if [[ "$RC" -eq 0 ]] && has "$OUT" "Usage:" && hasnt "$OUT" "Cannot read the latest version"; then
    pass "--help 不联网：版本源不可达时仍能打用法"
else
    fail "--help 仍然依赖版本源（rc=${RC}）"
fi

# -------------------- 2. --help 与呈现类旗标 --------------------

run_install help-zh --help --zh
if [[ "$RC" -eq 0 ]] && has "$OUT" "用法："; then
    pass "--help --zh：中文用法"
else
    fail "--help --zh 没打中文（rc=${RC}）"
fi

run_install help-raw --help --raw
# 注意：帮助正文里**提到** 🌊（--raw 的说明），所以只查行首有没有。
if [[ "$RC" -eq 0 ]] && [[ "$(printf '%s\n' "$OUT" | grep -c '^🌊')" -eq 0 ]] \
   && [[ "$(printf '%s\n' "$OUT" | grep -c "$(printf '\033')")" -eq 0 ]]; then
    pass "--help --raw：行首无 🌊、无 ANSI"
else
    fail "--help --raw 的输出不干净"
fi

# -------------------- 3. --help 与 --dry-run：先用法、再走流程 --------------------

run_install help-dry --help --dry-run
if hasnt "$OUT" "cannot be combined" && has "$OUT" "Usage:" && has "$OUT" "Dry run"; then
    pass "--help --dry-run：允许，先打用法再走试运行"
else
    fail "--help --dry-run 被拒或没继续（rc=${RC}）"
fi

# -------------------- 4. --help 与其它参数：必须报错 --------------------

run_install help-ci --help --ci
if [[ "$RC" -eq 1 ]] && has "$OUT" "cannot be combined with '--ci'"; then
    pass "--help --ci：报错并点名 --ci"
else
    fail "--help --ci 没有报错（rc=${RC}）"
fi

run_install help-dir --help --dir-option=1
if [[ "$RC" -eq 1 ]] && has "$OUT" "cannot be combined with '--dir-option=1'"; then
    pass "--help --dir-option=1：报错并点名该参数"
else
    fail "--help --dir-option=1 没有报错（rc=${RC}）"
fi

if has "$OUT" "--print-usage"; then
    pass "报错时指出 --print-usage 这条出路"
else
    fail "报错里没有提到 --print-usage"
fi

# -------------------- 5. --print-usage：打用法后继续 --------------------

run_install pu-dry --print-usage --dry-run --dir-option=1
if [[ "$RC" -eq 0 ]] && has "$OUT" "Usage:" && has "$OUT" "Dry run"; then
    pass "--print-usage --dry-run：先用法，再继续试运行"
else
    fail "--print-usage --dry-run 的行为不对（rc=${RC}）"
fi

run_install pu-zh-raw --print-usage --zh --raw --dry-run --dir-option=1
if [[ "$RC" -eq 0 ]] && has "$OUT" "用法：" \
   && [[ "$(printf '%s\n' "$OUT" | grep -c '^🌊')" -eq 0 ]] \
   && [[ "$(printf '%s\n' "$OUT" | grep -c "$(printf '\033')")" -eq 0 ]]; then
    pass "--print-usage 也遵守 --zh 与 --raw"
else
    fail "--print-usage --zh --raw 的组合没按规矩输出（rc=${RC}）"
fi

# -------------------- 6. 未知选项仍然报错（回归） --------------------

run_install unknown --bogus-flag
if [[ "$RC" -eq 1 ]] && has "$OUT" "unknown option"; then
    pass "未知选项仍然报错"
else
    fail "未知选项没有报错（rc=${RC}）"
fi

# -------------------- 7. 平台守卫：非 Linux 请去 MacWave --------------------
#
# 用替身 uname 摆出「宿主是 Darwin」：LinuxWave 的安装器只处理 Linux，在
# macOS 上装到一半才报错是最差的形态。
#
# 这里**故意不设 LINUXWAVE_TEST** —— 平台判断看的是宿主内核，与沙箱无关。

STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/uname" <<'STUB'
#!/bin/sh
case "$1" in
    -s) echo Darwin ;;
    -m) echo arm64 ;;
    *) exec /usr/bin/uname "$@" ;;
esac
STUB
chmod +x "$STUB_BIN/uname"

mkother() {
    # mkother [参数...]：在「非 Linux 宿主」下跑一次，输出进 OUT，退出码进 RC
    rm -rf "$WORK/other-root"
    OUT=$(PATH="$STUB_BIN:$PATH" \
          LINUXWAVE_SELFUPDATE_DOMAIN="file://$SELFUPDATE_DIR" \
          "$BASH_BIN" "$INSTALL_SH" "$@" < /dev/null 2>&1)
    RC=$?
}

mkother --dry-run --dir-option=1
if [[ "$RC" -eq 1 ]] \
   && has "$OUT" "this installer is for Linux" \
   && has "$OUT" "https://macwave.org"; then
    pass "非 Linux：拒绝，并指向 MacWave（rc=1）"
else
    fail "非 Linux 的提示不对（rc=${RC}）：$(printf '%s' "$OUT" | head -2)"
fi

if [[ ! -e "$WORK/other-root" ]] && [[ -z "$(find "$WORK" -maxdepth 1 -name 'other-*' 2>/dev/null)" ]]; then
    pass "非 Linux：拒绝发生在任何安装动作之前（没有测试根、没有产物）"
else
    fail "非 Linux 时还是动了文件"
fi

mkother --zh
if [[ "$RC" -eq 1 ]] && has "$OUT" "本安装器只用于 Linux"; then
    pass "非 Linux --zh：提示是中文的"
else
    fail "非 Linux --zh 没有中文提示（rc=${RC}）"
fi

mkother --raw
if [[ "$RC" -eq 1 ]] && [[ "$(printf '%s\n' "$OUT" | grep -c '^🌊')" -eq 0 ]]; then
    pass "非 Linux --raw：行首无 🌊（走的是同一个过滤器）"
else
    fail "非 Linux --raw 的输出不干净（rc=${RC}）"
fi

mkother --help
if [[ "$RC" -eq 0 ]] && has "$OUT" "Usage:"; then
    pass "非 Linux --help：照常打用法，不被平台守卫拦住"
else
    fail "非 Linux --help 被拦住了（rc=${RC}）"
fi

# -------------------- 7a2. --skip-platform-check：跳过守卫，但必须出声 --------------------
#
# 用途有两个：调试安装器本身；手上没有 Linux 的时候把流程演练一遍（配 --dry-run）。
# 跳过的是「这套东西装在这台机器上能不能跑」的判断，所以警告里要报出当前是什么
# 系统，并且明说结果没验证过 —— 静默跳过等于把风险藏起来。

mkother --skip-platform-check --dry-run --dir-option=1
if [[ "$RC" -eq 0 ]] && has "$OUT" "Dry run" && has "$OUT" "--skip-platform-check"; then
    pass "--skip-platform-check：非 Linux 也继续，且打印了警告（rc=0）"
else
    fail "--skip-platform-check 没跳过平台守卫（rc=${RC}）：$(printf '%s' "$OUT" | head -2)"
fi

if has "$OUT" "This system is Darwin"; then
    pass "--skip-platform-check：警告里报了当前系统"
else
    fail "--skip-platform-check 的警告没说是哪个系统"
fi

mkother --skip-platform-check --dry-run --dir-option=1 --raw
if [[ "$RC" -eq 0 ]] && [[ "$(printf '%s\n' "$OUT" | grep -c '^🌊')" -eq 0 ]]; then
    pass "--skip-platform-check --raw：警告也没有行首 🌊"
else
    fail "--skip-platform-check --raw 的输出不干净（rc=${RC}）"
fi

echo
echo "=========================================="
echo -e "🌊 Passed: $PASSED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="

[[ "$FAILED" -eq 0 ]] || exit 1
echo -e "${GREEN}🌊 All install flag tests passed${RESET}"
