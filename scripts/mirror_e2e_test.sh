#!/bin/bash

# mirror_e2e_test.sh
# 镜像端到端回归：真的从一个**需要认证**的镜像取字节，而不是只看地址拼得对不对。
#
# 为什么单独有这一份：address 层（domains_test.sh）验的是「地址怎么拼」，payload
# 层（payload_test.sh）验的是「选哪条路」。两者都没有证明最后那一步 —— 字节能不能
# 真的拿到、凭据有没有真的被用上、拿错了会不会被发现。镜像上线前唯一的空白就在这。
#
# 做法：起一个回环上的 HTTP 镜像，要求 Basic 认证；把 bottle 域指过去（域名里的
# 凭据写在 URL 里，与生产同一形状），再用客户端真正在用的两个函数走一遍：
#   domains.resolve_payload  → 决定从哪儿取、文件叫什么
#   pkginstaller.download_file → 真的把字节写下来
# 全程不碰外网，所以断网机器也能跑。

set -u

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

PASSED=0
FAILED=0
pass() { echo -e "${GREEN}🌊 PASS: $1${RESET}"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED_BOLD}🌊 FAIL: $1${RESET}"; FAILED=$((FAILED + 1)); }

WORK="$(mktemp -d)"
SERVER_PID=""
cleanup() {
    [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# ==========================================
# 1. 造一份镜像：<包名>/<文件名>，与 payload_url 的形状一致
#    （域名本身就是存储根，所以路径里不再重复 bottle/deps 段）
# ==========================================

PKG="demo"
VERSION="1.0"
ARCH="amd64"
UPSTREAM_FILENAME="demo.tar.gz"
PAYLOAD="$(python3 -c "
import sys; sys.path.insert(0, '$REPO_DIR/lib')
import domains
print(domains.payload_filename('$PKG', '$VERSION', '$ARCH', '$UPSTREAM_FILENAME'))
")"

MIRROR_ROOT="$WORK/mirror"
mkdir -p "$MIRROR_ROOT/$PKG"
printf 'linuxwave-mirror-payload-%s\n' "$RANDOM$RANDOM" > "$MIRROR_ROOT/$PKG/$PAYLOAD"
EXPECTED_SHA="$(sha256sum "$MIRROR_ROOT/$PKG/$PAYLOAD" | awk '{print $1}')"
echo "🌊 Mirror payload: $PKG/$PAYLOAD  sha256=${EXPECTED_SHA:0:12}…"

if [[ "$PAYLOAD" != "demo@1.0.amd64.tar.gz" ]]; then
    fail "payload 文件名不是预期形状（得到 $PAYLOAD）"
else
    pass "payload 文件名按 <包>@<版本>.<架构><扩展名> 生成"
fi

# ==========================================
# 2. 起一个要求 Basic 认证的镜像
# ==========================================

USER_NAME="gw"
PASSWORD="s3cret-$RANDOM"
PORT="$(python3 -c '
import socket
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
')"

python3 - "$MIRROR_ROOT" "$PORT" "$USER_NAME" "$PASSWORD" > "$WORK/server.log" 2>&1 <<'PY' &
import base64
import http.server
import os
import sys

root, port, user, password = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
expected = "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()


class AuthHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=root, **kwargs)

    def do_GET(self):
        if self.headers.get("Authorization") != expected:
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="LinuxWave mirror"')
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        super().do_GET()

    def log_message(self, *args):
        pass


http.server.HTTPServer(("127.0.0.1", port), AuthHandler).serve_forever()
PY
SERVER_PID=$!

ready=0
for _ in $(seq 1 100); do
    if curl -fsS -o /dev/null --noproxy '*' "http://127.0.0.1:$PORT/" 2>/dev/null \
       || [[ "$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' "http://127.0.0.1:$PORT/" 2>/dev/null)" == "401" ]]; then
        ready=1
        break
    fi
    sleep 0.1
done
if [[ "$ready" == "1" ]]; then
    pass "本地镜像已启动（$PORT，要求 Basic 认证）"
else
    fail "本地镜像没起来"
    sed 's/^/    /' "$WORK/server.log"
    exit 1
fi

# 回环地址必须绕过代理，否则镜像请求会被发到外部代理上
export NO_PROXY="127.0.0.1,localhost,::1${NO_PROXY:+,$NO_PROXY}"
export no_proxy="$NO_PROXY"

# ==========================================
# 3. 认证确实是必需的（否则下面的「成功」不算证据）
# ==========================================

anon_code="$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' \
    "http://127.0.0.1:$PORT/$PKG/$PAYLOAD")"
if [[ "$anon_code" == "401" ]]; then
    pass "不带凭据取镜像 → 401（认证真的生效）"
else
    fail "不带凭据竟然拿到了 $anon_code，这台的「成功」不能证明凭据有用"
fi

# ==========================================
# 4. 走客户端的真实路径：resolve_payload → download_file
# ==========================================

run_case() {
    # run_case <域名> <输出文件>
    local domain="$1" out="$2"
    LINUXWAVE_BOTTLE_DOMAIN="$domain" python3 - "$REPO_DIR" "$out" "$PKG" "$VERSION" \
        "$ARCH" "$UPSTREAM_FILENAME" <<'PY'
import pathlib
import sys

repo, out, name, version, arch, upstream_filename = sys.argv[1:7]
sys.path.insert(0, f"{repo}/lib")
sys.path.insert(0, f"{repo}/pkg")
sys.path.insert(0, f"{repo}/surfboard")

import domains
import pkginstaller


payload = domains.resolve_payload(
    "bottle", name, version, arch, upstream_filename, "", False)

# 用真正的旗标解析生成 config：手写字典会漏键（limit_rate 之类），
# 那样测出来的失败是测试自己的问题，不是客户端的问题。
config = pkginstaller.handle_download_args("wave install " + name)
pkginstaller.download_file(payload["url"], pathlib.Path(out), config, "", name)
print(f"OK {domains.redact_url(payload['url'])}")
PY
}

authed_domain="http://$USER_NAME:$PASSWORD@127.0.0.1:$PORT"
if run_case "$authed_domain" "$WORK/fetched.tgz" > "$WORK/run.log" 2>&1; then
    actual_sha="$(sha256sum "$WORK/fetched.tgz" 2>/dev/null | awk '{print $1}')"
    if [[ "$actual_sha" == "$EXPECTED_SHA" ]]; then
        pass "带凭据从镜像取到了字节，sha256 一致"
    else
        fail "取到了字节但 sha256 不符（$actual_sha != $EXPECTED_SHA）"
    fi
else
    fail "带凭据从镜像取字节失败"
    sed 's/^/    /' "$WORK/run.log"
fi

# 凭据不能出现在任何输出里
if grep -qF "$PASSWORD" "$WORK/run.log"; then
    fail "明文口令出现在了输出里"
else
    pass "输出里没有明文口令"
fi

# ==========================================
# 5. 负向：凭据错了必须失败，不能悄悄回落到什么别的地方
# ==========================================

wrong_domain="http://$USER_NAME:wrong-$PASSWORD@127.0.0.1:$PORT"
if run_case "$wrong_domain" "$WORK/wrong.tgz" > "$WORK/wrong.log" 2>&1; then
    fail "口令错误竟然也取到了字节（镜像认证没被真正校验）"
else
    pass "口令错误时取不到字节（401 被如实报出来）"
fi

# 失败路径才是最会泄漏的地方：用户看到报错就整段贴进工单。
if grep -qF "$PASSWORD" "$WORK/wrong.log"; then
    fail "失败路径把明文口令打出来了（用户会整段贴进工单）"
else
    pass "失败路径的输出里也没有明文口令"
fi

# ==========================================
# 6. 脱敏：错误信息里出现的地址不能带明文口令
# ==========================================

masked="$(python3 -c "
import sys; sys.path.insert(0, '$REPO_DIR/lib')
import domains
print(domains.redact_url('http://$USER_NAME:$PASSWORD@127.0.0.1:$PORT/bottle/$PKG/$PAYLOAD'))
")"
if [[ "$masked" == *"$USER_NAME:***@"* && "$masked" != *"$PASSWORD"* ]]; then
    pass "镜像地址在日志里被脱敏（用户名保留、口令掩掉）"
else
    fail "脱敏结果不对（$masked）"
fi

# ==========================================
# 7. 未配置镜像时必须明确要求配置，而不是拼出一个没有主机的地址
# ==========================================

if LINUXWAVE_BOTTLE_DOMAIN="" python3 -c "
import sys; sys.path.insert(0, '$REPO_DIR/lib')
import domains
try:
    domains.resolve_payload('bottle', '$PKG', '$VERSION', '$ARCH', '$UPSTREAM_FILENAME', '', False)
except SystemExit:
    raise SystemExit(1)
raise SystemExit(0)
" > /dev/null 2>&1; then
    fail "没配 bottle 域却成功拼出了地址（会把请求发到空主机）"
else
    pass "没配镜像时明确报错，不会拼出空主机地址"
fi

echo ""
echo "=========================================="
if [[ "$FAILED" -gt 0 ]]; then
    echo -e "${RED_BOLD}🌊 Mirror end-to-end tests failed: $FAILED${RESET}"
    exit 1
fi
echo -e "${GREEN}🌊 All mirror end-to-end tests passed (${PASSED} checks).${RESET}"
echo "=========================================="
