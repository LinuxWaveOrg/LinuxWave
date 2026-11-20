#!/usr/bin/env python3

# common.py

# 公共旗标的**唯一解析入口**。
#
# 「公共」= cli/flags.py 里 GLOBAL 那一组：-v / -C / --skip-ssl / --limit-rate /
# --proxy / --max-time / --connect-timeout / --content-time /
# --install-python-from-source。
#
# 为什么必须只有一份：同一个 --proxy，install 会校验协议、再写进 requests 的
# proxies；selfupdate 只从环境变量拿值，于是 `wave selfupdate --proxy foo` 一声不响
# 地忽略，`wave install jq --proxy foo` 报错退出。旗标的**含义**不该取决于哪条
# 命令在读它。解析与校验收到这里之后，同样的输入在任何命令下都得到同样的结果、
# 同样的报错与同样的退出码。
#
# 分层，三层各管一件事，不要互相越界：
#
#   cli/flags.py     词法：一个词怎么拆成旗标名（纯函数，不打印、不退出）
#   net/timeouts.py  时长语义：40s / 1min20s / 2h → 秒，以及 Budget 的组装
#   cli/common.py    ★ 本文件：把上面两层拼成「这次命令行的公共选项」，
#                    校验与报错只在这里发生
#   各 handler        只消费 parse() 的结果，不再自己 flag_value()
#
# 白名单校验仍归各命令自己（pkginstaller.ALLOWED_FLAGS 等）：哪些旗标**能出现**
# 是每条命令的事，而它们**是什么意思**是这里的事。

import difflib
import os
import re
import sys

import flags
import timeouts


RED_BOLD = '\033[1;31m'
RESET = '\033[0m'

# --proxy 只认这三种前缀。别的写法不是「用法偏好」，是打错了 —— 而打错的代理
# 如果被静默忽略，用户看到的是「网络不通」，会去查网络。
PROXY_SCHEMES = ("http://", "https://", "socks5://")

# `--proxy` 的值写进这些环境变量，这条命令的**所有**请求就都走代理：
# requests（trust_env 默认开）、urllib、以及 bash 子脚本里的 curl 都读它们。
# 逐个改造调用点做不到 —— requests.get 有十来处，还有一整层 bash。
PROXY_ENV_VARS = ("HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY",
                  "https_proxy", "http_proxy", "all_proxy")

# 取值类旗标 → 报错时给一条能照抄的写法。键就是这里认的全部取值旗标。
VALUE_EXAMPLES = {
    "--proxy": "http://127.0.0.1:8080",
    "--limit-rate": "400K",
    "--max-time": "1min",
    "--connect-timeout": "10s",
    "--content-time": "1min",
}


class Options:
    """一次命令行的公共选项。字段都是「解析完、校验过」的终值。"""

    __slots__ = ("verbose", "resume", "skip_ssl", "install_python_from_source",
                 "proxy", "limit_rate", "timeout_raws", "timeouts")

    def __init__(self):
        self.verbose = False
        self.resume = False
        self.skip_ssl = False
        self.install_python_from_source = False
        self.proxy = ""
        self.limit_rate = None
        self.timeout_raws = {}
        self.timeouts = timeouts.Budget()

    def __repr__(self):
        return (f"Options(verbose={self.verbose}, resume={self.resume}, "
                f"skip_ssl={self.skip_ssl}, proxy={self.proxy!r}, "
                f"limit_rate={self.limit_rate}, timeouts={self.timeouts})")


# -------------------- 解析 --------------------

def _words(source):
    return source.split() if isinstance(source, str) else list(source)


def parse(source):
    """解析公共旗标。source 可以是命令行文本，也可以是已经 split 过的词列表。

    不属于公共旗标的词一律跳过 —— 「这条命令认不认某个旗标」由各命令的白名单
    决定；这里只回答「值是多少、合不合法」。取值不合法时报错并退出 1。
    """
    words = _words(source)
    options = Options()
    raws = {}
    index = 0

    while index < len(words):
        word = words[index]
        index += 1

        if word == "-":
            # 单独一个 - 之后全是参数，与 install / latest 的约定一致
            break
        if not word.startswith("-"):
            continue

        if not word.startswith("--"):
            # 短旗标簇：-v、-C、-vC。簇里别的字母（-s、-X、-F…）是各命令的事，
            # 这里不认也不拒绝。
            for letter in flags.short_cluster(word) or "":
                if letter == "v":
                    options.verbose = True
                elif letter == "C":
                    options.resume = True
            continue

        name, has_inline, inline = word.partition("=")
        if name == "--verbose":
            options.verbose = True
        elif name == "--continue":
            options.resume = True
        elif name == "--skip-ssl":
            options.skip_ssl = True
        elif name == "--install-python-from-source":
            options.install_python_from_source = True
        elif name in VALUE_EXAMPLES:
            raw, index = _take(words, index, name, has_inline, inline)
            _apply(options, raws, name, raw)

    # 时长统一交给 net/timeouts.py：它才是「40s 是多少秒」的唯一实现
    options.timeout_raws = raws
    options.timeouts = timeouts.from_values(raws, fail=cannot_parse)
    return options


