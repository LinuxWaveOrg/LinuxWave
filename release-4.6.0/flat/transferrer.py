#!/usr/bin/env python3

# transferrer.py

# `wave transfer`：给**已经装着**的产物补一遍路径重定位，让整棵树不再依赖安装目录。
#
# 为什么需要：LinuxWave 到 4.5 为止是在**安装时**做重定位的（`surfboard/transfer.sh`
# 把 ELF 的 RPATH 改写成 `$ORIGIN` 相对形式）。那个时机之后才装进来的包、或者从更早
# 的版本升上来、当时因为缺 patchelf 被跳过的包，RPATH 里可能还留着绝对路径 —— 于是
# 「换目录 / 搬走整棵树」就不成立了。这个命令就是补那一步。
#
# 自动检测新旧：每个目标目录先跑 `transfer.sh --check`（只读），已经全是相对的直接
# 跳过，只对还写着绝对路径的动手。所以重复执行安全，混着新旧产物的树也只处理该处理的。
#
# 改写会重写 ELF 字节（ELF 没有代码签名，改完即用），因此：
#   - 先用 `-n/--dry-run` 看一眼要动哪些；
#   - 想彻底恢复原样，`wave reinstall <包>` 重新下一份即可。

import os
import subprocess
import sys
import tempfile

import silent
from configpaths import load_base_dir

TRANSFER_SCRIPT = os.environ.get("LINUXWAVE_TRANSFER_SCRIPT") or os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "surfboard", "transfer.sh",
)
# LINUXWAVE_TRANSFER_SCRIPT 只给测试用：真脚本要解析 ELF、跑 patchelf/readelf，
# macOS 上造不出真 ELF，所以测试用一个按剧本回话的假脚本验 Python 这一层
# （选目标、依赖闭包、去重、dry-run、汇总、退出码）。

BASE_DIR = load_base_dir()
BIN_DIR = BASE_DIR / "bin"


def _run_transfer(args):
    """跑一次 transfer.sh，返回 (退出码, 输出)。输出已去掉尾部空白。"""
    result = subprocess.run(
        ["/bin/bash", TRANSFER_SCRIPT] + list(args),
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )
    return result.returncode, (result.stdout or "").strip()


def _read_deps(artifact_dir):
    """读取某个产物目录的 `_DEPS`，返回 [(依赖名, 版本)]。"""
    path = os.path.join(artifact_dir, "_DEPS")
    if not os.path.isfile(path):
        return []
    refs = []
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            ref = line.strip().strip('"').strip()
            if not ref or "@" not in ref:
                continue
            name, _, version = ref.partition("@")
            if name and version:
                refs.append((name, version))
    return refs


def _dep_dir(name, version):
    return os.path.join(str(BASE_DIR), "deps", name, f"{name}@{version}")


def _collect_deps(package_dirs):
    """把若干软件包目录用到的依赖（含依赖的依赖）收成目录集合。

    必须连依赖一起迁移：只改软件包自己的引用，它指向的 dep 里那些绝对路径
    仍然写死，整棵树照样搬不动。
    """
    seen = {}
    pending = list(package_dirs)

    while pending:
        current = pending.pop()
        for name, version in _read_deps(current):
            target = _dep_dir(name, version)
            if target in seen or not os.path.isdir(target):
                continue
            seen[target] = True
            pending.append(target)

    return sorted(seen)


def _package_dirs(specs):
    """spec 列表 -> [(标签, 目录)]。不带 @版本 时取该包的所有已装版本。"""
    from uninstaller import find_installed_versions

    targets = []
    problems = []

    for spec in specs:
        name, _, version = spec.partition("@")
        installed = find_installed_versions(name)

        if not installed:
            problems.append(f"not installed: {name}")
            continue

        if version:
            if version not in installed:
                problems.append(
                    f"not installed: {name}@{version} (installed: {', '.join(installed)})")
                continue
            wanted = [version]
        else:
            wanted = list(reversed(installed))  # find_installed_versions 降序

        for each in wanted:
            targets.append((f"{name}@{each}", os.path.join(str(BIN_DIR), f"{name}@{each}")))

    return targets, problems


def all_installed_dirs():
    """所有已装软件包 + 所有已装依赖：[(标签, 目录)]。--all 与 basedir 预检共用。"""
    targets = []

    if os.path.isdir(str(BIN_DIR)):
        for entry in sorted(os.listdir(str(BIN_DIR))):
            path = os.path.join(str(BIN_DIR), entry)
            if os.path.isdir(path) and "@" in entry:
                targets.append((f"bin/{entry}", path))

    deps_root = os.path.join(str(BASE_DIR), "deps")
    if os.path.isdir(deps_root):
        for owner in sorted(os.listdir(deps_root)):
            owner_dir = os.path.join(deps_root, owner)
            if not os.path.isdir(owner_dir):
                continue
            for version_dir in sorted(os.listdir(owner_dir)):
                path = os.path.join(owner_dir, version_dir)
                if os.path.isdir(path):
                    targets.append((f"deps/{owner}/{version_dir}", path))

    return targets


