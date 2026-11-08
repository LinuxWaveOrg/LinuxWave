#!/usr/bin/env python3

# configpaths.py
# 解析 LinuxWave 的配置目录。
#
# 安装目录决定配置写在哪：
#   - 系统级（/opt/linuxwave、/usr/local/linuxwave 等需要 sudo 的目录）
#     → /etc/linuxwave_config
#   - 用户级（~/.local/linuxwave 等无需 sudo 的目录）
#     → ~/.config/linuxwave_config
#
# 读取时系统级优先：只要 /etc/linuxwave_config/config.json 存在就用它，
# 否则才回落到 ~/.config/linuxwave_config —— 也就是优先跑系统级的 LinuxWave。

import json
import os
import re
import unicodedata
import sys
from pathlib import Path


# -------------------- 颜色定义 --------------------

RED_BOLD = '\033[1;31m'
RESET = '\033[0m'


# -------------------- 测试根（隔离） --------------------

def _resolve_test_root():
    # LINUXWAVE_TEST 指向一个目录时，程序把这个目录当作 /：所有绝对路径都挂到它
    # 下面，HOME 也搬进去，于是配置目录、安装目录、下载缓存全落在里面，完全不
    # 碰真实系统。没设置时（正常使用）一切照旧。
    raw = os.environ.get("LINUXWAVE_TEST")
    if not raw:
        return None

    if raw == "~" or raw.startswith("~/"):
        real_home = os.environ.get("HOME") or str(Path.home())
        raw = real_home + raw[1:]

    root = Path(raw)
    if not root.is_absolute():
        root = Path.cwd() / root
    root = root.resolve()
    root.mkdir(parents=True, exist_ok=True)
    return root


TEST_ROOT = _resolve_test_root()

if TEST_ROOT is not None:
    # HOME 一起搬进测试根：~/.config/linuxwave_config、~/.local/linuxwave 都该隔离。
    # 子进程（bash 脚本）继承这个 HOME，所以整条链路都在测试根里。
    _real_home = Path(os.environ.get("HOME") or Path.home())
    _test_home = TEST_ROOT / (_real_home.relative_to("/") if _real_home.is_absolute() else "home")
    _test_home.mkdir(parents=True, exist_ok=True)
    os.environ["HOME"] = str(_test_home)
    # 给 shell 脚本用：它们拿不到 Python 的变量，只能走环境变量
    os.environ["LINUXWAVE_TEST_ROOT"] = str(TEST_ROOT)


def rooted(path):
    # 把绝对路径映射到测试根之下；没开测试模式时原样返回。
    # 例如 /etc/linuxwave_config → $LINUXWAVE_TEST/etc/linuxwave_config
    path = Path(path)
    if TEST_ROOT is None or not path.is_absolute():
        return path
    return TEST_ROOT / path.relative_to("/")


# -------------------- 配置目录候选 --------------------

CONFIG_FILE_NAME = "config.json"
VERSION_FILE_NAME = "VERSION.json"

SYSTEM_CONFIG_DIR = rooted("/etc/linuxwave_config")
USER_CONFIG_DIR = Path.home() / ".config" / "linuxwave_config"


def config_dir_candidates():
    # 系统级优先，其次用户级
    return [SYSTEM_CONFIG_DIR, USER_CONFIG_DIR]


# -------------------- 配置读取 --------------------

def _read_base_dir(config_file):
    # 读得到合法 base_dir 就返回 Path，否则返回 None
    try:
        with open(config_file, 'r') as handle:
            base_dir = json.load(handle).get("base_dir")
        return Path(base_dir) if base_dir else None
    except Exception:
        return None


def find_config_dir():
    # 第一个装了 LinuxWave 的配置目录（config.json 合法且含 base_dir）；都没装时返回 None
    for directory in config_dir_candidates():
        if _read_base_dir(directory / CONFIG_FILE_NAME) is not None:
            return directory
    return None


