#!/bin/bash

# payload_test.sh
# B 档接线的回归（离线）：`resolve_payload()` 现在真的被调用了，
# 但「什么时候用它」是**调用方**的决定，这里把三种情形钉死：
#   1. 没配镜像（BOTTLE/DEPS 为空）→ 仍按索引的 `url` 取（3.1.x 的既有行为，不能被改坏）；
#   2. 配了镜像 → 按 4.0 的 payload 命名从我们自己的存储取；
#   3. `--install-from-source` → 一律回上游，即使配了镜像。
#
# 另附数据前置条件：走镜像时索引必须带 `file` 字段，缺了要硬失败而不是瞎猜扩展名。

set -u

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
LIB_DIR="$REPO_DIR/lib"

PASSED=0
FAILED=0

pass() {
    echo -e "${GREEN}🌊 PASS: $1${RESET}"
    PASSED=$((PASSED + 1))
}

fail() {
    echo -e "${RED_BOLD}🌊 FAIL: $1${RESET}"
    FAILED=$((FAILED + 1))
}

collect() {
    local verdict text
    while IFS='|' read -r verdict text; do
        case "$verdict" in
            PASS) pass "$text" ;;
            FAIL) fail "$text" ;;
        esac
    done
}

echo "========== 1. 什么时候走镜像 =========="

collect < <(python3 - "$REPO_DIR" <<'PY'
import contextlib
import io
import os
import sys

repo = sys.argv[1]
for sub in ("lib", "pkg", "surfboard"):
    sys.path.insert(0, f"{repo}/{sub}")

import domains


def report(ok, text):
    print(("PASS|" if ok else "FAIL|") + text)


def quiet(func, *args, **kwargs):
    buffer = io.StringIO()
    with contextlib.redirect_stdout(buffer), contextlib.redirect_stderr(buffer):
        return func(*args, **kwargs)


# 1. 没配镜像：保持原样，按索引 url 取
for kind, env in (("bottle", "LINUXWAVE_BOTTLE_DOMAIN"), ("deps", "LINUXWAVE_DEPS_DOMAIN")):
    os.environ.pop(env, None)
    report(domains.use_mirror_for(kind) is False, f"没配 {env} 时不上镜像（回落到 url）")

# 2. 配了镜像：走我们自己的存储
os.environ["LINUXWAVE_BOTTLE_DOMAIN"] = "https://mirror.example/LinuxWave/bottle"
os.environ["LINUXWAVE_DEPS_DOMAIN"] = "https://mirror.example/LinuxWave/deps"
report(domains.use_mirror_for("bottle") is True, "配了 BOTTLE 就走镜像")
report(domains.use_mirror_for("deps") is True, "配了 DEPS 就走镜像")

# 3. --install-from-source 优先，即使配了镜像
report(domains.use_mirror_for("bottle", from_source=True) is False,
       "--install-from-source 强制回上游（即使配了镜像）")

# 4. payload 命名：真实数据形状
payload = quiet(domains.resolve_payload, "bottle", "zoxide", "0.10.0", "amd64",
                "zoxide-0.10.0-x86_64-unknown-linux-gnu.tar.gz",
                "https://upstream.example/zoxide-0.10.0-x86_64-unknown-linux-gnu.tar.gz", False)
report(payload["filename"] == "zoxide@0.10.0.amd64.tar.gz",
       "镜像文件名按 payload 规则（保留 .tar.gz）")
expected_path = "https://mirror.example/LinuxWave/bottle/zoxide/zoxide@0.10.0.amd64.tar.gz"
# `payload_url` 会对文件名做 percent-encoding（`@` → `%40`），静态服务器解码后即得原名。
# 这是预期的线上形态：镜像上的文件名仍是 `zoxide@0.10.0.amd64.tar.gz`。
from urllib.parse import unquote

report(unquote(payload["url"]) == expected_path, "镜像 URL = 域 + 包名 + 文件名（解码后）")
report("%40" in payload["url"] and "@0.10.0" not in payload["url"],
       "URL 里 @ 被编码为 %40（服务器解码即得原名）")

bare = quiet(domains.resolve_payload, "bottle", "yq", "4.54.1", "arm64",
             "yq_linux_arm64", "https://upstream.example/yq_linux_arm64", False)
report(bare["filename"] == "yq@4.54.1.arm64", "裸二进制不带扩展名")

# 5. 走镜像但数据缺 file：必须硬失败（否则扩展名靠猜，解压会选错工具）
try:
    quiet(domains.resolve_payload, "bottle", "x", "1.0", "amd64", "",
          "https://upstream.example/x.tar.gz", False)
except SystemExit:
    report(True, "走镜像但缺 file 字段时硬失败")
else:
    report(False, "走镜像但缺 file 字段时硬失败（却放行了）")

# 6. from_source 分支不需要 file 字段
try:
    result = quiet(domains.resolve_payload, "bottle", "x", "1.0", "amd64", "",
                   "https://upstream.example/x.tar.gz", True)
    report(result["url"] == "https://upstream.example/x.tar.gz", "--install-from-source 直接用 url")
except SystemExit:
    report(False, "--install-from-source 直接用 url（却退出了）")
PY
)

echo ""
echo "========== 2. 安装器真的会读这个判定 =========="

collect < <(python3 - "$REPO_DIR" <<'PY'
import contextlib
import io
import os
import sys

repo = sys.argv[1]
for sub in ("lib", "pkg", "surfboard"):
    sys.path.insert(0, f"{repo}/{sub}")

import pkginstaller


def report(ok, text):
    print(("PASS|" if ok else "FAIL|") + text)


def quiet(func, *args, **kwargs):
    buffer = io.StringIO()
    with contextlib.redirect_stdout(buffer), contextlib.redirect_stderr(buffer):
        return func(*args, **kwargs)


report("--install-from-source" in pkginstaller.ALLOWED_FLAGS,
       "--install-from-source 在 install 的白名单里")
report(pkginstaller.parse_flags("wave install jq --install-from-source") == ["--install-from-source"],
       "parse_flags 接受 --install-from-source")
report(pkginstaller.first_package_token("wave install --install-from-source jq") == "jq",
       "--install-from-source 不会被当作包名")

config = quiet(pkginstaller.handle_download_args, "wave install jq")
report(config["from_source"] is False, "默认 from_source=False")
config = quiet(pkginstaller.handle_download_args, "wave install jq --install-from-source")
report(config["from_source"] is True, "--install-from-source 置 from_source=True")
PY
)

echo ""
echo "=========================================="
if [[ "$FAILED" -gt 0 ]]; then
    echo -e "${RED_BOLD}🌊 payload tests failed: $FAILED${RESET}"
    echo "=========================================="
    exit 1
fi
echo -e "${GREEN}🌊 All payload tests passed (${PASSED} checks).${RESET}"
echo "=========================================="
