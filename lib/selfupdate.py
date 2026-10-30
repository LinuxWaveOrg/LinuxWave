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
from configpaths import VERSION_FILE_NAME, config_dir_candidates, find_config_dir, load_base_dir

# 版本数据的位置由 domains 决定（LINUXWAVE_SELFUPDATE_DOMAIN 可整体换掉）。
# 目前仍在 configdata 里，搬到独立的 Selfupdate 仓库后只需改 domains 的默认值。
VERSION_DATA_URL = f"{domains.selfupdate_domain()}/versiondata/latest_version"

# 4.0 起的两级结构：latest.toml 说「装哪个版本」，该版本的 update_commands.sh 说「怎么装」。
# 前者每次发版都变，后者按版本冻结 —— 装了旧版本的人继续用他们那份说明，而旧版本仍在运行。
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
    """返回 (版本数据, 布局)，两个布局都没有时返回 (None, None)。

    优先 4.0 的 linuxwavedata/latest.toml；取不到或字段不全才回落到 3.x 的
    versiondata/latest_version（镜像上两份可以并存，迁移期谁也不会被打断）。
    """
    text = fetch_url_text(LATEST_TOML_URL)
    if text:
        data = parse_toml(text)
        if data.get("version"):
            return data, "linuxwavedata"

    text = fetch_url_text(VERSION_DATA_URL)
    if text:
        return parse_version_data(text), "legacy"

    return None, None


def fetch_version_data():
    # 优先用标准库；本地 Python 缺根证书时改走 curl
    try:
        with urllib.request.urlopen(VERSION_DATA_URL, timeout=FETCH_TIMEOUT) as response:
            return response.read().decode()
    except (urllib.error.URLError, UnicodeDecodeError):
        pass

    result = subprocess.run(['curl', '-fsSL', '--max-time', str(FETCH_TIMEOUT), VERSION_DATA_URL],
                            capture_output=True, text=True)
    if result.returncode != 0:
        return None
    return result.stdout


def parse_version_data(text):
    # 字段写法与 infosource 数据一致：`field: "value"`。
    # update_command 是例外，它的值写在 <<< 和 >>> 之间，可以跨行。
    fields = {}

    command_match = re.search(r'update_command:\s*<<<(.*?)>>>', text, re.DOTALL)
    if command_match:
        fields['update_command'] = command_match.group(1).strip()
        text = text[:command_match.start()] + text[command_match.end():]

    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        key, separator, value = line.partition(':')
        key = key.strip()
        if not separator or not key:
            continue
        value = value.strip()
        if len(value) >= 2 and value.startswith('"') and value.endswith('"'):
            value = value[1:-1]
        fields[key] = value

    return fields


def version_key(value):
    # 只比较数字段（2.3 -> [2, 3, 0, 0]），避免依赖 packaging
    parts = [int(part) for part in re.findall(r'\d+', str(value))]
    while len(parts) < 4:
        parts.append(0)
    return parts


def version_file():
    # 配置目录可能在上一次升级里被迁移（见 configdata 的 updatedata/），
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


