#!/usr/bin/env python3

# selfupdate.py

import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request


# -------------------- 颜色定义 --------------------

RED_BOLD = '\033[1;31m'
GREEN = '\033[32m'
YELLOW = '\033[33m'
RESET = '\033[0m'


# -------------------- 常量 --------------------

import domains
import silent
from configpaths import VERSION_FILE_NAME, config_dir_candidates, find_config_dir, load_base_dir

# -------------------- 同意记录 --------------------
#
# 安装器把「用户同意的是哪一版协议」写进配置目录的 AGREEMENT.json，值就是这里的
# AGREEMENT_ID。CI 装完再跑 `wave selfupdate` 时据此免去再问一次 —— 否则无人值守
# 的流水线会卡在一个没人看的提示符上。
#
# 改协议内容时**必须**同时改 AGREEMENT_ID（用协议生效日期），否则已经同意旧协议
# 的用户会被当成同意过新的。
AGREEMENT_ID = "2026-11-19"
AGREEMENT_FILE_NAME = "AGREEMENT.json"


# 4.0 起的两级结构：latest.toml 说「装哪个版本」，该版本的 update_commands.sh 说「怎么装」。
# 前者每次发版都变，后者按版本冻结 —— 装了旧版本的人继续用他们那份说明，而旧版本仍在运行。
#
# 本层只回答「有没有新版」；下载与落盘由 lib/selfupdate.sh 取回那份脚本再执行。
LATEST_TOML_URL = domains.selfupdate_latest_url()
FETCH_TIMEOUT = domains.DEFAULT_TIMEOUT
UPDATE_TIMEOUT = 1800


# -------------------- 版本数据 --------------------

def fetch_url_text(url):
    """取一段文本：优先标准库，本地 Python 缺根证书时改走 curl。取不到返回 None。"""
    try:
        with urllib.request.urlopen(url, timeout=FETCH_TIMEOUT) as response:
            return response.read().decode()
    except (urllib.error.URLError, UnicodeDecodeError, OSError):
        pass

    result = subprocess.run(['curl', '-fsSL', '--max-time', str(FETCH_TIMEOUT), url],
                            capture_output=True, text=True)
    if result.returncode != 0:
        return None
    return result.stdout


def parse_toml(text):
    """只认本项目的用法：`key = "value"`，`#` 开头是注释，其余忽略。

    4.0 的 latest.toml 就长这样（上游用真正的 TOML，但字段只有四个字符串），
    为此引一个 TOML 解析器不值得 —— 但解析必须严格：值不带引号就当不存在，
    免得半行残缺被当成版本号。
    """
    fields = {}
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, separator, value = line.partition("=")
        key = key.strip()
        value = value.strip()
        if not separator or not key:
            continue
        if len(value) >= 2 and value.startswith('"') and value.endswith('"'):
            fields[key] = value[1:-1]
    return fields


def resolve_release():
    """返回版本数据；取不到或没有 version 字段时返回 None。

    只有 4.0 的 linuxwavedata/latest.toml 一种布局 —— 3.x 的
    versiondata/latest_version 与 files_info 一起退休了，回落会让「读到了什么」
    变成两说。
    """
    text = fetch_url_text(LATEST_TOML_URL)
    if not text:
        return None
    data = parse_toml(text)
    return data if data.get("version") else None


def run_script(environment, overall_timeout):
    """执行 lib/selfupdate.sh。它负责取回 update_commands.sh 并跑它。

    **必须从临时副本执行**：更新过程会覆盖 lib/selfupdate.sh 自己，而 bash 是
    边读边执行的，被覆盖的正文会让运行中的脚本读到半截内容。复制一份再跑，
    覆盖就发生在「已经读完的副本」之外，不影响本次执行。
    """
    source = os.path.join(os.path.dirname(os.path.abspath(__file__)), "selfupdate.sh")

    print("🌊 Preparing the update script for this version...")

    try:
        with open(source, encoding="utf-8") as stream:
            text = stream.read()
    except OSError:
        print(f"{RED_BOLD}🌊 Error: Cannot read the update script.{RESET}")
        print(f"{RED_BOLD}🌊 {source}{RESET}")
        sys.exit(1)

    handle, path = tempfile.mkstemp(prefix="linuxwave-selfupdate-", suffix=".sh")
    try:
        with os.fdopen(handle, "w") as stream:
            stream.write(text)
        return subprocess.run(['/bin/bash', path], env=environment, timeout=overall_timeout)
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


def version_key(value):
    # 只比较数字段（2.3 -> [2, 3, 0, 0]），避免依赖 packaging
    parts = [int(part) for part in re.findall(r'\d+', str(value))]
    while len(parts) < 4:
        parts.append(0)
    return parts


def version_file():
    # 配置目录可能在上一次升级里被迁移（见 update_commands.sh 里的迁移步骤），
    # 所以每次都重新解析一遍，不要用模块级常量。
    config_dir = find_config_dir()
    if config_dir is not None:
        return config_dir / VERSION_FILE_NAME
    return config_dir_candidates()[0] / VERSION_FILE_NAME


def installed_version():
    path = version_file()
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text()).get("version")
    except (ValueError, OSError):
        return None


# -------------------- 主流程 --------------------

