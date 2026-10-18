#!/bin/bash

# checksum_test.sh
# 校验值回归：**没有合法 sha256 就不许安装**。
#
# 索引记录是整条信任链的起点 —— 每条记录声明「这个 URL 的内容，其 SHA-256 是 X」，
# 安装时把下载到的字节与 X 比对，是唯一把「索引承诺的内容」与「实际落盘的内容」绑在
# 一起的动作。HTTPS 只保护传输过程，保护不了「索引被改动」与「上游替换同名产物」。
# 所以缺 X 时不能只警告后放行（3.0.3 及之前就是放行的）。
#
# 三段覆盖：
#   A. 校验核心 mw_verify_sha256 的行为（离线）—— 缺值 / 长度不足 / 大写 / 非十六进制
#      / 格式合法但内容不符（还要删掉损坏文件）/ 正确值
#   B. 端到端拒绝（联网）—— wave install 缺校验值的包必须失败，且不留下任何安装痕迹
#   C. 静态哨兵 —— 三处守卫（包记录 / 依赖记录 / 安装核心）缺一即失败，
#      防止将来重构时被悄悄删掉
#
# 用法: bash scripts/checksum_test.sh
# 需要先按 lib/install.sh 装好（要读 config.json 里的 base_dir）。

set -e

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
WAVE_BIN="$REPO_DIR/lib/wave.py"
DEPSMANAGER_SH="$REPO_DIR/surfboard/depsmanager.sh"

if [[ ! -f "$WAVE_BIN" ]]; then
    echo -e "${RED_BOLD}🌊 Error: wave.py not found at $WAVE_BIN${RESET}"
    exit 1
fi

if [[ ! -f "$DEPSMANAGER_SH" ]]; then
    echo -e "${RED_BOLD}🌊 Error: depsmanager.sh not found at $DEPSMANAGER_SH${RESET}"
    exit 1
fi

FAILED=0
PASSED=0
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

# ---- 断言辅助 ----

# expect_rc <描述> <实际> <期望>
expect_rc() {
    if [[ "$2" -eq "$3" ]]; then
        pass "$1（退出码 $2）"
    else
        fail "$1（退出码 $2，期望 $3）"
        if [[ -n "${LAST_OUT:-}" ]]; then
            echo "$LAST_OUT" | sed 's/^/      /' | head -5
        fi
    fi
}

# expect_in <描述> <文本> <子串>
expect_in() {
    if printf '%s' "$2" | grep -qF "$3"; then
        pass "$1"
    else
        fail "$1（没找到「$3」）"
        printf '%s\n' "$2" | sed 's/^/      /' | head -8
    fi
}

TMP_ROOT="$(mktemp -d)"
cleanup() {
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

SAMPLE_FILE="$TMP_ROOT/sample.bin"
printf 'LinuxWave checksum regression sample\n' > "$SAMPLE_FILE"
SAMPLE_SHA="$(sha256sum "$SAMPLE_FILE" | awk '{print $1}')"

# ============================================================
echo "========== A. 校验核心的行为（离线） =========="
# ============================================================

# 每个用例都在独立子 shell 里跑：mw_verify_sha256 用 exit 1 表示拒绝，
# 直接在当前 shell 调用会把测试脚本本身干掉。source 会带进 set -e，子 shell 一并隔离。
run_verify() {
    local expected="$1"
    VERIFY_OUT="$(bash -c 'source "$1" > /dev/null 2>&1; mw_verify_sha256 "$2" "$3"' \
                       _ "$DEPSMANAGER_SH" "$SAMPLE_FILE" "$expected" 2>&1)" || VERIFY_RC=$?
    LAST_OUT="$VERIFY_OUT"
}

# A1. 缺校验值
VERIFY_RC=0; run_verify ""
expect_rc "缺校验值时拒绝安装" "$VERIFY_RC" 1
expect_in "缺校验值的报错说明了原因" "$VERIFY_OUT" "No SHA256 checksum"
expect_in "缺校验值时明确表示拒绝" "$VERIFY_OUT" "refusing to install"

# A2. 长度不足
VERIFY_RC=0; run_verify "abc"
expect_rc "校验值长度不足时拒绝" "$VERIFY_RC" 1
expect_in "长度不足报成格式错误" "$VERIFY_OUT" "Malformed SHA256 checksum"

# A3. 64 位但含大写
VERIFY_RC=0; run_verify "$(printf 'A%.0s' {1..64})"
expect_rc "校验值含大写时拒绝" "$VERIFY_RC" 1
expect_in "大写报成格式错误" "$VERIFY_OUT" "Malformed SHA256 checksum"

# A4. 64 位但含非十六进制字符
VERIFY_RC=0; run_verify "$(printf 'z%.0s' {1..64})"
expect_rc "校验值含非十六进制字符时拒绝" "$VERIFY_RC" 1
expect_in "非十六进制报成格式错误" "$VERIFY_OUT" "Malformed SHA256 checksum"

# A5. 格式合法且内容正确
VERIFY_RC=0; run_verify "$SAMPLE_SHA"
expect_rc "正确校验值通过" "$VERIFY_RC" 0
expect_in "正确校验值打出了通过信息" "$VERIFY_OUT" "SHA256 verification passed"

# A6. 格式合法但内容不符 —— 要报错并删掉损坏文件
VERIFY_RC=0; run_verify "$(printf '0%.0s' {1..64})"
expect_rc "校验值不符时拒绝" "$VERIFY_RC" 1
expect_in "不符时说明是校验失败" "$VERIFY_OUT" "SHA256 verification failed"
if [[ -f "$SAMPLE_FILE" ]]; then
    fail "校验失败后应删除损坏文件（文件仍在）"
else
    pass "校验失败后删除了损坏文件"
fi

# ============================================================
echo
echo "========== B. 端到端拒绝（联网） =========="
# ============================================================

# 配置目录：交给产品自己的解析逻辑（系统级优先，其次用户级），
# 这样设了 LINUXWAVE_TEST 时也能在假根里跑，和 wave 本身看到的是同一个安装目录。
BASE_DIR="$(python3 - "$REPO_DIR" <<'PYEOF' 2>/dev/null
import sys
sys.path.insert(0, sys.argv[1] + "/lib")
from configpaths import load_base_dir
print(load_base_dir())
PYEOF
)" || BASE_DIR=""