def _relative_label(path):
    try:
        return os.path.relpath(path, str(BASE_DIR))
    except ValueError:
        return path


def position_independence(artifact_dir):
    """True / False / None（None = 判断不了，例如没有 otool）。

    用 `transfer.sh --check` 判断 —— 那是唯一的口径（同一个脚本负责改写），
    在这里另写一份 Mach-O 解析只会和它走散。只读、不建索引。
    退出码：0 = 已是相对形式，1 = 还有绝对路径，2 = 无法检查。
    """
    code, _output = _run_transfer(["--check", str(artifact_dir), str(BASE_DIR)])
    if code == 0:
        return True
    if code == 1:
        return False
    return None


def is_position_independent(artifact_dir):
    return position_independence(artifact_dir) is True


def absolute_artifacts():
    """还写着绝对路径的产物：[(标签, 目录)]。空列表 = 整棵树可以搬走。

    「判断不了」不算在内：把未知当成"坏"，会让 `basedir --set` 在缺 otool 的环境里
    永远拒绝搬家。
    """
    return [(label, path) for label, path in all_installed_dirs()
            if position_independence(path) is False]


def handle_transfer(input_string):
    """`wave transfer <package>[@<version>] [, ...]` 与 `wave transfer --all`。"""
    from lock import tree_lock
    with tree_lock("transfer"):
        return _handle_transfer_locked(input_string)


def _handle_transfer_locked(input_string):
    words = input_string.split()
    operands = [word for word in words[2:] if not word.startswith("-")]
    flag_words = {word for word in words[2:] if word.startswith("-")}

    all_packages = bool({"-a", "--all"} & flag_words)
    dry_run = bool({"-n", "--dry-run"} & flag_words)

    tolerated = {"-a", "--all", "-n", "--dry-run"}
    from flags import GLOBAL
    for unknown in sorted(flag_words - tolerated - set(GLOBAL)):
        print(f"🌊 Warning: unknown flag '{unknown}' ignored.")

    if all_packages:
        if operands:
            print("🌊 Error: -a/--all transfers every installed package; it cannot be "
                  "combined with package names.")
            print("🌊 Use wave transfer --all, or name the packages without -a.")
            sys.exit(1)
        targets = all_installed_dirs()
        if not targets:
            print("🌊 No packages installed yet.")
            return 0
    else:
        # 逗号与空格都当分隔，与 install / uninstall 一致
        specs = []
        for token in operands:
            specs.extend(part.strip() for part in token.split(",") if part.strip())
        if not specs:
            print("🌊 Error: Missing package name.")
            print("🌊 Try: wave transfer <package>, wave transfer <package>@<version>, "
                  "or wave transfer --all")
            sys.exit(1)

        targets, problems = _package_dirs(specs)
        for problem in problems:
            print(f"🌊 Error: {problem}")
        if problems:
            print("🌊 Nothing was transferred.")
            sys.exit(1)

        # 连这些包用到的依赖一起迁移，否则整棵树仍然搬不动
        extras = _collect_deps([path for _label, path in targets])
        targets.extend((_relative_label(path), path) for path in extras)

    # 去重（包与依赖可能被重复列出），保持顺序
    unique = {}
    for label, path in targets:
        unique.setdefault(path, label)
    targets = [(label, path) for path, label in unique.items()]

    if dry_run:
        silent.say(f"🌊 Would transfer {len(targets)} installed artifact(s):")

    shared_index = tempfile.mkdtemp(prefix="linuxwave-transfer-index-")
    migrated = []
    already = []
    failed = []

    try:
        for label, path in targets:
            code, output = _run_transfer(["--check", path, str(BASE_DIR)])
            if code == 0:
                already.append(label)
                continue
            if code != 1:
                failed.append((label, output or "check failed"))
                continue

            if dry_run:
                migrated.append(label)
                silent.say(f"🌊   needs transfer: {label}")
                continue

            code, output = _run_transfer([path, str(BASE_DIR), shared_index])
            if code == 0:
                migrated.append(label)
                detail = output.splitlines()[-1] if output else ""
                detail = detail.lstrip("🌊").strip()
                silent.say(f"🌊 {label}: {detail or 'ok'}")
            else:
                failed.append((label, output))
    finally:
        for name in os.listdir(shared_index):
            try:
                os.unlink(os.path.join(shared_index, name))
            except OSError:
                pass
        try:
            os.rmdir(shared_index)
        except OSError:
            pass

    verb = "would transfer" if dry_run else "transferred"
    silent.say(f"🌊 {verb} {len(migrated)}, already relative {len(already)}, "
               f"failed {len(failed)} (of {len(targets)})")

    for label, output in failed:
        print(f"🌊 Error: {label} could not be transferred.")
        for line in (output or "").splitlines():
            print(f"🌊   {line}")

    if failed:
        print("🌊 These artifacts still name absolute paths; reinstalling them with "
              "'wave reinstall <package>' gets a copy the installer relocates on the way in instead.")
        sys.exit(1)


if __name__ == "__main__":
    try:
        handle_transfer(" ".join(sys.argv[1:]))
    except KeyboardInterrupt:
        print("🌊 Operation cancelled by user.")
        sys.exit(130)
