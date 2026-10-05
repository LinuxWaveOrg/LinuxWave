#!/bin/bash

# transfer.sh
# LinuxWave 🌊 路径替换（ELF 版）：把安装好的产物里所有 ELF 文件的
# RPATH/RUNPATH 改写成 $ORIGIN 相对路径，指向产物自己的 lib/ 与 _DEPS
# 列出的依赖的 lib/，让运行时 ld.so 真正找得到依赖包里的共享库。
#
# 用法: bash transfer.sh <目标目录> <BASE_DIR> 或 /bin/bash bash transfer.sh <目标目录> <BASE_DIR>
#
# 解析优先级：
#   1. 目标目录内部（产物自己的 lib/ lib64/）
#   2. _DEPS 里列出的依赖（deps/{依赖名}/{依赖名}@{版本号}/lib[64]）
#   3. 其余已安装依赖的 lib（兜底，用于传递依赖）
#
# 与 Mach-O 版的区别：ELF 的 DT_NEEDED 只记库名、不含路径，运行期完全靠
# RPATH/RUNPATH 搜索，所以这里重写的就是搜索路径本身；另外 ELF 没有代码签名，
# 改完即用。路径一律写成 $ORIGIN 相对形式，即使整个 BASE_DIR 被搬走也依然有效。
#
# 只处理 ELF（魔数 \x7fELF）：静态链接、无 .dynamic 的 ELF 在此直接跳过。

set -e

# -------------------- 颜色定义 --------------------

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'

# -------------------- 参数与检查 --------------------

TARGET_DIR="$1"
BASE_DIR="$2"

if [[ -z "$TARGET_DIR" || -z "$BASE_DIR" ]]; then
    echo -e "${RED_BOLD}🌊 Error: Missing target directory or base directory.${RESET}"
    exit 1
fi

if [[ ! -d "$TARGET_DIR" ]]; then
    echo -e "${RED_BOLD}🌊 Error: Target directory not found: $TARGET_DIR${RESET}"
    exit 1
fi

if ! command -v patchelf >/dev/null 2>&1; then
    echo -e "${YELLOW}🌊 Warning: 'patchelf' not found, skipping path transfer.${RESET}"
    exit 0
fi

# -------------------- 临时文件 --------------------

LIB_DIRS_FILE="$(mktemp)"
PROVIDED_FILE="$(mktemp)"
SYSTEM_FILE="$(mktemp)"
TREE_FILE="$(mktemp)"
UNRESOLVED_FILE="$(mktemp)"
MISSING_FILE="$(mktemp)"
EXTERNAL_FILE="$(mktemp)"
FAILED_FILE="$(mktemp)"
ERROR_FILE="$(mktemp)"

cleanup() {
    rm -f "$LIB_DIRS_FILE" "$PROVIDED_FILE" "$SYSTEM_FILE" "$TREE_FILE" \
          "$UNRESOLVED_FILE" "$MISSING_FILE" "$EXTERNAL_FILE" "$FAILED_FILE" "$ERROR_FILE"
}
trap cleanup EXIT

# -------------------- 库目录索引（有序、去重） --------------------

add_lib_dir() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        return 0
    fi
    if grep -qxF "$dir" "$LIB_DIRS_FILE" 2>/dev/null; then
        return 0
    fi
    echo "$dir" >> "$LIB_DIRS_FILE"
}

# 1. 目标目录自身
add_lib_dir "$TARGET_DIR/lib"
add_lib_dir "$TARGET_DIR/lib64"

# 2. _DEPS 列出的依赖（优先于其它同名库）
DEPS_FILE="$TARGET_DIR/_DEPS"
if [[ -f "$DEPS_FILE" ]]; then
    while IFS= read -r line; do
        ref="${line//\"/}"
        ref="${ref// /}"

        if [[ -z "$ref" || "$ref" != *@* ]]; then
            continue
        fi

        dep_name="${ref%@*}"
        dep_version="${ref##*@}"
        add_lib_dir "$BASE_DIR/deps/$dep_name/$dep_name@$dep_version/lib"
        add_lib_dir "$BASE_DIR/deps/$dep_name/$dep_name@$dep_version/lib64"
    done < "$DEPS_FILE"