if [[ -z "$BASE_DIR" ]]; then
    skip "端到端拒绝（LinuxWave 未安装，解析不到 base_dir）"
else

    # 每次安装都在独立子进程里跑；stdin 关闭，避免任何交互提示挂住
    run_install() {
        INSTALL_OUT="$(python3 "$WAVE_BIN" install "$1" < /dev/null 2>&1)" || INSTALL_RC=$?
        LAST_OUT="$INSTALL_OUT"
    }

    is_network_hiccup() {
        # 网络层失败与「校验值被拒」是两件事：前者应当跳过，后者才是本测试要的结果。
        # 除了自己的友好提示，还要认 requests 直接冒出来的连接错误（raw 被重置时会这样）。
        printf '%s' "$1" | grep -qE \
            'Cannot reach GitHub|GitHub returned HTTP|Connection (aborted|reset|refused)|Max retries exceeded|timed out|Temporary failure'
    }

    # B1. 记录里没有 sha256 字段
    INSTALL_RC=0; run_install "test_no_sha256@1.0.0"
    if is_network_hiccup "$INSTALL_OUT"; then
        skip "缺校验值的包被拒绝（网络不可达，未能走到校验）"
    else
        if [[ "$INSTALL_RC" -ne 0 ]]; then
            pass "缺校验值的包安装失败（退出码 $INSTALL_RC）"
        else
            fail "缺校验值的包竟然安装成功"
        fi
        expect_in "缺校验值时指出是校验值缺失" "$INSTALL_OUT" "No SHA256 checksum"
        if [[ -e "$BASE_DIR/bin/test_no_sha256" || -e "$BASE_DIR/links/test_no_sha256" ]]; then
            fail "缺校验值的包不应留下安装痕迹"
        else
            pass "缺校验值的包没有留下安装痕迹"
        fi
    fi

    # B2. 校验值格式合法但内容错误
    INSTALL_RC=0; run_install "test_wrong_sha256@1.0.0"
    if is_network_hiccup "$INSTALL_OUT"; then
        skip "校验值错误的包被拒绝（网络不可达，未能走到下载）"
    else
        if [[ "$INSTALL_RC" -ne 0 ]]; then
            pass "校验值错误的包安装失败（退出码 $INSTALL_RC）"
        else
            fail "校验值错误的包竟然安装成功"
        fi
        expect_in "校验值错误时说明是校验失败" "$INSTALL_OUT" "SHA256 verification failed"
        if [[ -e "$BASE_DIR/bin/test_wrong_sha256" || -e "$BASE_DIR/links/test_wrong_sha256" ]]; then
            fail "校验值错误的包不应留下安装痕迹"
        else
            pass "校验值错误的包没有留下安装痕迹"
        fi
    fi
fi

# ============================================================
echo
echo "========== C. 三处守卫仍在（静态哨兵） =========="
# ============================================================

# 这三条守卫各自守一层：包记录、依赖记录、安装核心。
# 它们都是「缺校验值就退出」，删掉任何一处都会让那一层重新变得可绕过 ——
# 而外部行为测试只能覆盖到包记录那一层（数据里没有缺校验值的依赖夹具），
# 所以这里补一组静态检查，防止将来重构时被顺手删掉。
sentinel() {
    local label="$1" file="$2" needle="$3"
    if grep -qF "$needle" "$REPO_DIR/$file" 2>/dev/null; then
        pass "$label"
    else
        fail "$label（$file 里找不到「$needle」）"
    fi
}

sentinel "包记录层拒绝缺失校验值" pkg/pkginstaller.py "No SHA256 checksum for"
sentinel "包记录层拒绝畸形校验值" pkg/pkginstaller.py "Malformed SHA256 checksum for"
sentinel "依赖记录层拒绝缺失校验值" surfboard/depsinstaller.py "No SHA256 checksum for dependency"
sentinel "依赖记录层拒绝畸形校验值" surfboard/depsinstaller.py "Malformed SHA256 checksum for dependency"
sentinel "安装核心拒绝缺失校验值" surfboard/depsmanager.sh "No SHA256 checksum in the package data"
sentinel "安装核心拒绝畸形校验值" surfboard/depsmanager.sh "Malformed SHA256 checksum in the package data"

# ============================================================
echo
echo "=========================================="
echo -e "🌊 Passed: $PASSED"
echo -e "🌊 Failed: $FAILED"
echo -e "🌊 Skipped: $SKIPPED"
echo "=========================================="

if [[ "$FAILED" -gt 0 ]]; then
    exit 1
fi
