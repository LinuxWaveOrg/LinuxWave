#!/bin/bash

# python_source_test.sh
# `--install-python-from-source` 与「自带解释器从哪儿取」的回归（离线）。
#
# 三条规则：默认先试我们自己托管的 `pythondata/<版本>/<文件名>`，没有才回落到数据里的上游地址；
# 加了 `--install-python-from-source` 就**直接用上游**，连试都不试我们的存储。
#
# 做法是把 `ensure_portable_python` 从 install.sh / selfupdate.sh 里原文抽出来，
# 配上最小的桩与一个 fake 归档（内含 python/bin/python3）跑真实流程 —— 因此这里覆盖
# 的是实现本身，而不是另一份复制品。两个脚本必须给出同样的结论。

set -u

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

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

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "========== 0. 造一个能过校验的假解释器包 =========="

VERSION="9.9.9"
SRC="$WORK/src/python"
mkdir -p "$SRC/bin"
printf '#!/bin/sh\nexit 0\n' > "$SRC/bin/python3"
chmod +x "$SRC/bin/python3"
ARCHIVE="$WORK/portable-python-$VERSION.tar.gz"
tar -C "$WORK/src" -czf "$ARCHIVE" python
SHA="$(sha256sum "$ARCHIVE" | awk '{print $1}')"
echo "  假归档 $(stat -c%s "$ARCHIVE") 字节  sha256=${SHA:0:12}…"

# 数据文件（与 pythondata/latest_python 同形）
DATA="$WORK/configdata/pythondata"
mkdir -p "$DATA"
write_data() {
    local url="$1"
    {
        echo "version: \"$VERSION\""
        echo "amd64_url: \"$url\""
        echo "amd64_sha256: \"$SHA\""
        echo "arm64_url: \"$url\""
        echo "arm64_sha256: \"$SHA\""
    } > "$DATA/latest_python"
}

# 上游副本
mkdir -p "$WORK/upstream"
cp "$ARCHIVE" "$WORK/upstream/python.tar.gz"

run_case() {
    # run_case <脚本路径> <托管副本是否存在> <是否加旗标>
    # 打印：ok/skip/hosted/upstream
    local script="$1" hosted_present="$2" from_source="$3"
    local store="$WORK/store-$RANDOM"
    local install="$WORK/install-$RANDOM"
    mkdir -p "$install/downloads/tmp"

    if [[ "$hosted_present" == "yes" ]]; then
        mkdir -p "$store/pythondata/$VERSION"
        cp "$ARCHIVE" "$store/pythondata/$VERSION/python.tar.gz"
    else
        mkdir -p "$store/pythondata/$VERSION"
    fi
    write_data "file://$WORK/upstream/python.tar.gz"

    (
        set -u
        # 只注入被测函数需要的东西：颜色、日志、run_cmd、路径归一化与解释器探测
        CONFIGDATA_URL="file://$WORK/configdata"
        PYTHON_DATA_URL="file://$store"
        run_cmd() { "$@"; }
        # 只有真存在才算「已装」——桩写得太宽松会让函数误判成已安装、直接跳过下载
        # 注意：不能写成 `local dir="$1" p="$dir/..."` —— 同一个 local 里 $dir 还没绑定，
        # set -u 下会直接报「未绑定的变量」，函数于是静默返回空。
        portable_python_binary() {
            local dir="$1"
            local p="$dir/python/bin/python3"
            [[ -x "$p" ]] && printf '%s\n' "$p"
        }
        normalize_portable_python() { :; }
        # selfupdate.sh 的下载走 fetch_to_file（自带重试）；这里给个等价桩
        fetch_to_file() { local url="$1" dest="$2" limit="$3"; run_cmd curl -fsSL --max-time "$limit" -o "$dest" "$url"; }
        port_arch() { echo amd64; }

        eval "$(sed -n '/^ensure_portable_python() {/,/^}$/p' "$script")"

        export LINUXWAVE_PYTHON_FROM_SOURCE="${from_source}"
        if [[ "$from_source" == "yes" ]]; then
            export LINUXWAVE_PYTHON_FROM_SOURCE=1
        else
            unset LINUXWAVE_PYTHON_FROM_SOURCE
        fi

        output="$(ensure_portable_python "$install" amd64 2>&1)"
        rc=$?
        echo "RC=$rc"
        echo "$output" | grep -q 'No hosted copy' && echo "FELL_BACK=1" || echo "FELL_BACK=0"
    )
}

unset LINUXWAVE_TEST LINUXWAVE_SKIP_PORTABLE_PYTHON LINUXWAVE_PYTHON_FROM_SOURCE