fi

# 3. 其余已安装依赖的 lib（兜底，用于传递依赖）
for dep_tree in "$BASE_DIR"/deps/*/*; do
    if [[ -d "$dep_tree" ]]; then
        add_lib_dir "$dep_tree/lib"
        add_lib_dir "$dep_tree/lib64"
    fi
done

# -------------------- 已经在我们树里的库名 --------------------

# PROVIDED：出现在上面这些 lib 目录里的库文件名 —— 能靠 RUNPATH 解析的
while IFS= read -r dir; do
    for file in "$dir"/*; do
        if [[ -f "$file" ]]; then
            basename "$file" >> "$PROVIDED_FILE"
        fi
    done
done < "$LIB_DIRS_FILE"

# TREE：整棵树里出现过的文件名 —— 用于分辨“我们有但没接上”与“根本不属于我们”
tree_add_tree() {
    local root="$1"
    local file
    while IFS= read -r file; do
        basename "$file"
    done < <(find "$root" -type f 2>/dev/null)
}

tree_add_tree "$TARGET_DIR" >> "$TREE_FILE"
for dep_tree in "$BASE_DIR"/deps/*/*; do
    if [[ -d "$dep_tree" ]]; then
        tree_add_tree "$dep_tree" >> "$TREE_FILE"
    fi
done

# -------------------- 系统库名（不计入“未声明依赖”） --------------------

# libc/libm/ld.so 这类系统本来就有的库由加载器的默认搜索路径兜底，
# 不该被报成“未被任何已安装依赖提供”。ldconfig -p 能覆盖绝大部分。
{
    echo "libc.so.6"
    echo "libm.so.6"
    echo "libdl.so.2"
    echo "librt.so.1"
    echo "libpthread.so.0"
    echo "libresolv.so.2"
    echo "libutil.so.1"
    echo "libnsl.so.1"
    echo "libcrypt.so.1"
    echo "libgcc_s.so.1"
    echo "libstdc++.so.6"
} >> "$SYSTEM_FILE"

if command -v ldconfig >/dev/null 2>&1; then
    ldconfig -p 2>/dev/null | awk '/=>/ {print $1}' >> "$SYSTEM_FILE" || true
fi

# -------------------- 辅助函数 --------------------

is_elf() {
    # 按魔数判断；静态库（!<arch>）、脚本、数据文件在此直接滤掉。
    local file="$1"
    local magic
    magic="$(head -c 4 "$file" 2>/dev/null | od -An -tx1 | tr -d ' \n')"

    case "$magic" in
        7f454c46)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

is_system_lib() {
    # 系统自带的库：动态加载器本身，以及 ldconfig -p 里登记过的
    local name="$1"
    case "$name" in
        ld-linux*.so*|ld.so*)
            return 0
            ;;
    esac
    grep -qxF "$name" "$SYSTEM_FILE" 2>/dev/null
}

declare -A RPATH_REL_CACHE

build_rpath_for_file() {
    # 输出该文件应有的 RUNPATH（$ORIGIN 相对形式，按 LIB_DIRS 顺序），
    # 无需重定位时输出空串。同一个文件目录的 relpath 只算一次。
    local file="$1"
    local file_dir
    file_dir="$(dirname "$file")"

    local rpath=""
    local dir rel entry key

    while IFS= read -r dir; do
        key="$file_dir|$dir"
        if [[ -n "${RPATH_REL_CACHE[$key]+set}" ]]; then
            rel="${RPATH_REL_CACHE[$key]}"
        else
            rel="$(realpath --relative-to="$file_dir" "$dir" 2>/dev/null || true)"
            RPATH_REL_CACHE[$key]="$rel"
        fi

        if [[ -z "$rel" ]]; then
            continue
        fi

        if [[ "$rel" == "." ]]; then
            entry='$ORIGIN'
        else
            entry="\$ORIGIN/$rel"
        fi

        if [[ -z "$rpath" ]]; then
            rpath="$entry"
        else
            rpath="$rpath:$entry"
        fi
    done < "$LIB_DIRS_FILE"

    printf '%s' "$rpath"
}