def load_base_dir():
    # 按系统级 → 用户级的顺序读取 base_dir，读到就返回
    for directory in config_dir_candidates():
        base_dir = _read_base_dir(directory / CONFIG_FILE_NAME)
        if base_dir is not None:
            return base_dir

    print(f"{RED_BOLD}🌊 Error: Configuration file not found or invalid.{RESET}")
    print(f"{RED_BOLD}🌊 Please run the install script again to reinstall LinuxWave.{RESET}")
    sys.exit(1)


# -------------------- 代理（--proxy 全局生效） --------------------
#
# `--proxy` 必须对这条命令的**所有**请求生效，不只是下载包体那一步。
# 以前它只影响 requests 的下载参数：取索引、取 @common、取依赖信息全都绕过它，
# 内网用户在下载任何字节之前就撞上「Cannot fetch @common file」，看着像参数没生效。
#
# 与其逐个改造调用点（requests.get 有十来处，还有 bash 子脚本里的 curl），
# 不如把值写进进程环境：requests（trust_env 默认开）、urllib、curl 都读环境变量，
# 于是这条命令的所有请求都自动走代理，子进程也一并继承。
# 这是刻意的「全局」语义：命令行上写了 --proxy，这条命令就不该有任何请求绕过它。

PROXY_ENV_VARS = ("HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY",
                  "https_proxy", "http_proxy", "all_proxy")

PROXY_SCHEMES = ("http://", "https://", "socks5://")


def proxy_value_from(argv):
    # 从命令行里取 --proxy 的值；支持 `--proxy X` 与 `--proxy=X`，没有则返回 ""。
    tokens = list(argv)
    for index, token in enumerate(tokens):
        if token == "--proxy":
            return tokens[index + 1] if index + 1 < len(tokens) else ""
        if token.startswith("--proxy="):
            return token[len("--proxy="):]
    return ""


def apply_proxy_from_command_line(argv):
    # 校验协议后写进环境变量。不合法的值交给原来的解析路径去报错（这里只跳过），
    # 免得同一条命令在两处报出不同的错。
    value = proxy_value_from(argv).strip()
    if not value:
        return ""

    if not value.startswith(PROXY_SCHEMES):
        return ""

    for name in PROXY_ENV_VARS:
        os.environ[name] = value
    return value


# -------------------- 名字与版本号的安全校验 --------------------
#
# 包名、版本号、可执行文件名既来自命令行，也来自远端数据（@common / deps 字段），
# 之后会被拼进 URL 和文件路径，还会以换行分隔的长字符串形式交给 shell。
# 所以这里做统一的白名单校验，外加"最终路径必须在 BASE_DIR 之内"的兜底。

# 允许的字符按 Unicode 类别判定，而不是 ASCII 白名单：这样中文包名（Lo）、
# é 这类带重音的名字（L + Mn）也合法，而不必逐个把字符加进白名单。
# 刻意不含 / \ % @ : 空白 与换行——它们要么能改变目录层级（路径穿越），
# 要么能做 URL 注入（%2f 之类），要么能往 shell 里注入额外字段。
NAME_CATEGORIES = frozenset({
    'Lu', 'Ll', 'Lt', 'Lm', 'Lo',   # 字母
    'Mn', 'Mc', 'Me',               # 组合符号，如 e + U+0301
    'Nd', 'Nl', 'No',               # 数字
})

# 首字符必须是字母或数字：挡住开头的 -（选项注入）、. 与组合符号（同形异义伪装）。
START_CATEGORIES = frozenset({'Lu', 'Ll', 'Lt', 'Lm', 'Lo', 'Nd', 'Nl', 'No'})

ALLOWED_PUNCT = frozenset('._+-')

# 落盘名是「包名@版本.架构.扩展名」时多放行一个 @（B 档启用后才会用到）。
# @ 在 shell 里无特殊含义（全程引号引用），进 URL 时由 domains.payload_url 编码成 %40。
ALLOWED_PUNCT_FILENAME = ALLOWED_PUNCT | {'@'}