def handle_selfupdate(input_string=""):
    _apply_max_time(input_string)

    if find_config_dir() is None:
        print(f"{RED_BOLD}🌊 Error: LinuxWave is not installed. Run lib/install.sh first.{RESET}")
        sys.exit(1)

    print("🌊 Fetching the latest version...")

    data, layout = resolve_release()
    if data is None:
        print(f"{RED_BOLD}🌊 Error: Cannot reach the LinuxWave version data.{RESET}")
        print(f"{RED_BOLD}🌊 {LATEST_TOML_URL}{RESET}")
        print(f"{RED_BOLD}🌊 {VERSION_DATA_URL}{RESET}")
        sys.exit(1)
    latest = data.get("version", "")
    if not latest:
        print(f"{RED_BOLD}🌊 Error: The version data has no 'version' field.{RESET}")
        sys.exit(1)

    print(f"🌊 Latest version found: {latest}")

    current = installed_version()
    if current and version_key(current) >= version_key(latest):
        print(f"{GREEN}🌊 LinuxWave is already up to date (current: {current}).{RESET}")
        sys.exit(0)

    print("🌊 Fetching the new version information")

    environment = dict(os.environ)
    environment["LINUXWAVE_UPDATE_VERSION"] = latest
    if data.get("branch"):
        environment["LINUXWAVE_UPDATE_BRANCH"] = data["branch"]

    if layout == "linuxwavedata":
        # 4.0 布局：该版本冻结的更新脚本自己完成下载与落盘。
        # 客户端只负责把它取下来、按合同传环境变量、跑它。
        script_url = domains.selfupdate_commands_url(latest)
        script_text = fetch_url_text(script_url)
        if not script_text:
            print(f"{RED_BOLD}🌊 Error: Cannot fetch the update commands for {latest}.{RESET}")
            print(f"{RED_BOLD}🌊 {script_url}{RESET}")
            sys.exit(1)

        # 合同里的变量（与 scripts/build_update_commands.py 的注释逐条对应）
        environment["LINUXWAVE_INSTALL_DIR"] = str(load_base_dir())
        environment["LINUXWAVE_CONFIG_DIR"] = str(find_config_dir() or "")
        environment["LINUXWAVE_CORE_URL"] = domains.core_domain()
        environment["LINUXWAVE_BRANCH"] = data.get("branch", "")
        environment["LINUXWAVE_TARGET_VERSION"] = latest
        environment["LINUXWAVE_CURRENT_VERSION"] = current or ""
        environment["LINUXWAVE_FILE_TIMEOUT"] = str(FETCH_TIMEOUT)
        environment["LINUXWAVE_NEED_SUDO"] = "0" if os.access(load_base_dir(), os.W_OK) else "1"
        command = None
    else:
        command = data.get("update_command", "")
        if not command:
            print(f"{RED_BOLD}🌊 Error: The version data has no 'update_command' field.{RESET}")
            sys.exit(1)

    if current:
        print(f"🌊 Updating LinuxWave from {current} to {latest}...")
    else:
        print(f"{YELLOW}🌊 No installed version found, updating to {latest}...{RESET}")

    try:
        if command is None:
            # 落到临时文件再跑：脚本内容来自网络，不能直接塞进 -c 的字符串里
            with tempfile.NamedTemporaryFile('w', suffix='.sh', delete=False) as handle:
                handle.write(script_text)
                script_path = handle.name
            try:
                result = subprocess.run(['/bin/bash', script_path], env=environment,
                                        timeout=UPDATE_TIMEOUT)
            finally:
                try:
                    os.unlink(script_path)
                except OSError:
                    pass
        else:
            result = subprocess.run(['/bin/bash', '-c', command], env=environment,
                                    timeout=UPDATE_TIMEOUT)
    except subprocess.TimeoutExpired:
        print(f"{RED_BOLD}🌊 Error: The update command timed out.{RESET}")
        sys.exit(1)

    if result.returncode != 0:
        print(f"{RED_BOLD}🌊 Error: The update command failed (exit code {result.returncode}).{RESET}")
        sys.exit(1)

    # update_command 是 `bash -c "$(curl ...)"` 形式，curl 失败时 bash 仍然返回 0，
    # 所以这里以 VERSION.json 的实际内容为准，避免误报成功
    final = installed_version()
    if not final or version_key(final) < version_key(latest):
        print(f"{RED_BOLD}🌊 Error: The update did not complete (still on {final or 'unknown'}).{RESET}")
        sys.exit(1)

    print("")
    print(f"{GREEN}🌊 LinuxWave has been updated to {final}!{RESET}")

    # wave.py 会被覆盖，但当前进程已经加载完了，直接退出即可
    sys.exit(0)


if __name__ == "__main__":
    handle_selfupdate()