def _take(words, index, name, has_inline, inline):
    """取出一个取值类旗标的值：`--name=value` 直接用，`--name value` 取下一个词。"""
    if has_inline:
        return inline, index
    if index < len(words):
        return words[index], index + 1
    return "", index


def _apply(options, raws, name, raw):
    if raw == "":
        needs_value(name)

    if name == "--proxy":
        if not raw.startswith(PROXY_SCHEMES):
            print('🌊 Proxy error, please check your network proxy settings, '
                  'whether the input is correct, or contact your ISP.')
            sys.exit(1)
        options.proxy = raw
    elif name == "--limit-rate":
        rate = parse_rate_limit(raw)
        if rate is None:
            cannot_parse(name, raw)
        options.limit_rate = rate
    else:
        # 时长旗标：原样留文本，换算交给 timeouts.from_values
        raws[name] = raw


def value(source, name):
    """取某个取值类旗标的**原始文本**（不做校验）；没有给返回 None。

    给「只有某条命令认识」的取值旗标用（如 install 的 --ver）。公共旗标请走
    parse() —— 那条路径才会校验。
    """
    words = _words(source)
    for index, word in enumerate(words):
        if word == "-":
            break
        if word == name:
            return words[index + 1] if index + 1 < len(words) else ""
        if word.startswith(name + "="):
            return word[len(name) + 1:]
    return None


def parse_rate_limit(text):
    """`400K` / `2M` / `1048576` → 每秒字节数；看不懂返回 None。"""
    raw = (text or "").strip().upper()
    multipliers = {"K": 1024, "M": 1024 ** 2, "G": 1024 ** 3}
    unit = raw[-1:]
    number = raw[:-1] if unit in multipliers else raw
    try:
        return float(number) * multipliers.get(unit, 1)
    except ValueError:
        return None


# -------------------- 报错（全仓只有这一份） --------------------

def needs_value(flag):
    print(f"{RED_BOLD}🌊 Error: {flag} needs a value, "
          f"e.g. {flag}={VALUE_EXAMPLES[flag]}.{RESET}")
    sys.exit(1)


def cannot_parse(flag, raw):
    print(f"{RED_BOLD}🌊 Error: cannot parse {flag} value '{raw}'.{RESET}")
    if flag == "--limit-rate":
        print(f"{RED_BOLD}🌊 Use a number of bytes per second, "
              f"or a suffix like 400K, 2M.{RESET}")
    else:
        print(f"{RED_BOLD}🌊 Use a number of seconds or a suffix like "
              f"40s, 1min, 1min20s, 2h.{RESET}")
    sys.exit(1)


# -------------------- 副作用 --------------------

def apply_proxy(options):
    """把 --proxy 落进进程环境。返回写进去的值；没写则返回空字符串。

    刻意做成「全局」：命令行上写了 --proxy，这条命令就不该有任何请求绕过它 ——
    漏掉的那一处会以「Cannot fetch @common file」这种和代理毫无关系的面貌出现。
    """
    if not options.proxy:
        return ""
    for name in PROXY_ENV_VARS:
        os.environ[name] = options.proxy
    return options.proxy


# -------------------- 旗标白名单校验 --------------------
#
# 「这条命令认哪些旗标」的唯一判定处。各 handler 不再各写一遍词法循环与报错文案 ——
# 以前 install 报 "Input contains illegal fields"，upgrade 报自己的那句，
# uninstall 打一行警告就忽略（用户以为生效了，链接照样被改）。
#
# 白名单 = flags.GLOBAL（任何命令都收）+ 这条命令独有的那组。别名按规范名判断，
# 所以 `--unlink` 与 `--no-link` 在 install/uninstall 上等价。
#
# 放在 common.py 而不是 flags.py：flags.py 是纯函数（不打印、不退出），
# 这条要报错退出。

# 普通红：与「未知命令」那块的配色一致（旗标与 ^ 用 31，不用加粗红）
RED = '\033[31m'
RESET = '\033[0m'


def allowed_for(command):
    """这条命令接受的旗标名（含公共旗标）。"""
    return flags.GLOBAL | flags.COMMAND_FLAGS.get(command, set())