for script in "$REPO_DIR/lib/install.sh" "$REPO_DIR/lib/selfupdate.sh"; do
    name="$(basename "$script")"
    echo ""
    echo "========== $name =========="

    # ① 托管有副本 → 用它，不该出现回落提示
    out="$(run_case "$script" yes no)"
    if grep -q '^RC=0' <<< "$out" && grep -q '^FELL_BACK=0' <<< "$out"; then
        pass "$name：有托管副本时直接用（无回落提示）"
    else
        fail "$name：有托管副本时的行为不对（$(tr '\n' ' ' <<< "$out")）"
    fi

    # ② 托管没有副本 → 回落到上游，并且明确说出来
    out="$(run_case "$script" no no)"
    if grep -q '^RC=0' <<< "$out" && grep -q '^FELL_BACK=1' <<< "$out"; then
        pass "$name：没有托管副本时回落到上游并提示"
    else
        fail "$name：没有托管副本时没有回落（$(tr '\n' ' ' <<< "$out")）"
    fi

    # ③ 加旗标 → 即使托管有副本也直接走上游（用「托管副本是坏的」来证明它没被读）
    #    这里让托管目录里放一个坏文件，走上游才可能成功
    store_bad="$WORK/store-bad-$name"
    mkdir -p "$store_bad/pythondata/$VERSION"
    printf 'not a tarball\n' > "$store_bad/pythondata/$VERSION/python.tar.gz"
    install="$WORK/install-flag-$name"
    mkdir -p "$install/downloads/tmp"
    write_data "file://$WORK/upstream/python.tar.gz"

    out="$(
        set -u
        CONFIGDATA_URL="file://$WORK/configdata"
        PYTHON_DATA_URL="file://$store_bad"
        run_cmd() { "$@"; }
        # 只有真存在才算「已装」——桩写得太宽松会让函数误判成已安装、直接跳过下载
        # 注意：不能写成 `local dir="$1" p="$dir/..."` —— 同一个 local 里 $dir 还没绑定，
        # set -u 下会直接报「未绑定的变量」，函数于是静默返回空。
        portable_python_binary() {
            local dir="$1"
            local p="$dir/python/bin/python3"
            [[ -x "$p" ]] && printf '%s\n' "$p"
        }
        normalize_portable_python() { :; }
        # selfupdate.sh 的下载走 fetch_to_file（自带重试）；这里给个等价桩
        fetch_to_file() { local url="$1" dest="$2" limit="$3"; run_cmd curl -fsSL --max-time "$limit" -o "$dest" "$url"; }
        unset LINUXWAVE_TEST LINUXWAVE_SKIP_PORTABLE_PYTHON
        eval "$(sed -n '/^ensure_portable_python() {/,/^}$/p' "$script")"
        export LINUXWAVE_PYTHON_FROM_SOURCE=1
        ensure_portable_python "$install" amd64 2>&1
        echo "RC=$?"
    )"
    if grep -q '^RC=0' <<< "$out"; then
        pass "$name：加旗标时跳过坏掉的托管副本、直接走上游"
    else
        fail "$name：加旗标时仍然读了托管副本（$(tr '\n' ' ' <<< "$out")）"
    fi
done

echo ""
echo "========== 路径形状必须与 domains.py 一致 =========="
# 上面跑的是真实现，但 URL 是我在 shell 里手写的一份；domains.py 里有同一个结论
# （python_archive_url）。两边各写一次就必须比对，否则改了其中一边只是少下载一次。

while IFS='|' read -r verdict text; do
    [[ "$verdict" == "PASS" ]] && pass "$text"
    [[ "$verdict" == "FAIL" ]] && fail "$text"
done < <(python3 - "$REPO_DIR" <<'PY'
import re
import sys

repo = sys.argv[1]
sys.path.insert(0, f"{repo}/lib")
import domains

version, filename = "3.14.9", "cpython-amd64.tar.gz"
canonical = domains.python_archive_url(version, filename)

pattern = re.compile(r'\$PYTHON_DATA_URL(/\S*?)/\$version/\$\(basename "\$url"\)')
for name in ("install.sh", "selfupdate.sh"):
    text = open(f"{repo}/lib/{name}", encoding="utf-8").read()
    match = pattern.search(text)
    if not match:
        print(f"FAIL|{name}：找不到托管副本的地址拼装（被改掉了？）")
        continue
    prefix = match.group(1)
    built = f"{domains.python_data_domain()}{prefix}/{version}/{filename}"
    if built == canonical:
        print(f"PASS|{name}：托管地址与 domains.python_archive_url 一致")
    else:
        print(f"FAIL|{name}：托管地址是 {built}，domains.py 说是 {canonical}")
PY
)

echo ""
echo "========== 命令行旗标 =========="

while IFS='|' read -r verdict text; do
    [[ "$verdict" == "PASS" ]] && pass "$text"
    [[ "$verdict" == "FAIL" ]] && fail "$text"
done < <(python3 - "$REPO_DIR" <<'PY'
import os
import sys

repo = sys.argv[1]
for sub in ("lib", "pkg", "surfboard"):
    sys.path.insert(0, f"{repo}/{sub}")

import selfupdate

os.environ.pop("LINUXWAVE_PYTHON_FROM_SOURCE", None)
selfupdate._apply_python_source("wave selfupdate")
print(("PASS|" if "LINUXWAVE_PYTHON_FROM_SOURCE" not in os.environ else "FAIL|")
      + "不加旗标时不动环境变量")

selfupdate._apply_python_source("wave selfupdate --install-python-from-source")
print(("PASS|" if os.environ.get("LINUXWAVE_PYTHON_FROM_SOURCE") == "1" else "FAIL|")
      + "加旗标时置 LINUXWAVE_PYTHON_FROM_SOURCE=1")
PY
)

echo ""
echo "=========================================="
if [[ "$FAILED" -gt 0 ]]; then
    echo -e "${RED_BOLD}🌊 python source tests failed: $FAILED${RESET}"
    echo "=========================================="
    exit 1
fi
echo -e "${GREEN}🌊 All python source tests passed (${PASSED} checks).${RESET}"
echo "=========================================="