# -------------------- 逐个 ELF 替换 --------------------

CHANGED=0

while IFS= read -r file; do
    if ! is_elf "$file"; then
        continue
    fi

    # 没有 .dynamic（静态链接）的 ELF 不参与重定位
    if ! current_rpath="$(patchelf --print-rpath "$file" 2>/dev/null)"; then
        continue
    fi

    new_rpath="$(build_rpath_for_file "$file")"

    if [[ -n "$new_rpath" && "$current_rpath" != "$new_rpath" ]]; then
        if patchelf --set-rpath "$new_rpath" "$file" 2>"$ERROR_FILE"; then
            CHANGED=$((CHANGED + 1))
        else
            # 不要静默：改不动的话这个二进制运行时一定加载失败
            echo "$file|$new_rpath|$(head -n 1 "$ERROR_FILE")" >> "$FAILED_FILE"
        fi
    fi

    # 收集仍未解析的 DT_NEEDED（仅用于最后报告）
    while IFS= read -r needed; do
        if [[ -z "$needed" ]]; then
            continue
        fi

        # 我们的树里有同名库 → 能靠 RUNPATH 解析
        if grep -qxF "$needed" "$PROVIDED_FILE" 2>/dev/null; then
            continue
        fi

        # 系统库（含动态加载器本身）→ 交给默认搜索路径
        if is_system_lib "$needed"; then
            continue
        fi

        echo "$needed" >> "$UNRESOLVED_FILE"
    done < <(patchelf --print-needed "$file" 2>/dev/null || true)
done < <(find "$TARGET_DIR" -type f 2>/dev/null)

# -------------------- 输出 --------------------

if [[ "$CHANGED" -gt 0 ]]; then
    echo "🌊 Relocated $CHANGED ELF file(s) in ${TARGET_DIR#"$BASE_DIR"/}"
fi

if [[ -s "$FAILED_FILE" ]]; then
    failed_count="$(wc -l < "$FAILED_FILE" | tr -d ' ')"
    echo -e "${YELLOW}🌊 Warning: $failed_count file(s) could not be relocated:${RESET}"
    while IFS='|' read -r failed_file failed_rpath failed_reason; do
        echo -e "${YELLOW}🌊   ${failed_file#"$BASE_DIR"/}${RESET}"
        if [[ -n "$failed_reason" ]]; then
            echo -e "${YELLOW}🌊     $failed_reason${RESET}"
        fi
    done < <(sort -u "$FAILED_FILE" | head -10)
    echo -e "${YELLOW}🌊 These binaries will fail to load their libraries at runtime.${RESET}"
fi

if [[ -s "$UNRESOLVED_FILE" ]]; then
    # 分流：我们树里存在同名文件 → 真的没接上（警告）；
    #       树里根本没有 → 外部/未声明的依赖，LinuxWave 无从接，只作提示。
    while IFS= read -r ref; do
        if grep -qxF "$ref" "$TREE_FILE" 2>/dev/null; then
            echo "$ref" >> "$MISSING_FILE"
        else
            echo "$ref" >> "$EXTERNAL_FILE"
        fi
    done < "$UNRESOLVED_FILE"

    if [[ -s "$MISSING_FILE" ]]; then
        missing_count="$(wc -l < "$MISSING_FILE" | tr -d ' ')"
        echo -e "${YELLOW}🌊 Warning: $missing_count library reference(s) exist in this installation but could not be linked:${RESET}"
        sort -u "$MISSING_FILE" | head -10 | while IFS= read -r ref; do
            echo -e "${YELLOW}🌊   $ref${RESET}"
        done
    fi

    if [[ -s "$EXTERNAL_FILE" ]]; then
        external_count="$(wc -l < "$EXTERNAL_FILE" | tr -d ' ')"
        echo "🌊 Note: $external_count library reference(s) not provided by any installed dependency, left to the system loader:"
        sort -u "$EXTERNAL_FILE" | head -10 | while IFS= read -r ref; do
            echo "🌊   $ref"
        done
    fi
fi

exit 0
