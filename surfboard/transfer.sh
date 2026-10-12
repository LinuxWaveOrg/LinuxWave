#!/bin/bash

# transfer.sh
# LinuxWave 🌊 路径替换（ELF 版）：把安装好的产物里所有 ELF 文件的
# RPATH/RUNPATH 改写成 $ORIGIN 相对路径，指向产物自己的 lib/ 与 _DEPS
# 列出的依赖的 lib/，让运行时 ld.so 真正找得到依赖包里的共享库。
#
# 用法: bash transfer.sh <目标目录> <BASE_DIR> [共享索引目录]
#   /bin/bash bash transfer.sh <目标目录> <BASE_DIR> [共享索引目录]
#
# 第三个参数（或用环境变量 LINUXWAVE_SHARED_INDEX）给一个目录时，依赖侧的索引
# （整棵依赖树的名字表、依赖 lib 里的库名）会缓存到那个目录、只建一次。统一收尾
# 会对**每个**已装依赖各调一次本脚本，每次都重扫全部依赖树就是 O(依赖数²)：
# 18 个依赖 = 324 次全树扫描。不给这个参数时行为与以前一致（每次都现场建）。
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
SHARED_INDEX_DIR="${3:-${LINUXWAVE_SHARED_INDEX:-}}"

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
ELF_LIST_FILE="$(mktemp)"

cleanup() {
    rm -f "$LIB_DIRS_FILE" "$PROVIDED_FILE" "$SYSTEM_FILE" "$TREE_FILE" \
          "$UNRESOLVED_FILE" "$MISSING_FILE" "$EXTERNAL_FILE" "$FAILED_FILE" \
          "$ERROR_FILE" "$ELF_LIST_FILE"
}
trap cleanup EXIT

# -------------------- 库目录索引（有序、去重） --------------------

declare -A SEEN_LIB_DIRS

# 目录去重改用关联数组，不再每个目录 fork 一次 grep。
add_lib_dir() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        return 0
    fi
    if [[ -n "${SEEN_LIB_DIRS[$dir]+set}" ]]; then
        return 0
    fi
    SEEN_LIB_DIRS[$dir]=1
    printf '%s\n' "$dir" >> "$LIB_DIRS_FILE"
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

# 列出这些目录里的库名。逐文件 fork 一个 basename，在 libevent/ncurses 那种几百个
# 符号链接的库里会直接压过重定位本身，所以用内建 ${f##*/} 取名字，重定向放循环外。
dir_lib_names() {
    local dir file
    for dir in "$@"; do
        if [[ ! -d "$dir" ]]; then
            continue
        fi
        for file in "$dir"/*; do
            if [[ -f "$file" ]]; then
                printf '%s\n' "${file##*/}"
            fi
        done
    done
    return 0
}

# 整棵树里出现过的文件名 —— 用于分辨“我们有但没接上”与“根本不属于我们”。
# 软链接也要进索引：conda 的库里 libfoo.so.1 往往是指向 libfoo.so.1.2.3 的软链接，
# 只找 -type f 会漏掉它，于是"我们有但没接上"会被误判成"不属于我们"。
tree_add_tree() {
    local file
    while IFS= read -r file; do
        printf '%s\n' "${file##*/}"
    done < <(find "$1" \( -type f -o -type l \) 2>/dev/null)
}

# 依赖侧的内容对所有 target 都一样：走共享索引只建一次，先写临时文件再 mv，
# 避免半截索引被后面的 target 复用。否则统一收尾时每个 target 都要把全部依赖重扫一遍。
dep_lib_names() {
    local dep_tree
    for dep_tree in "$BASE_DIR"/deps/*/*; do
        if [[ -d "$dep_tree" ]]; then
            dir_lib_names "$dep_tree/lib" "$dep_tree/lib64"
        fi
    done
    return 0
}

dep_tree_names() {
    local dep_tree
    for dep_tree in "$BASE_DIR"/deps/*/*; do
        if [[ -d "$dep_tree" ]]; then
            tree_add_tree "$dep_tree"
        fi
    done
    return 0
}