def _pointer(text, flag):
    """把「you ran:」做成两行：命令行原样，下面用 ^ 指向出错的旗标。

    与「未知命令」的呈现方式一致 —— 命令行长的时候（好几个旗标加限速加超时），
    只靠整行变红看不出是哪一段出的问题。

    位置必须按词边界找，不能用 str.find：`--ver` 会命中 `--verbose`，
    `--connect-time` 若写成子串匹配也会先撞上前缀更长的写法。caret 只覆盖
    旗标本身，不含 `=<值>`。
    """
    label = "you ran: "
    if not flag or not text:
        return label + text

    offset = None
    for match in re.finditer(re.escape(flag) + r"(?==|\s|$)", text):
        start = match.start()
        if start == 0 or text[start - 1].isspace():
            offset = start
            break
    if offset is None:
        return label + text

    tail = text[offset + len(flag):]
    shown = f"{text[:offset]}{RED}{flag}{RESET}{tail}"
    carets = " " * (len(label) + offset) + "^" * len(flag)
    return f"{RESET}{label}{shown}\n{RED}{carets}"


def check_allowed(input_string, command, shown=None, allow_from=None):
    """校验旗标白名单；不在名单里的报错退出。返回拆出来的旗标名列表。

    command:   报错时说的命令名（`illegal option X for wave <command>`）。
    shown:     回显用的命令行。upgrade 内部会构造一条 `wave install placeholder …`
               的探针来复用 install 的白名单，那条探针只该用于解析，不该给用户看。
    allow_from: 白名单取自哪条命令，缺省就是 command 自己。upgrade 传 "install"：
               upgrade 能接受的就是 install 能接受的（去掉 -X/--all 这些它自己剥掉的），
               多出来的那两个由 upgrader 的 REJECTED_FLAGS 给出更贴切的替代做法。
    """
    found = flags.tokens(input_string.split(" "))
    allowed = allowed_for(allow_from or command)

    for flag in found:
        if flag in allowed or flags.ALIASES.get(flag, flag) in allowed:
            continue

        import silent
        import steplog

        # 静默模式：整段解释对脚本没用，给一行可匹配的即可。
        # 但要分清两种「不接受」：拼错了，还是这条命令不认它。
        if silent.is_silent():
            description = flags.describe(flag)
            if description:
                silent.misplaced(flag, description)
            else:
                silent.unknown("flag", flag)
            sys.exit(1)

        text = (shown or input_string).strip()
        description = flags.describe(flag)
        hint = []
        if description:
            # 是 LinuxWave 的旗标、只是不属于这条命令：说明它属于谁就够了。
            # 这时再猜拼写只会添乱 —— `--ver` 会被猜成 `--verbose`。
            hint.append(description)
        else:
            # 真正的拼错：给一个候选。候选只从**这条命令的白名单**里取，
            # 所以不会推荐一条这里不接受的长参数。
            suggestion = difflib.get_close_matches(flag, sorted(allowed), n=1, cutoff=0.6)
            if suggestion:
                hint.append(f"Did you mean {suggestion[0]}?")
        hint.append(f"`wave {command} --help` lists the flags this command accepts")
        steplog.fail(f"illegal option {flag} for `wave {command}`",
                     extra=_pointer(text, flag), hint=hint, usage=True)

    return found


# -------------------- 三档超时交给 shell --------------------

# 旗标名 → 传给 shell 脚本的环境变量。**传原始文本**，让脚本自己再解析一次：
# 换算规则只有 net/timeouts.py 一份，脚本那边（lib/install.sh / lib/selfupdate.sh）
# 只负责把它变成 curl 的旗标。若这里先算成秒，「1min 是多少秒」就有了两份实现。
TIMEOUT_ENV = {
    "--max-time": "LINUXWAVE_MAX_TIME",
    "--connect-timeout": "LINUXWAVE_CONNECT_TIMEOUT",
    "--content-time": "LINUXWAVE_CONTENT_TIME",
}


def export_timeouts(options, environ=None):
    """把命令行上给了的那几档超时写进环境变量；没给的就不设。

    不设而不是清空：脚本按自己的默认值走（元数据 30 秒、单个文件 60/180 秒），
    与「用户没写这个旗标」是同一件事。
    """
    target = os.environ if environ is None else environ
    for flag, name in TIMEOUT_ENV.items():
        raw = options.timeout_raws.get(flag)
        if raw:
            target[name] = raw
        else:
            target.pop(name, None)


def curl_limit_args(options):
    """把三档超时翻成 curl 的旗标（本层自己发请求时用）。

    curl 侧一一对应：握手是 --connect-timeout，总额是 --max-time；
    「连上了多久收不到数据算失败」没有同名旗标，用 --speed-limit 1 --speed-time N
    表达 —— 阈值压到 1 字节/秒，等价于「只要还在收数据就不算超时」。
    """
    budget = options.timeouts
    return ["--max-time", str(max(1, int(round(budget.total)))),
            "--connect-timeout", str(max(1, int(round(budget.connect)))),
            "--speed-limit", "1", "--speed-time", str(max(1, int(round(budget.content))))]