MAX_NAME_CHARS = 128
# 非 ASCII 一个字最多占 4 字节，而 Linux 的 NAME_MAX 是 255 **字节**，
# 所以除了字符数还要卡字节数，否则长中文包名会在落盘时才炸「File name too long」。
MAX_NAME_BYTES = 200


def _category(ch):
    return unicodedata.category(ch)


def _matches_name(value, punct):
    value = str(value)
    if not value or len(value) > MAX_NAME_CHARS:
        return False
    if '..' in value:
        return False
    if len(value.encode('utf-8')) > MAX_NAME_BYTES:
        return False
    if _category(value[0]) not in START_CATEGORIES:
        return False
    return all(ch in punct or _category(ch) in NAME_CATEGORIES for ch in value)


def is_safe_token(value):
    return _matches_name(value, ALLOWED_PUNCT)


def is_safe_filename(value):
    return _matches_name(value, ALLOWED_PUNCT_FILENAME)


def require_safe_token(value, what):
    # 不合法直接退出：这类输入没有任何"宽松解释"的余地
    if not is_safe_token(value):
        print(f"{RED_BOLD}🌊 Error: Unsafe {what}: {value!r}{RESET}")
        print(f"{RED_BOLD}🌊 Allowed: letters (any script), digits, and . _ + - "
              f"(must start with a letter or digit).{RESET}")
        print(f"{RED_BOLD}🌊 Path separators, whitespace, control characters and shell "
              f"metacharacters are never allowed.{RESET}")
        sys.exit(1)
    return str(value)


def _inside_failure(resolved, resolved_root, what):
    print(f"{RED_BOLD}🌊 Error: Unsafe {what} escapes {resolved_root}: {resolved}{RESET}")
    sys.exit(1)


def assert_inside(path, root, what):
    # 归一化后确认路径没有跑到 root 外面（防 ../ 与软链接穿越）。
    # 只做校验、不改写调用方的路径，避免改变既有行为。
    # **跟随**最后一段的软链接：用于会被写进去或递归删除的路径。
    resolved_root = Path(root).resolve()
    resolved = Path(path).resolve()
    if resolved != resolved_root and resolved_root not in resolved.parents:
        _inside_failure(resolved, resolved_root, what)
    return resolved


def assert_inside_entry(path, root, what):
    # 与 assert_inside 相同，但**不跟随**最后一段的软链接。links/ 下的链接本身就
    # 是软链接，指向 bin/ 里的可执行文件：跟随过去会把"删除/重指这个链接"这种
    # 再正常不过的操作误判成越界。只能用于"操作链接本身"、不会穿透写入的调用点。
    resolved_root = Path(root).resolve()
    candidate = Path(path)
    if candidate.name in ("", ".", ".."):
        _inside_failure(candidate, resolved_root, what)
    resolved = candidate.parent.resolve() / candidate.name
    if resolved != resolved_root and resolved_root not in resolved.parents:
        _inside_failure(resolved, resolved_root, what)
    return resolved


# -------------------- 产物里的符号链接 --------------------
#
# 规则：软件包里带的符号链接，解析后必须落在 base_dir 内；落在外面一律拒绝。
#
# 为什么要单独做这件事：归档解压只过滤成员**名字**里的 `../`，与链接**目标**无关。
# 实测 Python 3.15 的 tarfile：filter='tar' 会把 `x -> /etc/passwd` 原样解出来，
# 只有 filter='data' 才拒绝（但它连 conda 包需要的合法链接一起拒）。unzip 与
# tar 命令行同样不管目标。所以越界链接只能解压之后自己扫。
#
# 危害两头：链接指向隐私文件 → 随包附带的程序读到不该读的东西；链接指向
# LinuxWave 之后要写的路径（patchelf 重定位改写、.part → mv、卸载的 rm -rf）
# → 以用户身份在树外写或删。
#
# 例外只给系统库位置，两个条件必须同时成立：
#   1. 那里只有发行版自带的二进制与库，没有用户数据 —— 「顺着链接去读」不成立；
#   2. 这些路径在所有主流发行版上都归 root 所有，普通用户（包括共享安装里那个
#      组）写不进去 —— 「顺着链接去写」不成立。
# 第二条比 macOS 的 SIP 弱：它靠的是文件属主，不是强制访问控制。所以清单只留
# 系统库目录本身，绝不放宽到 /opt、/usr/local 这类「可能被用户自己接管」的位置。