def _apply_max_time(input_string):
    """把命令行上的 --max-time 换成秒，并写进环境变量给 selfupdate.sh。

    `wave.py` 不为 selfupdate 解析旗标（自更新要能把参数原样交给脚本），
    所以这里自己扫一遍：`--max-time 2min` 与 `--max-time=2min` 都认。
    """
    global FETCH_TIMEOUT
    words = input_string.split()
    raw = None
    for index, word in enumerate(words):
        if word == "--max-time":
            raw = words[index + 1] if index + 1 < len(words) else ""
        elif word.startswith("--max-time="):
            raw = word.split("=", 1)[1]

    if raw is None:
        return

    if raw == "":
        print(f"{RED_BOLD}🌊 Error: Missing time after --max-time "
              f"(e.g. --max-time=2min, --max-time=40).{RESET}")
        sys.exit(1)

    try:
        seconds = domains.parse_duration(raw)
    except ValueError:
        print(f"{RED_BOLD}🌊 Error: Cannot parse --max-time '{raw}'.{RESET}")
        print(f"{RED_BOLD}🌊 Use seconds or a unit: 40, 40s, 1min, 1min20s, 2h.{RESET}")
        sys.exit(1)

    FETCH_TIMEOUT = seconds
    os.environ[domains.MAX_TIME_ENV] = str(seconds)


def _wants_dry_run(input_string):
    """`--dry-run`：本层自己把计划打完就退出，不执行 selfupdate.sh。

    计划必须由**这一层**打：真正的下载发生在 update_commands.sh 里，而它是由
    selfupdate.sh 执行的 —— 让脚本自己去判断「试运行」就等于让下载路径多一种
    分支，迟早有一条会漏。
    """
    return bool(re.search(r"(^|\s)--dry-run(\s|$)", input_string or ""))


def _apply_python_source(input_string):
    """`--install-python-from-source`：自带解释器直接从上游取，不试我们托管的副本。

    客户端自己不下解释器（那一步在 selfupdate.sh / install.sh 里），所以这里只把
    旗标翻译成环境变量，由脚本去读。
    """
    if "--install-python-from-source" in input_string.split():
        os.environ["LINUXWAVE_PYTHON_FROM_SOURCE"] = "1"


def handle_selfupdate(input_string=""):
    _apply_max_time(input_string)
    _apply_python_source(input_string)

    if find_config_dir() is None:
        print(f"{RED_BOLD}🌊 Error: LinuxWave is not installed. Run lib/install.sh first.{RESET}")
        sys.exit(1)

    silent.say("🌊 Fetching the latest version...")

    data = resolve_release()
    if data is None:
        print(f"{RED_BOLD}🌊 Error: Cannot reach the LinuxWave version data.{RESET}")
        print(f"{RED_BOLD}🌊 {LATEST_TOML_URL}{RESET}")
        sys.exit(1)
    latest = data["version"]

    print(f"🌊 Latest version found: {latest}")

    current = installed_version()
    if current and version_key(current) >= version_key(latest):
        silent.say(f"{GREEN}🌊 LinuxWave is already up to date (current: {current}).{RESET}")
        sys.exit(0)

    environment = dict(os.environ)
    environment["LINUXWAVE_UPDATE_VERSION"] = latest
    if data.get("branch"):
        environment["LINUXWAVE_UPDATE_BRANCH"] = data["branch"]

    if _wants_dry_run(input_string):
        silent.say("🌊 Dry run: nothing will be downloaded or written.")
        silent.say(f"🌊 Latest version : {latest}")
        silent.say(f"🌊 Current version: {current or '<none>'}")
        silent.say(f"🌊 Branch         : {data.get('branch') or '<unchanged>'}")
        silent.say(f"🌊 Install dir    : {load_base_dir()}")
        silent.say(f"🌊 Config dir     : {find_config_dir()}")
        silent.say("🌊 Would fetch linuxwavedata/<版本>/update_commands.sh and run it,")
        silent.say("🌊 regenerate lib/wave, install the Python dependencies, and rewrite")
        silent.say("🌊 VERSION.json.")
        sys.exit(0)

    if current:
        silent.say(f"🌊 Updating LinuxWave from {current} to {latest}...")
    else:
        silent.say(f"{YELLOW}🌊 No installed version found, updating to {latest}...{RESET}")

    try:
        result = run_script(environment, UPDATE_TIMEOUT)
    except subprocess.TimeoutExpired:
        print(f"{RED_BOLD}🌊 Error: The update timed out.{RESET}")
        sys.exit(1)

    if result.returncode != 0:
        print(f"{RED_BOLD}🌊 Error: The update failed (exit code {result.returncode}).{RESET}")
        sys.exit(1)

    # VERSION.json 是「装好了」的唯一凭据：selfupdate.sh 只在全部文件到位之后才写它。
    # 再确认一次，避免任何一层把失败当成成功。
    final = installed_version()
    if not final or version_key(final) < version_key(latest):
        print(f"{RED_BOLD}🌊 Error: The update did not complete (still on {final or 'unknown'}).{RESET}")
        sys.exit(1)

    silent.say("")
    silent.say(f"{GREEN}🌊 LinuxWave has been updated to {final}!{RESET}")

    # wave.py 会被覆盖，但当前进程已经加载完了，直接退出即可
    sys.exit(0)


if __name__ == "__main__":
    handle_selfupdate()