# 缓存到共享目录；没有共享目录（或建不出来）时就地现算，行为与优化前一致。
cached_dep_scan() {
    local cache_name="$1" builder="$2"
    local cache_path="" cache_tmp
    if [[ -n "$SHARED_INDEX_DIR" ]] && mkdir -p "$SHARED_INDEX_DIR" 2>/dev/null; then
        cache_path="$SHARED_INDEX_DIR/$cache_name"
    fi

    if [[ -n "$cache_path" && ! -f "$cache_path" ]]; then
        cache_tmp="$(mktemp)"
        "$builder" > "$cache_tmp"
        mv -f "$cache_tmp" "$cache_path"
    fi

    if [[ -n "$cache_path" ]]; then
        cat "$cache_path"
    else
        "$builder"
    fi
}

# PROVIDED：这些 lib 目录里的库名 —— 能靠 RUNPATH 解析的。
# 依赖那一份必须独立扫 deps/*/*，不能用上面那份去重后的目录表：那份表会把“本 target
# 自己”的 lib 目录剔掉，而缓存是给所有 target 复用的，别的 target 就此看不到这些库名。
dir_lib_names "$TARGET_DIR/lib" "$TARGET_DIR/lib64" > "$PROVIDED_FILE"
cached_dep_scan dep_lib_names dep_lib_names >> "$PROVIDED_FILE"

tree_add_tree "$TARGET_DIR" >> "$TREE_FILE"
cached_dep_scan dep_tree_names dep_tree_names >> "$TREE_FILE"

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

# 系统库名单装进关联数组：每个未解析的 DT_NEEDED 都要查一次，逐次 fork grep 很贵。
declare -A SYSTEM_SET
while IFS= read -r name; do
SYSTEM_SET[$name]=1
done < "$SYSTEM_FILE"

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
    [[ -n "${SYSTEM_SET[$name]+set}" ]]
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

# 后面两轮判断（是不是我们提供的库名 / 树里有没有同名文件）都是纯查表，
# 装进关联数组即可，免得每个符号都去 fork 一次 grep。
declare -A PROVIDED_SET TREE_SET
while IFS= read -r name; do
    PROVIDED_SET[$name]=1
done < "$PROVIDED_FILE"
while IFS= read -r name; do
    TREE_SET[$name]=1
done < "$TREE_FILE"

# 一次 Python 扫描挑出 ELF：原来是 find -type f 之后每个文件再 fork
# head|od|tr 三个进程去读魔数，文件一多就是几万次 fork。python3 不可用时退回老办法。
ELF_FILES=()
if command -v python3 >/dev/null 2>&1 && python3 -c '
import os, stat, sys

MAGIC = b"\x7fELF"

for root, _dirs, files in os.walk(sys.argv[1]):
    for name in files:
        path = os.path.join(root, name)
        try:
            # 与 find -type f 对齐：不跟随软链接，只要普通文件
            if not stat.S_ISREG(os.lstat(path).st_mode):
                continue
            with open(path, "rb") as handle:
                if handle.read(4) != MAGIC:
                    continue
        except OSError:
            continue
        sys.stdout.write(path + "\n")
' "$TARGET_DIR" > "$ELF_LIST_FILE"; then
    mapfile -t ELF_FILES < "$ELF_LIST_FILE"
else
    while IFS= read -r candidate; do
        if is_elf "$candidate"; then
            ELF_FILES+=("$candidate")
        fi
    done < <(find "$TARGET_DIR" -type f 2>/dev/null)
fi

CHANGED=0

for file in "${ELF_FILES[@]}"; do
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
        if [[ -n "${PROVIDED_SET[$needed]+set}" ]]; then
            continue
        fi

        # 系统库（含动态加载器本身）→ 交给默认搜索路径
        if is_system_lib "$needed"; then
            continue
        fi

        echo "$needed" >> "$UNRESOLVED_FILE"
    done < <(patchelf --print-needed "$file" 2>/dev/null || true)
done

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
        if [[ -n "${TREE_SET[$ref]+set}" ]]; then
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
