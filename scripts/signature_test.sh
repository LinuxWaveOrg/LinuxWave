#!/bin/bash

# signature_test.sh
# 信任链回归：**哈希与签名验不过时必须说出来**，严格模式下必须失败。
#
# 覆盖三段：
#   A. lw_check_integrity —— 期望值为空 / 一致 / 不一致（警告）/ 不一致 + 严格模式
#   B. lw_verify_latest_signature —— 没有公钥 / .sig 缺失 / 签名正确 / 签名不对
#      （警告与严格模式各一次）。.sig 用 file:// 取，全程不联网。
#   C. 内置公钥与 Keys/ 同步（scripts/embed_rsa_pub.py --check）
#
# 用法: bash scripts/signature_test.sh
# 本机需要有 openssl 与 bash 4.4+。

set -u

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
INSTALL_SH="$REPO_DIR/lib/install.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo -e "  ${GREEN}✅ $1${RESET}"; }
fail() { FAIL=$((FAIL + 1)); echo -e "  ${RED_BOLD}❌ $1${RESET}"; }
report() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1（期望 '$3'，得到 '$2'）"; fi; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 把信任链那几个函数与它们依赖的输出函数摘出来，单独 source。
# 摘取按标记走，避免把整份安装器（会先判平台）拖进来。
extract() {
    {
        echo 'RED_BOLD=""; GREEN=""; YELLOW=""; RESET=""'
        echo 'LW_LANG="en"'
        echo 'lw_say() { printf "%b\n" "$1"; }'
        echo 'lw_say_err() { printf "%b\n" "$1" >&2; }'
        awk '/^LW_RSA_PUB_TMP=""$/{f=1} f{print} f&&/^# <<< RSA public key <<<$/{exit}' "$INSTALL_SH"
    } > "$WORK/trust.sh"
}

extract
if [[ ! -s "$WORK/trust.sh" ]] || ! grep -q "lw_verify_latest_signature" "$WORK/trust.sh"; then
    echo -e "${RED_BOLD}🌊 Error: 摘不出信任链函数（install.sh 里的标记变了？）${RESET}"
    exit 1
fi

echo "========== A. 哈希校验 =========="
printf 'hello\n' > "$WORK/file"
GOOD="$(openssl dgst -sha256 -r "$WORK/file" | awk '{print $1}')"
BAD="0000000000000000000000000000000000000000000000000000000000000000"

out="$(bash -c 'source "$1"; lw_check_integrity x "$2" "" && echo ok' _ "$WORK/trust.sh" "$WORK/file" 2>&1)"
report "期望值为空时放行" "$out" "ok"

out="$(bash -c 'source "$1"; lw_check_integrity x "$2" "$3" && echo ok' _ "$WORK/trust.sh" "$WORK/file" "$GOOD" 2>&1)"
report "哈希一致时放行且不啰嗦" "$out" "ok"

out="$(bash -c 'source "$1"; lw_check_integrity x "$2" "$3" && echo ok' _ "$WORK/trust.sh" "$WORK/file" "$BAD" 2>&1)"
case "$out" in
    *ok*) pass "哈希不一致时（非严格）继续" ;;
    *) fail "哈希不一致时（非严格）不该中断" ;;
esac
case "$out" in
    *"does not match the signed data"*) pass "哈希不一致时说清楚了" ;;
    *) fail "哈希不一致时没有提示（$out）" ;;
esac

bash -c 'source "$1"; LINUXWAVE_STRICT_HASHES=1; lw_check_integrity x "$2" "$3"' \
    _ "$WORK/trust.sh" "$WORK/file" "$BAD" > /dev/null 2>&1
report "严格模式下哈希不一致直接失败" "$?" "1"

echo "========== B. 探针签名 =========="
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$WORK/good.key" 2>/dev/null
openssl pkey -in "$WORK/good.key" -pubout -out "$WORK/good.pub" 2>/dev/null
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$WORK/other.key" 2>/dev/null

printf 'version = "9.9.9"\nbranch = "main"\n' > "$WORK/latest.toml"
openssl dgst -sha256 -sign "$WORK/good.key" -out "$WORK/latest.toml.sig" "$WORK/latest.toml" 2>/dev/null

verify() {  # verify <公钥路径或空> <严格模式 ?> [附加 env]
    local pub="$1" strict="$2"
    local envs=()
    [[ -n "$pub" ]] && envs+=("LINUXWAVE_RSA_PUB=$pub")
    [[ "$strict" == "1" ]] && envs+=("LINUXWAVE_STRICT_HASHES=1")
    env "${envs[@]}" bash -c 'source "$1"; d="$(cat "$2")"; lw_verify_latest_signature "$d" "$3"; echo "rc=$?"' \
        _ "$WORK/trust.sh" "$WORK/latest.toml" "file://$WORK/latest.toml" 2>&1
}

out="$(verify "" 0)"
case "$out" in
    *"rc=0"*) pass "没有公钥时整段跳过" ;;
    *) fail "没有公钥时不该报错（$out）" ;;
esac
case "$out" in
    *"signature OK"*) fail "没有公钥时不该说签名通过" ;;
    *) pass "没有公钥时不谎报通过" ;;
esac

out="$(verify "$WORK/good.pub" 0)"
case "$out" in
    *"signature OK"*) pass "签名正确时明确说通过" ;;
    *) fail "签名正确却没报通过（$out）" ;;
esac

out="$(verify "$WORK/other.pub" 0)"
case "$out" in
    *"rc=0"*) pass "签名不对时（非严格）继续" ;;
    *) fail "签名不对时（非严格）不该中断（$out）" ;;
esac
case "$out" in
    *"not signed by the trusted key"*) pass "签名不对时说清楚了" ;;
    *) fail "签名不对时没有提示（$out）" ;;
esac

LINUXWAVE_RSA_PUB="$WORK/other.pub" LINUXWAVE_STRICT_HASHES=1 \
    bash -c 'source "$1"; d="$(cat "$2")"; lw_verify_latest_signature "$d" "$3"' \
    _ "$WORK/trust.sh" "$WORK/latest.toml" "file://$WORK/latest.toml" > /dev/null 2>&1
report "严格模式下签名不对直接失败" "$?" "1"

mv "$WORK/latest.toml.sig" "$WORK/latest.toml.sig.bak"
out="$(verify "$WORK/good.pub" 0)"
case "$out" in
    *"No signature"*) pass ".sig 缺失时按「这一版没签名」处理" ;;
    *) fail ".sig 缺失时应说明没签名（$out）" ;;
esac
case "$out" in
    *"rc=0"*) pass ".sig 缺失不算错误" ;;
    *) fail ".sig 缺失不该失败（$out）" ;;
esac
mv "$WORK/latest.toml.sig.bak" "$WORK/latest.toml.sig"

echo "========== C. 内置公钥同步 =========="
if python3 "$SCRIPT_DIR/embed_rsa_pub.py" --check > /dev/null 2>&1; then
    pass "install.sh 内置公钥与 Keys/ 一致"
else
    fail "内置公钥与 Keys/ 不一致（跑 python3 scripts/embed_rsa_pub.py）"
fi

echo "------------------------------------------------------------"
if [[ "$FAIL" -ne 0 ]]; then
    echo -e "${RED_BOLD}🌊 $FAIL 项失败，$PASS 项通过${RESET}"
    exit 1
fi
echo -e "${GREEN}🌊 全部 $PASS 项通过${RESET}"