SYSTEM_LINK_PREFIXES = (
    "/bin",
    "/sbin",
    "/lib",
    "/lib64",
    "/usr/bin",
    "/usr/sbin",
    "/usr/lib",
    "/usr/lib64",
    "/usr/libexec",
)


def _under(path, prefix):
    return path == prefix or path.startswith(prefix + os.sep)


def is_system_link_target(resolved):
    """链接目标是否落在豁免的系统库位置。"""
    text = str(resolved)
    return any(_under(text, prefix) for prefix in SYSTEM_LINK_PREFIXES)


def escaping_links(root):
    """遍历 root，返回 [(链接, 解析后的目标)] —— 只在解析后落在 root 与豁免之外。

    不跟随目录软链接（否则可能绕进别的树里无限走），但**每个链接本身**都会被解析，
    包括指向目录的链接：指向树外的目录链接同样是「顺着它能读写树外」。
    悬空链接也照常判定 —— resolve() 不要求目标存在，词法上跑出 root 就算越界。
    """
    resolved_root = Path(root).resolve()
    found = []
    for dirpath, dirnames, filenames in os.walk(resolved_root, followlinks=False):
        for name in dirnames + filenames:
            candidate = Path(dirpath) / name
            if not candidate.is_symlink():
                continue
            try:
                target = Path(os.readlink(candidate))
            except OSError:
                continue
            if not target.is_absolute():
                target = candidate.parent / target
            try:
                resolved = target.resolve()
            except (OSError, RuntimeError):
                # 自我引用或过长的链：没法解析，按越界处理（拒绝比放行安全）
                found.append((candidate, target))
                continue
            if resolved != resolved_root and resolved_root not in resolved.parents:
                if not is_system_link_target(resolved):
                    found.append((candidate, resolved))
    return found


def assert_links_inside(root, what):
    """把一个树里越界的符号链接当作致命错误。"""
    offenders = escaping_links(root)
    if not offenders:
        return
    print(f"{RED_BOLD}🌊 Error: {len(offenders)} symbolic link(s) in {what} point outside "
          f"{Path(root).resolve()}{RESET}", file=sys.stderr)
    for link, target in offenders[:10]:
        print(f"   {link} -> {target}", file=sys.stderr)
    if len(offenders) > 10:
        print(f"   … and {len(offenders) - 10} more", file=sys.stderr)
    print("🌊 A link that leaves the install root can read private files, or make a later "
          "write (relocation, rename, uninstall) land outside the tree.", file=sys.stderr)
    print(f"🌊 Only these locations are exempt: {', '.join(SYSTEM_LINK_PREFIXES)}", file=sys.stderr)
    print("🌊 Refusing this payload. Report it to the index maintainer.", file=sys.stderr)
    sys.exit(1)


# -------------------- 当前生效的配置 --------------------

CONFIG_DIR = find_config_dir() or SYSTEM_CONFIG_DIR
CONFIG_FILE = CONFIG_DIR / CONFIG_FILE_NAME
VERSION_FILE = CONFIG_DIR / VERSION_FILE_NAME


if __name__ == "__main__":
    # 唯一的命令行入口：解压之后由 depsmanager.sh 调用，检查产物里的符号链接。
    #   python3 lib/configpaths.py --check-links <目录> <描述，仅用于报错>
    if len(sys.argv) >= 3 and sys.argv[1] == "--check-links":
        assert_links_inside(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else sys.argv[2])
        sys.exit(0)
    print("🌊 This module is not meant to be run directly.")
    print("🌊 It is used internally by the other LinuxWave modules.")
    sys.exit(1)
