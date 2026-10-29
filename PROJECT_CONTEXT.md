# 🌊 LinuxWave 项目结构

面向 Linux 软件开发者的包管理器，主要托管面向 Linux 的预编译软件包。
技术栈：Python + Shell。

- `main` 与版本分支（当前的 `3.0`）：程序代码，两者保持同步
- `configdata` 分支：版本数据（`versiondata/latest_version` 给 `wave selfupdate` 判断有没有新版本，`versiondata/files_info` 是要更新的文件清单）
- `infosource` 分支：纯数据（包与依赖的元数据、下载地址、校验值）

---

## 一、仓库目录

```
lib/          入口与帮助
pkg/          安装与查询核心
surfboard/    依赖处理
scripts/      回归测试脚本
.github/      CI
.templates/   目录与文件的模板样例（bin/、pkg/、linuxwave_config/、SPECIAL/ 安装示例）
.Pseudocode/  早期伪代码，仅作参考
STYLE.md      代码风格约定
README.md     用户文档（英文）
README.zh-Hans.md  用户文档（简体中文，与英文版同步维护）
PROJECT_CONTEXT.md 本文件：项目结构与关键机制
```

## 二、各文件作用

### lib/ —— 入口与帮助

| 文件 | 作用 |
| --- | --- |
| `wave.py` | 主入口（**由 `lib/wave` 启动器调用**，见 install.sh 行）。读配置目录（`config.json`）的 `base_dir`，把 `lib/`、`pkg/`、`surfboard/` 注入 `sys.path`；用 `COMMANDS` 字典把 `install / uninstall / list / search / info / version / selfupdate / link / unlink / linkquery / mirror` 分发到对应模块，`ARGUMENTS` 处理 `-h/--help/-V/--version`。**2.6.1 起** `__main__` 捕获 `KeyboardInterrupt`（下载卡住时用户多半会按 Ctrl-C）打印一行 `Interrupted. Nothing was installed.` 并 `exit(130)`，以及 `BrokenPipeError`（如 `wave list \| head`）静默 `exit(0)` |
| `configpaths.py` | **配置目录解析**（`find_config_dir` / `load_base_dir` / `CONFIG_FILE` / `VERSION_FILE`）：系统级 `/etc/linuxwave_config` 优先，其次用户级 `~/.config/linuxwave_config`；系统级配置损坏或缺 `base_dir` 时也回落用户级。其余模块都从这里取配置，不再各自写死路径 |
| `configerror.py` | 启动前的环境自检：`check_environment()` 检查装没装；`check_dependencies()` 检查 `requests`/`packaging`/`rich` 是否可用（缺了就打印当前解释器路径、缺失清单与修复命令）——正常路径走不到它，因为启动器已经挑过解释器了，它只兜住「绕过启动器直接 `python3 lib/wave.py`」这种情况。原文：只要两处配置目录里有一处装了 LinuxWave 就放行；都没装且在 git 仓库里时，报错并提示用 `lib/install.sh` 正式安装 |
| `help.py` | 帮助与版本文本：`print_custom_help`（`-h` / `--help` 的用法，命令与旗标列表与 README 的 Command Reference 对齐）、`print_version`、`print_error_help`（未知命令时先报错再打帮助） |
| `domains.py` | **对外地址的单一真相源（4.0 起）**。七种用途各一个域（`api` / `bottle` / `deps` / `core` / `python` / `selfupdate` / `sourcecode`），覆盖变量形如 `LINUXWAVE_API_DOMAIN`。`_validate` 必须与两份 shell 脚本里的 `mw_domain` 给出同样结论（`scripts/domains_test.sh` 拿同一批输入逐条比对）；`https` / `file` 之外只有回环地址允许明文 `http`；末尾斜杠去掉、主机名转小写；空格、引号、反引号、`$`、反斜杠一律拒绝。另含 payload 命名（`payload_suffix` / `payload_filename` / `payload_url`）、`listing_names`（同时认 GitHub 的 JSON 数组与镜像的纯文本清单）、**请求超时的解析**（`parse_duration`：`40` / `40s` / `1min20s` / `2h`，畸形值直接报错而不是静默取默认值）与凭据脱敏。**已接线（B 档）**：`pkg/pkginstaller.py` 与 `surfboard/depsinstaller.py` 在「配了对应域名」时调用 `resolve_payload`；没配则回落到索引的 `url`（3.1.x 的既有行为）。是否走镜像由 `use_mirror_for(kind, from_source)` 统一判定：`--install-from-source` 一律回上游 |
| `steplog.py` | `-v` 分步日志（`step` / `detail` / `fail` / `done`），纯标准库，只 `import sys`。`domains.py` 依赖它 |
| `mirrorinfo.py` | **`wave mirror`**：按当前生效值列出七种地址（未覆盖的显示内置默认值），支持 table / `--json` / `--yaml` / `--toml` / `--raw`（可直接粘进 shell 配置）与 `--only-set`（`--raw` 下只导出你覆盖过的那几项）；密码固定显示六颗星，`--show-password` 才展开，`--hide-user` 连用户名一起遮 |
| `install.sh` | 官方安装脚本：支持 `--silent`（`-S`，全程无交互，同时`--dir-option` 与协议都自动应答；需要免密 sudo 或 root）与 `--dir-option=N` / `--dir-option=N=DIR`（非交互选择菜单项，自定义项直接把路径写在 `=` 后）以便批量/脚本安装，`--help` 列出全部；选安装目录（含共享安装选项 `/home/linuxwave/.linuxwave`，等价 Linuxbrew 的 `/home/linuxbrew`；选中后自动建 `linuxwave` 账号、把安装树交给它、配置固定写 `/etc/linuxwave_config`、放宽家目录与安装树权限、并把 PATH 同时写入 `linuxwave` 与调用者的 rc）、`sudo` 提权、建运行时目录（`bin` / `links` / `deps` / `pkg` / `surfboard` / `lib` / `downloads/tmp`）、写 `config.json` / `VERSION.json`（**系统目录→`/etc/linuxwave_config`，用户目录→`~/.config/linuxwave_config`**）、**用户级安装时把 2.5 之前的旧系统级配置 `/etc/linuxwave_config` 迁走**（否则它会因系统级优先而盖住新配置）、**按 configdata 的 `versiondata/files_info` 清单拉取全部程序文件**（与 `selfupdate.sh` 共用同一份清单，解析逻辑也相同）、安装 Python 依赖（requests / packaging / rich）、把 `bin/` + `links/` + `lib/` 写入 PATH（升级时替换旧版只含 `bin`/`lib` 的行）、清理旧版平铺 `bin/` 文件、检查 `patchelf`（依赖库重定位所需）、许可协议确认（直接回车视为同意）。注意 `LINUXWAVE_VERSION` 仍**按分支写死**在脚本里，不能从 configdata 取 —— 否则用旧分支安装会写成新版本号。**推荐调用方式是 `/bin/bash -c "$(curl …)"`**：绝对路径的 `/bin/bash` 不受被篡改的 `PATH` 影响，且 `curl` 会先完整结束、`bash` 才开始执行，下载中途失败不会被边下边跑。这种方式下传参必须写 `--`（`/bin/bash -c "$(curl …)" -- --silent`），因为 `bash -c` 会把第一个参数当作脚本名（`$0`）；`$0` 里出现选项即说明参数**已被静默丢弃**，脚本会就此警告并打印正确写法。**许可协议在「安装完成」之前询问**（否则先报成功、随后又因不同意而全删），拒绝时会把安装树、配置目录与 rc 里的 PATH 一起回滚干净——回滚用 `run_cmd` 而非写死的 `sudo`，因为用户级安装全程无需提权。共享用户的 `~/.bashrc` 不存在时会**建出来**（账号预存或 `/etc/skel` 缺文件时，否则该账号反而跑不了 `wave`）。脚本以 `set -eE` 运行：`-E` 让 ERR 陷阱能看见 `run_cmd` 等**函数内部**的失败，中途失败会打印「未完成 + 实际路径 + 重跑即可」的指引，且**刻意不自动删除**已下载内容（升级时删树会毁掉用户原有的可用安装）。**2.6.1 起**：每个程序文件失败会**自动重试 5 次**（退避等待，单次 `--connect-timeout 20 --max-time 180`；重试提示在 `--silent` 下也照打，只有逐文件进度被压掉）；**目录菜单输入无效时不再静默回落到别的目录**，而是明确报错、最多 3 次后 `exit 1`；**`--silent` 不带 `--dir-option` 时显式选默认项并说明用了哪个**（不再去读可能不存在的终端、也不再泄漏 `/dev/tty` 报错）；**2.6.3 起共享安装改成组共享（Linuxbrew 式）**：自动建 `linuxwave` 组、把调用者 `usermod -aG` 加进去、`chgrp -R` 把安装树交给该组、`chmod -R g+w` 打开组写位，并给所有目录加 `setgid`（不加的话组员新建的文件会落回他自己的主组，下一个组员就改不动）——于是装包既不用 `sudo` 也不用全路径，直接 `wave install <package>`。判「是否已在组内」按 **gid** 比而不是组名（`id -nG` 的组名是按 gid 反查出来的，gid 与用户主组撞号时会漏判成「未入组」而白跑一遍 `usermod`）；而且 `id` 的两种形式语义不同（实测确认）：`id -G <用户名>` 查的是 `/etc` **数据库**，用来决定要不要 `usermod`；`id -G` 不带参数读的是**当前会话**的进程组，用来决定「要不要重新登录」—— 两者混用会把「已写进 `/etc/group`、但当前 shell 还没这个组」的用户谎报成已生效；`usermod` 失败（账号由 LDAP/SSSD 管、`/etc/group` 有重复条目…）**不让整个安装失败**，只如实报告并给出手工命令；两处提示都写明「组身份只在新的登录会话生效，先重登或 `newgrp linuxwave`」，并给出 `sudo usermod -aG linuxwave <user>` 供开通更多用户 | **Python 运行环境（3.1.0 起）**：下载上游便携 CPython（地址与校验值来自 `configdata/pythondata/latest_python`，Linux 两架构，`install_only_stripped`），校验 sha256 后解到 `$BASE_DIR/python/<版本>/` 并建 `current` 链接；在安装根建私有 `venv/` 装好 `requests`/`packaging`/`rich`；再生成 **`lib/wave` sh 启动器**（`lib/wave.py` 按原名落盘）。启动器按「venv → 自带解释器 → 安装时的解释器 → PATH」逐层试，每层都实测能否 import。下载失败回退系统 python3；拿不到 PyPI 时退回 `--system-site-packages` 的 venv；两者都不可用就如实失败。`LINUXWAVE_TEST` 下跳过 30MB+ 下载（离线测试根）。
| `uninstall.sh` | 卸载 LinuxWave 本体：读两处配置定位 `BASE_DIR`（都读不到则遍历候选路径）、二次确认后删除安装目录与两处配置目录、清掉 rc 文件里的 PATH 行（共享安装连 `linuxwave` 的 rc 一并清）、最后自删。支持 `--force`（跳过全部确认，**保留** `linuxwave` 账号）与 `--remove-user`（连账号一并删除，不再询问）以便脚本化卸载。共享安装还会**询问**是否删除 `linuxwave` 账号，并明确警告 `userdel -r` 会连带删除家目录；拒绝时打印手工命令。删账号前会先 `loginctl disable-linger` 并停掉 `user@<uid>.service`——否则该用户一旦有过会话，systemd 的 user manager 会让 `userdel` 以「用户当前被进程使用」失败；`userdel` 的退出码会被检查，失败时如实报错并给出手工命令、退出码为 1（此前无论成败都打印「已删除」）。另外会清理共享用户家目录里的 `~/.config/linuxwave_config`（安装时 `HOME` 指向过它，配置可能落在那儿）。传参同样用 `--`（`/bin/bash -c "$(curl …)" -- --force`），否则选项被静默丢弃、脚本会警告。**自删只在 `$0` 是含本脚本标记的普通文件时执行**：用 `/bin/bash -c "$(curl …)"` 调用时 `$0` 是解释器自身（无参数）或 `--`（带参数），写死的 `rm -f "$0"` 会把 `/bin/bash` 删掉——这是官方文档推荐的调用方式，等于用 sudo 按文档卸载就会毁掉 `/bin/bash`。**不带 `--force` 时第一次确认从 `/dev/tty` 读，读不到就中止（exit 1）**：stdin 是 EOF（`< /dev/null`、CI）时绝不能默认当成同意；无人值守必须显式 `--force` |
| `selfupdate.py` | `wave selfupdate`：拉 `configdata` 分支的 `versiondata/latest_version`，取其 `version` 与当前生效的 `VERSION.json` 比较（只比数字段，`2.3` == `2.3.0`）；已是最新则直接返回，否则把 `update_command` 中 `<<<` / `>>>` 之间的内容交给 `/bin/bash -c` 执行（用环境变量 `LINUXWAVE_UPDATE_VERSION` / `LINUXWAVE_UPDATE_BRANCH` 把目标版本与分支传下去）。因为 `bash -c "$(curl …)"` 在 curl 失败时仍返回 0，执行完会**回读 `VERSION.json` 复核**，没变就报错 |
| `selfupdate.sh` | 自更新脚本，由 `latest_version` 的 `update_command` 调用（也可 `bash lib/selfupdate.sh [分支]`）：按「系统级 → 用户级」定位配置目录与 `BASE_DIR` → 拉 `configdata/versiondata/files_info`（一份**只写仓库路径**的缩进树，`/` 开头是安装根、以 `/` 结尾表示目录、`#` 开始是注释；缩进每层 4 空格，Tab 与之等价，也可行内直接写 `pkg/linker.py` 这样的完整路径）→ **用脚本内置的 `python3` 解析它**（不能做成单独的 `.py` 文件，否则新文件本身又得先被下载 —— 鸡生蛋）→ 逐个从 `$BRANCH` 下载并复位可执行位（`lib/wave.py` 特例装成可执行的 `lib/wave`；其余 `*.sh` 加 +x）→ 清掉 `__pycache__` → 重写 `VERSION.json`。**以后新增文件只改 configdata 的 files_info，不用再动本脚本**。**2.6.4 起**：下载是拿 root 跑的（`NEED_SUDO=true` 时 `run_cmd` 即 `sudo`），新文件会落成 root 属主，所以先把安装树的属主/属组记下来、收尾时 `chown -R` 交回去（否则共享安装树会慢慢变成 root 的）；再对「树属于别的账号、且属组不是 `root`」的共享安装就地补上组共享写（`groupadd -f` / `usermod -aG` / `chmod -R g+w` / 目录 `setgid`）——这样**已存在的**安装树升级时就能拿到，不必重装；提示只在「会话里还没有该组身份」时打（刚入组、或入组后一直没重登），已经有了就明说不用重登。属组是 `root` 的系统级安装不碰，也不劝人加入 `root` 组，与安装器同一判断 | 另外（3.1.0 起）**幂等补齐 Python 运行环境**：便携解释器与 venv 已存在就复用（不重复下载/重建），缺了才建，最后重写 `lib/wave` 启动器 —— 否则从 3.0.x 升上来的用户入口仍是旧的 python 副本。下载复用 `fetch_to_file`（带超时/重试/`.part`）。

### pkg/ —— 安装与查询核心

| 文件 | 作用 |
| --- | --- |
| `pkginstaller.py` | **软件包安装编排**。解析参数（包名取第一个非 flag 的 token，`--limit-rate` / `--proxy` 的值会被跳过）与架构 → 定版本（`@版本`、`--ver` 或远程取最高）→ 拉 `_包名@common` 取 `bin_name` → 拉版本文件取 `url` / `sha256` / `deps` → 下载（rich 进度条、断点续传、限速、代理、30 秒超时+重试询问）→ 调 `pkginstaller.sh` → 通过 `depsinstaller` 递归安装依赖 → 最后调 `linker.link_package()` 把不带版本号的软链接指到刚装好的版本（`--unlink` 可跳过）。**2.6.1 起**：`ensure_install_writable()` 在**联网取版本之前**预检 `downloads/tmp` 与 `bin/` 能否写入，不可写就打印 `print_write_permission_advice()`（给出 `sudo <BASE_DIR>/lib/wave install <package>` 这条能跑通的全路径命令；树的属组不是 `root` 时再补一条 `sudo usermod -aG <组> <你>`，并点明「刚入组但还没重登」是最常见的原因——组名按 gid 反查，gid 0 的 `root:root` 树故意不提组，免得建议用户去加入 `root` 组）并 `exit 1`；落盘两步与 `download_file` 也各自捕获 `PermissionError`（注意 `except PermissionError` 必须写在 `except Exception` **之前**，否则永远轮不到它）；重试提示里的 `KeyboardInterrupt` **原样抛出**交给顶层报成 interrupted——把它当成「不重试」会把用户自己按的 Ctrl-C 谎报成下载失败，只有 `EOFError` 才算不重试 |
| `pkginstaller.sh` | **软件包安装入口（binary 模式）**：组装长字符串，调用通用安装核心 `depsmanager.sh` 的 `mw_install_artifact`，写 `installed.json`，输出安装结果 |
| `pkginfohelper.py` | `list`（扫描 `bin/` 下的目录）、`search`（远程匹配包名）、`info`（本地已装版本 + 远程可装版本 + `@common` 描述） |
| `pkgversionparser.py` | 版本号比较与排序；处理 `alpha/beta/rc` 预发布，以及 `procursus` / `linuxwaveteam` / `Xteam` 等特殊版本 |
| `pkgunzip.sh` | 按扩展名解压：`zip` / `tar.gz` / `tar.bz2` / `tar.xz` / `tar` / `gz` / `bz2` / `xz` / `conda`。裸 `xz` 用 Python 标准库 `lzma`，`bz2` 与 `tar.bz2` 用标准库 `bz2`（都不依赖系统装有 `xz`／`bzip2` 命令）；**`.conda` 本质是个 zip，里装两个 zstd 压缩的 tar，只取 `pkg-*.tar.zst` 那个载荷**（`info-*.tar.zst` 是元数据），用 Python 3.14 的 `compression.zstd` 解（不依赖系统装有 `zstd`）—— **所以安装要求 Python 3.14+**；`extractall` 传 `filter='tar'`，因为 3.14 默认的 `data` 过滤器会拒掉 conda 包里的符号链接 |
| `upgrader.py` | **`wave upgrade <包名>`（3.1.0 起）**：版本由索引决定（不接受 `包名@版本`），复用 `handle_install` 的整条流水线。版本是共存的，所以升级只是再装一份；`-X` 才会清掉更旧的版本。**四种等价写法**：`-X` / `--remove-old-versions` / `--remove-old-version` / `--rov`，帮助里只宣传前两种，但另外两个必须继续能用（3.2.0 发布过单数形式）。`--ver` / `--unlink` 明确拒绝并指向替代做法。索引比本机旧时（版本被撤下）只警告、不降级 |
| `uninstaller.py` | **卸载**：扫描 `bin/` 找出该包所有版本；删除包目录与软链接；按 `_DEPS` 删除依赖标记，若某依赖已无任何标记，则连同它自己的依赖一起级联删除（递归时带 `visited` 集合，避免循环依赖 A→B→A 造成无限递归）。卸载完调 `linker` 同步不带版本号的软链接：还有别的版本就改指最高的，一个不剩就删掉；本来就没链接过的不重建（悬空链接也在这里被治好）。加 `--unlink` 则不动这个链接 —— **但如果被删的版本正好是链接当前指向的那个，会报错并拒绝执行**（绝不留下指向已卸载版本的坏链接） |
| `linker.py` | **不带版本号的软链接**（仅限软件包，不碰依赖）：`link <名>[@latest]` / `link --all`（`-a`）建或改指链接，`unlink <名>` / `unlink --all` 删链接，`linkquery <名>` 看当前指向（输出形如 `🌊 ffmpeg@9.0`；未链接退 1，**指向已不存在的版本也报错退 1**）。`installed_versions` / `linked_version` / `is_dangling` 分别扫 `bin/`、读 `links/` 软链、判断是否悬空；重复 link 会报 `already linked` |

### surfboard/ —— 依赖处理（2.2 新增）

| 文件 | 作用 |
| --- | --- |
| `depsinstaller.py` | **依赖安装编排（Python）**。校验/解析依赖引用 → 拉 `_依赖名@common` 取 `dep_name` → 拉 `_依赖名@版本号` 取 `url` / `sha256` / `deps` → 复用 `pkginstaller.download_file` 下载（进度条与软件包一致）→ 调 `depsinstaller.sh` → 递归安装子依赖；依赖已安装时只补标记（走 `tagger.sh` 命令行），并**优先读该依赖自己落盘的 `_DEPS`** 来递归补它自己的依赖 —— 只有 `_DEPS` 不存在（上次安装真的中断了）时才回源取版本文件。以前这里无条件回源，网络一抖，一个**已经装好**的依赖就会让整条安装失败（软件包本体已落盘，却连不带版本号的链接都没建）。统一收尾的 `transfer_installed_artifacts()` 会**先收集全部 target**（所有 `deps/*/*` + 传入的包目录），再建**一个** `TemporaryDirectory` 当共享索引目录交给每个 target，收尾时自动清理 |
| `depsinstaller.sh` | **依赖安装入口（tree 模式）**：`source depsmanager.sh` → 调 `mw_install_artifact` → 在依赖目录里创建 `.depped_pkg_*` / `.depped_dep_*` 标记 |
| `depsmanager.sh` | **通用安装核心**（被 `pkginstaller.sh` 与 `depsinstaller.sh` source，不单独执行）：定位下载到的原文件、SHA256 校验、解压、落盘（`binary` / `tree` 两种形态）、创建 `links/` 软链接、写 `_DEPS`、标记文件辅助函数。`mw_extract_binary` 与 `mw_extract_all` 里各有一串扩展名，**加新格式时两处都得补**，漏一个就会出现“把压缩包当二进制装下去”的静默错误。`mw_extract_all` 里“载荷只有一个顶层目录就剥掉它”的兜底带**内容目录白名单**（`lib`/`bin`/`sbin`/`include`/`share`/`man`/`etc`/`libexec`）：命中就**不剥**，否则像 `libcxx` 那种只含 `lib/` 的载荷会被摊平，依赖的 `lib/` 结构被破坏（MacWave 3.0.3 的实测 bug，LinuxWave 当前 30 个依赖都是 `.tar.bz2`、都带 `info/`，所以暂时踩不到，属预防性对齐） |
| `tagger.sh` | `.depped_*` 标记文件原语：`tagger_create` / `tagger_delete` / `tagger_has_any`，既可 `bash tagger.sh <动作> …` 调用，也可被 source |
| `transfer.sh` | **路径替换（Homebrew 式，ELF 版）**：把产物里所有 ELF 的 `RPATH`/`RUNPATH` 改写成 `$ORIGIN` 相对路径，指向产物自己的 `lib/`（`lib64/`）与 `_DEPS` 列出的依赖的 `lib/`，运行时 `ld.so` 才找得到依赖包里的共享库。解析顺序：产物自己的 `lib/` → `_DEPS` 列出的依赖 → 其它已安装依赖的 `lib`（兜底，覆盖传递依赖）。ELF 没有代码签名这一说，改完即用；ELF 的 `DT_NEEDED` 只记库名、不含路径，所以这里重写的是**搜索路径本身**。**改不动时不再静默**：`patchelf` 失败的文件会被收集并在最后打出 Warning，不然安装报“成功”、一跑就 `cannot open shared object file`。接不上的引用分两类报告：本地树里其实有、只是没放进 lib 目录 → YELLOW 警告；本地根本没有（上游包自带的外部依赖）→ 🌊 Note 列出名字。系统库（libc / libm / ld.so 等，取自 `ldconfig -p`）不算未声明依赖。**性能**：依赖侧的两份索引（整棵依赖树的名字表、依赖 `lib/` 里的库名）对所有 target 完全相同，给出第三个参数（共享索引目录，或环境变量 `LINUXWAVE_SHARED_INDEX`）时只建一次、其余复用——统一收尾会为每个已装依赖各调一次本脚本，逐次重扫就是 O(依赖数²)。取名字用内建 `${f##*/}`、输出用内建 `printf` 且重定向放在循环外（逐文件 fork `basename` 是主要开销）；ELF 用**一次 Python 扫描**按魔数列出（`python3` 不可用时退回逐文件 `head\|od\|tr`），`PROVIDED`/`SYSTEM`/`TREE` 三张表装进关联数组，免掉每个符号两次 `grep`。共享索引里的依赖侧内容**独立扫 `deps/*/*`**，不能用去重后的目录表——那份表会把“本 target 自己”的 `lib/` 剔掉，缓存给别人用就会漏库名、把能接上的引用误报成接不上 |
| `depsversionparser.py` | 依赖引用解析（强制 `依赖名@版本号`）与版本比较；版本逻辑复用 `pkgversionparser.py` |
| `querier.py` | 查询依赖是否已安装：`deps/{引用名}/{引用名}@{版本号}/` 存在**且含 `_DEPS`** 才算安装完成（避免中途失败留下的空目录被误判） |

### scripts/ 与 CI

| 文件 | 作用 |
| --- | --- |
| `scripts/checksum_test.sh` | **校验值回归（没有合法 `sha256` 就不许安装）**。三段：① 离线测校验核心 `mw_verify_sha256` 的行为 —— 缺值 / 长度不足 / 含大写 / 含非十六进制字符都要拒绝，格式合法但内容不符要报校验失败**并删掉损坏文件**，正确值放行；② 端到端（联网）装 `test_no_sha256` 与 `test_wrong_sha256`，断言失败、报错文案正确、且**不留下任何安装痕迹**；③ 静态哨兵，三处守卫（包记录 `pkginstaller.py` / 依赖记录 `depsinstaller.py` / 安装核心 `depsmanager.sh`）的报错文案缺一即失败 —— 数据里没有缺校验值的**依赖**夹具，这一层只能靠哨兵防重构时被删。网络不可达时第②段记 SKIP 而不是 FAIL（区分「连不上」与「被拒绝」）。注意它跑的是**已部署**的代码（`wave.py` 用的是 `BASE_DIR` 里的脚本），所以设 `LINUXWAVE_TEST` 可在假根里验证 |
| `scripts/format_test.sh` | 10 种打包格式（无扩展名 / zip / tar.gz / tar.bz2 / tar.xz / tar / gz / bz2 / xz / **conda**）逐个跑 install → 运行 → uninstall；跑完再断言装完自动建了不带版本号的链接，以及 `install --unlink` 不建链接 |
| `scripts/audit_deps.py` | **依赖审计**。`data` 模式：查 infosource 数据的 `deps` 引用格式（必须一行一个引用）、`url` / `sha256` / `bin_name` 完整性（**真实软件包缺 `sha256` 现在判为 problem**，因为安装器会拒绝安装它；只有 `test_*` 夹具留空是合法的，`test_no_sha256` 正是用来验证拒绝分支的），以及被引用的 `@common` 与版本文件是否存在（本地有数据就读本地，否则从 GitHub 拉取）；`edges` 模式：把已安装依赖的实测 ELF `DT_NEEDED` 引用与数据声明对比，找出漏声明的依赖边——**只有系统给不了的引用才算漏声明**（`ldconfig -p` 登记过的一律豁免）：引用系统本来就有、恰好某个已装依赖也提供同名库时（`zstd` 的 `liblzma.so.5` 与 `xz`），报成漏声明是误报，实测只装 `zstd`、不装 `xz` 时 `zstd --version` 照样能跑；而 `libidn2` 的 `libiconv.so.2` 在 `ldconfig` 里查不到（glibc 的 iconv 在 libc 里，发行版不带 GNU libiconv），只按声明装就会以 `libiconv.so.2: cannot open shared object file` 起不来，才是真缺口。注意「已声明但实测没引用」的提醒仍按**全部**引用判定，不受该豁免影响。`--ignore 正则` 可跳过已知历史问题；加 `--check-urls` 会额外联网逐个确认 url 可达（默认关闭，因为依赖网络；数据里的 `test_*` 测试包故意用假 url，开它时要配 `--ignore 'test_'`）；发现真问题时退出码 1 |
| `scripts/deps_test.sh` | **依赖链端到端回归（全量）**：自动从数据里**发现所有带依赖的包**（每个包取最高版本，排除 `test_*`），逐个跑完整循环——安装 → 运行 `--version` 验证 relink → 检查安装日志没有未解析引用 → 跑 `audit_deps.py edges` 做**依赖边审计**（实测 `DT_NEEDED` 与数据声明对比）→ 检查 `.depped_*` 标记 → 卸载并确认依赖目录与软链接被级联清理，最后打总表。也可只跑指定包（`bash scripts/deps_test.sh htop@3.5.3`）、用 `--data-dir` 指定数据副本；数据目录默认先找 `$REPO_DIR/infosource-data`，再找 `$REPO_DIR/../infosource-data`（CI 把数据检出到仓库根，本地开发克隆在上层）。当前发现：`htop@3.5.3`、`ncdu@2.9.2`、`tmux@3.6`、`wget@1.25.0` |
| `scripts/selfupdate_test.sh` | **自更新回归**（必须放最后，它会真的改安装目录）。**全程离线**：顶部用当前工作树 + 真实的 `versiondata/files_info` 搭一份 `file://` 镜像，把 `LINUXWAVE_CORE_DOMAIN` / `LINUXWAVE_SELFUPDATE_DOMAIN` 指过去（`update_command` 保持生产形状 `bash -c "$(curl …)"`，只换地址）。① 单测 `parse_version_data`（含 `<<<`/`>>>` 多行命令）与 `version_key`；② 把 `VERSION.json` 写成 `9999.0`，断言 `wave selfupdate` 短路为「已是最新」；③ 写成 `0.1`，断言跨大版本被拒绝且配置未被动过；④ 同大版本走完整更新（读清单 → 下载 → 写 `VERSION.json` → 重写 `lib/wave` 启动器），断言版本号到位、清单里每个文件都落了地、`lib/wave` 是启动器（以 `#!` 开头）且命令表里每个模块都存在 |
| `scripts/link_test.sh` | **不带版本号软链接回归**：装完自动建链接 → 不带版本号能跑 → `link` / `unlink` / `linkquery` → `-a` 批量 → 卸掉最高版自动降级（先复制一份目录造出 2.0，不依赖 infosource 真有该版本）→ `uninstall --unlink` 不降级 → `install --unlink` 不建链接 → 卸掉最后一个版本时删掉链接 |
| `scripts/domains_test.sh` | **域名层回归（离线）**：默认值与 `domains.py` 一致、两份 shell 脚本的域名块**逐字相同**、16 个输入在 shell 与 Python 两侧给出同样结论（`http://localhost/x` 无端口、含空格、含反引号、IPv6 回环等历史分歧都在里面），以及**默认值以外不许出现写死的 GitHub 地址**——自更新里曾有一条 `BASE_URL` 绕过了域名块，配了镜像照样只走 GitHub |
| `scripts/mirror_test.sh` | **`wave mirror` 回归（离线）**：五种输出、`--only-set` 只导出已覆盖项、密码永远六颗星、`--show-password` / `--hide-user` 的行为，以及地址里带凭据（`https://user:pass@host`）时的解析与脱敏 |
| `scripts/help_test.sh` | **帮助排版回归（离线）**：`COMMANDS` 与 `COMMAND_HELP` 双向一致（缺一条 `wave X --help` 就会静默回落到总帮助）、每个命令的帮助都完整、已知命令不回落、不同长度的标签仍从同一列开始、总帮助里没有未解析的占位符 |
| `scripts/check_domain_defaults.py` | 被 `domains_test.sh` 调用：从两份 shell 脚本里抽出域名默认值，与 `lib/domains.py` 的 `DEFAULTS` 逐项比对 |
| `scripts/configpath_test.sh` | **配置目录解析回归**（离线）：把 `configpaths` 的两个候选目录换成临时目录，验证「系统级优先 / 用户级回落 / 系统级损坏或缺字段也回落 / 都没有则退 1」 |
| `scripts/sandbox_test.sh` | **安装器 / 卸载器的端到端回归，跑在隔离命名空间里**。用 `unshare -rm` 把 `/etc`、`/home`、`/opt`、`/usr/local`、`/root`、`/var`、`/srv` 换成临时影子副本，宿主这几个目录一个字节都不会被写；取数改成 `file://` 本地镜像，因此**不需要网络**。断言覆盖：四个安装目录选项 → 配置落位（用户级 `~/.config` / 系统级 `/etc`）→ PATH 写入 → 参数校验（缺路径、越界、路径穿越、未知旗标）→ **协议询问在「安装完成」之前**、拒绝后安装树与配置与 rc 里的 PATH 全部回滚 → 中途失败时的指引且不误删 → 卸载确认语义（无终端必须拒绝、答 n 取消、答 y 删除、`--force` 无人值守）→ 卸载器自删且以 `/bin/bash -c` 运行时不误删解释器 → 共享安装（双端 rc、家目录权限、只剩安装树时的识别、`--remove-user` 的调用序列与失败不谎报）→ 复用 `link_test.sh` → 目录菜单无效输入不静默换目录、`--silent` 单独使用走默认项 → **单文件下载重试**（「短暂失败后自愈」与「持续失败后如实报错」两种，并断言自愈那次不会留下误导性的「未完成」）→ **共用安装树不可写**（用只读挂载真实复现，断言在联网取版本之前就失败、给出 `sudo` 全路径命令、且 `root:root` 的树不劝人去加入 `root` 组）→ **组共享写**（断言调用者被加进 `linuxwave` 组、树目录打开组写位、目录带 `setgid`、提示写明「要重新登录」、重复安装不再谎称刚入组、`usermod` 失败时安装仍成功并如实报告、组名反查判定正确）→ **`Ctrl-C`**（传输中，以及停在重试提示上两处，断言退出码 130、只给一行提示、且不谎报成下载失败）。当前共 **163 条断言**（`PASS` / `FAIL` / `SKIP` 三类，SKIP 用于「本机确实无法复现」的情形，例如缺 `script` 就没有 pty、`mount` 失败就无法造只读树）。要求非 root 运行；`sudo`/`loginctl`/`systemctl` 用替身（命名空间内本就是 uid 0，真调 loginctl 会去改宿主的 systemd 状态）。**已知限制**：发行版一般没装 `newuidmap`，命名空间里只映射调用者自己的 uid，所以选项 4 改成复用已存在的 `linuxwave` 账号，`useradd` 那一行无法在这里复现；同理**映射不了别的 gid**，`linuxwave` 组的 gid 只能是 0（换成别的 gid，`chown`/`chgrp` 会因「未映射」报 `EINVAL`），所以「调用者尚未入组」这个前提改用 passwd 里 root 的主组字段表达，组名反查那一步（`group_name_for_gid`）直接单测、不硬凑一棵非 0 属组的树。另外，命名空间里 root 的会话本来就带 gid 0，而 `linuxwave` 组的 gid 也只能是 0，所以「会话里还没有该组、需要重新登录」这一分支在沙箱里**永远走不到**——那一支靠隔离实验单独验证 `id` 的两种语义（具名查库、不带参数看会话） |
| `.github/workflows/format-test.yml` | 在 `ubuntu-latest` 上把 `lib/`、`pkg/`、`surfboard/` 部署到 `/tmp/linuxwave-test`，依次跑配置目录回归、依赖审计、格式回归、**校验值回归**（`checksum_test.sh`）、依赖链回归、链接回归、**selfupdate 回归**。`python-version` 走 `['3.14', '3.15']` 矩阵（`fail-fast: false`，一条挂了不取消另一条）：3.14 是环境下限（`.conda` 需要 `compression.zstd`），3.15 是上游最新正式版。`actions/python-versions` 里还没有 3.15.0 正式版（`setup-python` 报 `The version '3.15' ... was not found`），所以 3.15 那条线用 `astral-sh/setup-uv` 拉 python-build-standalone，再 `uv venv --seed` 建一个带 pip 的 venv 插到 `GITHUB_PATH` 最前（`setup-uv` 只把解释器登记给自己用，`PATH` 上的 `python3` 仍是 runner 自带那个）；每条线都断言 `sys.version_info[:2]` 与矩阵一致，免得 3.15 悄悄跑在 3.14 上还报绿。另外给工作流带上 `GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}`（`audit_deps.py` 走 `api.github.com` 的 tree API，未认证只有 60 次/小时）与 `PYTHONUNBUFFERED: "1"` |
| `.github/workflows/portable-python.yml` | **便携解释器产物的月度体检**：拉 `configdata/pythondata/latest_python`，校验数据格式（https、64 位小写十六进制），下载**两个架构**并重新计算 sha256 比对，确认压缩包里真有 `python3`（四种候选布局之一）；对 native 架构再跑一遍完整能力验证：`-VV`、`compression.zstd`、pip、建 venv、装 `requests`/`packaging`/`rich`、用这个 venv 跑通仓库里的 `wave.py -V` 与全部模块导入。`schedule` 每月 + `workflow_dispatch` |

## 三、安装后的运行时目录

`BASE_DIR` 取自生效的 `config.json` 的 `base_dir`（系统级 `/etc/linuxwave_config` 优先，其次用户级 `~/.config/linuxwave_config`；默认安装 `~/.local/linuxwave`）。

配置目录的归属由安装位置决定：装到需要 `sudo` 的目录（`/opt/linuxwave`、`/usr/local/linuxwave`、自定义的系统路径）→ `/etc/linuxwave_config`；装到无需 `sudo` 的目录（`~/.local/linuxwave`、家目录下的自定义路径）→ `~/.config/linuxwave_config`。两处都存在时程序一律先用系统级。

**共享安装（`/home/linuxwave/.linuxwave`）例外，恒定使用 `/etc/linuxwave_config`**：用户级配置会按每个调用者各自的 `$HOME` 解析，若共享安装写用户级配置，其他用户运行 `wave` 只会得到「配置未找到」。因此该选项同时强制 `NEED_SUDO=true`，以便写 `/etc`。

**迁移**：2.5 之前不分系统级/用户级，配置一律写在 `/etc/linuxwave_config`。所以用户级安装时，`install.sh` 会读 `/etc/linuxwave_config/VERSION.json`，只要版本低于 `2.5`（读不到也视为旧版）就把它删掉，配置重新落到 `~/.config/linuxwave_config`；`2.5` 及以后的系统级配置不动。

```
BASE_DIR/bin/{可执行文件名}@{版本}/            软件包：二进制 + _DEPS
BASE_DIR/deps/{引用名}/{引用名}@{版本}/        依赖：整棵解压目录 + _DEPS + .depped_* 标记
BASE_DIR/links/{名字}@{版本}                   软链接，此目录已加入 PATH
BASE_DIR/pkg/installed.json                   已安装软件包记录
BASE_DIR/downloads/tmp/                       下载临时目录（*.partial 表示未下载完）
BASE_DIR/{lib,pkg,surfboard}/                 程序文件自身
BASE_DIR/python/{版本}/                       自带解释器（3.1.0 起；current 符号链接指向在用版本）
BASE_DIR/venv/                                私有 Python 环境（requests / packaging / rich）
BASE_DIR/lib/wave                             sh 启动器（由 write_launcher 生成，**不是** wave.py 的副本；不在 files_info 清单里）
/etc/linuxwave_config/{config.json,VERSION.json}          系统级安装的配置（优先）
~/.config/linuxwave_config/{config.json,VERSION.json}     用户级安装的配置
```

## 四、数据源（`infosource` 分支）

软件包：

```
pkg/pkginfo_{arch}/{包名}/_{包名}@common     bin_name / des / hom / lic / aut
pkg/pkginfo_{arch}/{包名}/_{包名}@{版本号}    url / sha256 / deps
```

依赖：

```
surfboard/depsinfo_{arch}/{依赖名}/_{依赖名}@common     dep_name / des / hom / lic / aut
surfboard/depsinfo_{arch}/{依赖名}/_{依赖名}@{版本号}     url / sha256 / deps
```

- `{arch}` 为 `arm64` 或 `amd64`
- 下载地址强制 `https://`
- **`deps` 写在版本文件里**（不是 `@common`），每行一个 `依赖名@版本号`，多行书写：

```
deps: "gettext@0.21.0"
      "openssl@3.0.15"
      "zlib@1.2.13"
```

- 简易 DSL 解析规则：行内第一个引号**前**有 `字段:` 声明，该行属于该字段；否则向上回溯到最近的字段声明；同一字段多行合并为列表。`deps` 字段缺失即视为无依赖
- 依赖引用格式强制 `依赖名@版本号`，不合规直接报错退出
- 依赖名/版本在 `depsinfo_{arch}/` 里找不到时报错退出

### ⚠️ 与上游 MacWave 的 `infosource` 是**语义分叉**，不能整仓同步

目录名一模一样，含义不同：`pkginfo_amd64` 在 MacWave 那边指 **macOS Intel**，在我们这里指 **Linux x86_64**。实测同一条记录：

| | `_ldid@2.1.5-procursus7`（amd64） |
| --- | --- |
| MacWave | `url = …/ldid_macosx_x86_64`，`sha256 9d46e0fe…` |
| LinuxWave | `url = …/ldid_linux_x86_64`，`sha256 4b8862b2…` |

所以**不要**把上游数据当镜像一键同步：`ldid`、`jq`、`yq`、`palera1n` 这些包会立刻变成「下载 macOS 二进制 + 校验不过」。上游「Refresh the sha256 for ldid …」那类提交修的是 macOS 产物，与我们无关。

- `file` 字段（4.0 的 payload 文件名）我们已在数据里补齐，但**客户端尚未消费**（见 §六.8）
- 名字校验已改为 Unicode 类别判定，不再限 ASCII；长度上限 128 字符 / 200 字节（`configpaths.is_safe_filename`）

## 五、数据源（`configdata` 分支的 `updatedata/`）

当某个版本**改动了目录结构**（例如 2.5 把用户级安装的配置从 `/etc/linuxwave_config` 挪到 `~/.config/linuxwave_config`）时，`install.sh` 与 `selfupdate.sh` 会在下载程序文件之前执行一段**数据驱动**的迁移：

```
updatedata/{版本号}/dir_structure_change   只有一个字符：Y/y = 目录结构变了，N/n = 没变
updatedata/{版本号}/transfer_commands      Y/y 时执行这个脚本（bash -c "$(curl …)"）
```

- `{版本号}`：`install.sh` 与 `selfupdate.sh` 都取 `latest_version` 里的目标版本（**3.0 起** `install.sh` 也从 configdata 读 `version`/`branch`，不再写死在脚本里）
- 标记文件拉不到（不存在/网络失败）→ 按「没变」处理，静默跳过；标记为 Y/y 但**迁移脚本拉不到** → 报错退出（避免留下半迁移状态）
- 执行迁移脚本前会 `export LINUXWAVE_INSTALL_DIR`（安装目录）/ `LINUXWAVE_CONFIG_DIR`（配置目录）/ `LINUXWAVE_TARGET_VERSION`，脚本据此**自己判断要不要搬**（例如只对用户级安装迁移）
- **迁移会搬走配置目录，所以迁移后必须重新解析**：`selfupdate.sh` 会再解析一次（否则 `VERSION.json` 会被写回旧位置）；`selfupdate.py` 的升级后复核也用 `version_file()` 每次重新解析（否则会误报「更新没有完成」）。`configpaths.py` 的模块级常量只在**进程启动时**解析一次，跨迁移的复核不能用它
- ⚠️ **从 2.5 之前的版本升级必须用 `install.sh`**：2.5 之前发布的 `selfupdate.py` 把 `VERSION_FILE` 写死在 `/etc/linuxwave_config/VERSION.json`，配置被搬走后升级完的复核会读不到、**误报失败**（其实升级成功了）。2.5 及以后没有这个问题，可以正常用 `wave selfupdate`
- 以后目录结构再变，只需在 configdata 加 `updatedata/{新版本}/` 这两个文件，**不用改任何代码**

### 构建号（`versiondata/latest_version` 的 `build_number`）

形如 `284D2306`，三段分别是：

| 段 | 含义 |
| --- | --- |
| `284` | 生成当天的**日序号**（2026-10-11 是当年第 284 天） |
| `D` | **星期几**：周一~周日依次为 `A`~`G`。`H` **只**用于法定节假日或公司年假，没有特殊说明就不要用 |
| `2306` | 生成时刻的 `HH:MM`（**本地时间**） |

取的是**生成时刻**，不是发布时刻 —— 例如 `283F2358` 是 10-10（周六 → `F`）23:58 生成、10-11 00:22 发布的，所以日序号是 283 而不是 284。

已知的历史偏差：`LinuxWave 3.0` 与 `3.0.1` 用的都是 `282D…`，但 10-09（日序号 282）是**周五**，按规则应为 `E`。

`versiondata/latest_version` 同时是**发布开关**：`install.sh` 从它读 `version` 与 `branch`，`selfupdate.py` 拿它的 `version` 与本地 `VERSION.json` 比较，所以把这份文件更新到新版本号，就等于把线上版本切过去了。

### 发版时必须一起刷新的位置

版本号和日期是两样东西，只改版本号会留下「最新版本 3.0.5 / 发布于 2026-10-11」这种自相矛盾的展示 —— 3.0.3 与 3.0.4 就漏过日期，直到 3.0.5 才发现。每次发版按这张单子过一遍：

| 位置 | 要改什么 |
| --- | --- |
| `main/README.md` 第 19 行附近 | `3.x.y, Release on YYYY-MM-DD` |
| `main/README.zh-Hans.md` 第 19 行附近 | `3.x.y，发布于 YYYY-MM-DD` |
| `pages-site/index.html` 的 `version-block`（英文与中文两处） | **版本号 + 发布日期的两行都要改** |
| `configdata` 的 `versiondata/latest_version` | `version` / `release_date` / `build_number` / `branch` |
| `configdata` 的 `versiondata/files_info` | 新增或删除 `lib/`、`pkg/`、`surfboard/` 下的文件时**必须同步**：漏一行，装出来的 `wave` 就以 `ModuleNotFoundError` 起不来（3.1.0 加的 `domains.py` / `steplog.py` / `mirrorinfo.py` 就是三行） |
| `configdata` 的 `updatedata/<版本>/dir_structure_change` | 新增，单字节 `N`；**真改了目录结构**才写 `Y` 并在同目录附 `transfer_commands` |
| `configdata` 的 `pythondata/latest_python` | 只在更换自带解释器版本时改（版本号 + 两架构地址 + sha256） |
| 发布分支 `x.y` | 先建分支，再推 `configdata`——指针里的 `branch` 指向它，分支不存在时每次自更新都 404 |
| `docs/release-notes/vX.Y.Z.md` | Release 正文。先写进仓库再粘到 Release；索引见 `docs/release-notes/README.md`（含发布日期与一句话摘要） |
| `release-<版本>/` 资产集 | `flat/` 放全部 `lib/` `pkg/` `surfboard/` `scripts/` 文件，`archive/` 放 `PROJECT_CONTEXT.md` + `lib/selfupdate.sh`，再打 `.tar` / `.tar.gz` |

改完用远端内容复核，不要只看本地：`main` 与发布分支（`3.1`）是镜像，两边都要对；官网还要等 Pages 构建后再抓一次首页确认。复核走 **API** 而不是 `raw.githubusercontent.com`——那条通道会被重置，也可能在推送后短暂滞后（实测出现过推送 1 分钟内 404、重跑即恢复）。

`.templates/` 下的 `version`（`9.9.9` / `1.2.0` / `3.0.0`）是样例占位值，不参与发版，**不要跟着改**。`2.5` / `2.6` 等历史分支保留各自的版本号，也不要动。

### 分支与合并：成块的工作走独立分支，合并时保留历史

一次性改动直接落 `main` 没问题；**成块的工作（新命令、新布局、跨多个文件的移植）必须开独立分支**，
完成后用 **merge commit** 并回 `main`：

```bash
git switch -c feature/upgrade        # 从 main 切出
# …若干次提交…
git switch main
git merge --no-ff feature/upgrade -m "Merge feature/upgrade: …"
```

**为什么不能用 squash 或 rebase 压平**：压平会丢掉分支上的分步提交，等到要回看「这个功能是怎么一步步做出来的」
就只剩一个巨提交，只能靠事后补历史——那比一开始就合并贵得多。`--no-ff` 还留下一个明确的合并点，
`git log --first-parent main` 能看清每次合入的是什么。

发布分支（`3.x`）从 `main` 快进而来（`git push origin main:refs/heads/3.x`），
所以 `main` 上看到的历史就是发布分支的历史；**不要把发布分支的内容反向提交回 main**。

### `pythondata/latest_python`：自带解释器的地址与校验值

3.1.0 起 `install.sh` / `selfupdate.sh` 都读它来决定下载哪个便携解释器：

```
version: "3.14.9"
arm64_url / arm64_sha256
amd64_url / amd64_sha256
```

- 指向 GitHub 上 `astral-sh/python-build-standalone` 的 `install_only_stripped` 产物
  （Linux 两架构，30MB / 36MB）；解压后解释器在 `python/bin/python3`，安装器会再补一个
  `<安装根>/bin/python3` 的相对链接把布局归一化，启动器只认 `python/current/bin/python3`。
- **换成非 stripped 版没有意义**：那只是多了调试符号，Linux 上是 58MB / 76MB。
- 校验值取自 GitHub 对该资产声明的 digest；两个架构由
  `.github/workflows/portable-python.yml` **下载后重新计算**并比对，同时确认包里真有
  那个解释器路径、native 架构能建 venv、能 `import requests, packaging, rich`、
  `compression.zstd` 可用（`.conda` 包必需）。**上游删 tag 是这套方案唯一的静默失效点**，
  所以那个工作流每月跑一次。
- 两个 URL 留空时安装器只警告并回退系统 `python3`，安装不会中断。

## 六、关键机制

1. **目录 + 软链接**：包与依赖都不再以“单个文件”形式存在，而是目录；`links/` 里放软链接并已加入 PATH。`名字@版本号` 永远可用；想让 `名字` 也能直接跑，用 `wave link <名>` 建一条不带版本号的软链接（自动跟随最高已装版本），或装的时候默认就会建（`--unlink` 可关掉）
2. **两种安装形态**（共用 `depsmanager.sh` 的同一套流程）：
   - `binary`（软件包）：解压后只取一个可执行文件，同名优先，找不到同名则取第一个并打 YELLOW 警告
   - `tree`（依赖）：保留整棵解压目录（库包不能只取一个文件）；`bin/` 下的每个文件都软链到 `links/{名字}@{版本号}`，因此不依赖“与包同名的可执行文件”
3. **`_DEPS`**：安装后写入，每行形如 `"a@1.0"`；卸载时据此清理依赖
4. **`.depped_*` 标记**：记录“谁依赖了我”
   - `.depped_pkg_{包名}@{版本号}`：被某个软件包依赖
   - `.depped_dep_{依赖名}@{版本号}`：被某个依赖依赖
   - 卸载时先删掉自己的标记；某依赖已无任何标记，才连同它自己的依赖一起级联删除，多个依赖者共享时不会被误删
5. **递归**：依赖自身的 `deps` 会被继续安装（先装下层、再装自己）
6. **动态库路径替换**：依赖包里的库不会自动被 `ld.so` 找到（预编译产物的 `DT_NEEDED` 只记库名、`RUNPATH` 又只指向构建机的路径，而安装目录可选，跨目录必然失败）。安装完成后由 `surfboard/transfer.sh` 用 `patchelf` 把 `RPATH`/`RUNPATH` 改写成指向依赖 `lib/` 的 `$ORIGIN` 相对路径。替换统一放在**全部产物就位之后**做（先逐个处理 `deps/*/*`，再处理软件包目录），因为依赖声明顺序与实际库依赖顺序未必一致——例如 `wget` 的 `deps` 里 `libidn2` 排在 `libunistring` 前面，而 `libidn2` 恰好引用 `libunistring`，提前替换会解析不到
7. **网络**：所有请求 30 秒超时；下载超时或连接失败时询问是否重试
8. **对外地址（4.0 起）**：七种用途各一个域，全部可由环境变量覆盖（`LINUXWAVE_API_DOMAIN`、`LINUXWAVE_BOTTLE_DOMAIN`、`LINUXWAVE_DEPS_DOMAIN`、`LINUXWAVE_CORE_DOMAIN`、`LINUXWAVE_PYTHON_DOMAIN`、`LINUXWAVE_SELFUPDATE_DOMAIN`、`LINUXWAVE_PKG_SOURCECODE_DOMAIN`）。Python 侧在 `lib/domains.py`，shell 侧两份脚本各抄一份 `mw_domain`——**三处必须给出同样结论**，`scripts/domains_test.sh` 用同一批输入做交叉验证。`wave mirror` 可随时查看当前生效值与来源；`--raw` 输出可直接粘进 shell 配置。
   **规则**：除域名表里的默认值外，代码里不允许再出现写死的 `github.com`（有断言守着）。自更新里曾漏改一条 `BASE_URL`，结果配了镜像也只走 GitHub、离线必挂。
   **payload 命名（B 档）**已接线：`bottle` / `deps` 域名配了就走我们自己的存储，文件名按
   `<包名>@<版本>.<架构><扩展名>`（`payload_filename`）；URL 里的 `@` 会被编码成 `%40`，服务器解码即得原名。
   没配域名时回落到索引的 `url` —— 这是**调用方**的决定（`use_mirror_for`），`resolve_payload` 自身不回落，
   它遇到缺 `file` 字段直接报数据缺陷。`--install-from-source` 一律回上游，与「配没配镜像」无关。
   **仍未接线**：`selfupdate_latest_url` / `selfupdate_commands_url`（`linuxwavedata/latest.toml` +
   `<版本>/update_commands.sh`）已定义未使用，自更新仍走 `versiondata/latest_version` + `update_command`
9. **`--proxy` 是全局的**：命令行上写了它，这条命令就**不该有任何请求绕过它**。实现是把值写进进程环境（`HTTPS_PROXY` / `HTTP_PROXY` / `ALL_PROXY` 及其小写形式），requests（`trust_env` 默认开）、urllib、curl 与子进程一并继承。此前它只影响 requests 的下载参数，取索引、取 `@common`、取依赖信息全都绕过——内网用户在下载任何字节之前就撞上「Cannot fetch @common」，看着像参数没生效
10. **测试隔离**：`LINUXWAVE_TEST=<目录>` 把整个文件系统视图挂到该目录下（`HOME` 与系统路径都落在里面），用于离线假根；`LINUXWAVE_SKIP_PORTABLE_PYTHON` 单独关掉 30MB+ 解释器下载——`sandbox_test.sh` 走 `unshare` 真装到真路径、不设 `LINUXWAVE_TEST`，光靠前者拦不住
11. **预期内的失败不该是致命错误**：`install.sh` 以 `set -eE` 运行，`mw_try` 把「允许失败」的调用包起来并把结果记进 `MW_OPTIONAL_RESULT`，`install_failed()` 见到 `MW_FAILURE_HANDLED` 就提前返回——否则「拿不到自带解释器、回退系统 python3」这种正常降级会被 ERR 陷阱当成安装失败

## 七、代码约定

见 `STYLE.md`，要点：

- Python 文件头 5 行：shebang / 空行 / `# 文件名` / 空行 / 代码，其后用 `# -------------------- 分区名 --------------------` 分区
- 颜色常量模块级单引号：`RED_BOLD` / `GREEN` / `YELLOW` / `RESET`
- 所有输出带 🌊 前缀；错误 `print(f"{RED_BOLD}🌊 Error: …{RESET}")` 后 `sys.exit(1)`
- Shell 脚本 `set -e`，同样的颜色定义与 🌊 前缀
- 脚本之间用 `\n` 分隔的长字符串传参；安装信息为 8 行：名称 / 版本号 / sha256 / 目标目录 / BASE_DIR / 可执行文件名 / 依赖者 / 原文件名

---

## 八、安装「带依赖的软件包」时，各程序依次做什么

以 `wave install wget@1.25.0` 为例（`_wget@1.25.0` 的 deps 为
`gettext@0.21.0`、`libiconv@1.16`、`libidn2@2.3.8`、`libunistring@1.3`、`openssl@3.0.15`、`pcre2@10.42`、`zlib@1.2.13`，
其中 `gettext` 自己又依赖 `libiconv@1.16`）。

### 步骤总览

| # | 程序 | 做什么 |
| --- | --- | --- |
| 1 | `lib/wave.py` | 读 `base_dir`，把 `lib/`、`pkg/`、`surfboard/` 注入 `sys.path`；按 `COMMANDS` 字典把 `install` 分发给 `pkginstaller.handle_install("wave install wget@1.25.0")` |
| 2 | `pkg/pkginstaller.py` | 解析下载参数（`-v` / `-C` / `--skip-ssl` / `--limit-rate` / `--proxy`，白名单校验）；解析包名与架构 |
| 3 | `pkg/pkginstaller.py` | 定版本：`@版本号` → `--ver` → 都没有则调 `fetch_max_version()`（GitHub API，带 `?ref=infosource`） |
| 4 | `pkg/pkginstaller.py` | 拉 `_wget@common`，解析出 `bin_name`（缺失即报错） |
| 5 | `pkg/pkginstaller.py` | 拉 `_wget@1.25.0`，解析出 `url` / `sha256` / **`deps`**（多行，向上回溯的 DSL 解析）；校验 `url` 必须是 https |
| 6 | `pkg/pkginstaller.py` | `download_file()` 下载到 `downloads/tmp/`（rich 进度条、`.partial` + 断点续传、限速、代理、30 秒超时后询问重试），完成后去掉 `.partial` 后缀 |
| 7 | `pkg/pkginstaller.py` → `pkg/pkginstaller.sh` | 传 8 行长字符串（含目标目录 `bin/wget@1.25.0`）与依赖列表，`pkginstaller.sh` 用 `binary` 模式安装 wget 本体 |
| 8 | `surfboard/depsmanager.sh` | `mw_install_artifact`：定位原文件 → SHA256 校验 → 解压 → 取一个可执行文件（同名优先，否则取第一个并打警告）→ `chmod 755` → 建软链接 `links/wget@1.25.0` → 写 `_DEPS`（7 行依赖） |
| 9 | `pkg/pkginstaller.sh` | 写 `pkg/installed.json`（带 `fcntl` 文件锁），打印安装结果 |
| 10 | `pkg/pkginstaller.py` | 调 `depsinstaller.install_dependencies()`，逐个安装 7 个依赖 |
| 11 | `surfboard/depsinstaller.py` | 每个依赖 `ensure_dependency()`：校验引用格式 → `querier.is_installed()` 判断是否已装 |
| 12 | `surfboard/depsinstaller.py` | 未装时：拉 `_依赖名@common` 取 `dep_name`、拉 `_依赖名@版本号` 取 `url` / `sha256` / `deps`；找不到则报 `Dependency '…' not found in depsinfo.` 并退出 |
| 13 | `surfboard/depsinstaller.py` | **先递归装下层依赖**（`gettext` 会先把 `libiconv` 装好）→ 再下载自己（复用第 6 步的同一个 `download_file`，进度条一致）→ 调 `surfboard/depsinstaller.sh` |
| 14 | `surfboard/depsinstaller.sh` → `depsmanager.sh` | `tree` 模式安装：整棵解压目录落到 `deps/{依赖名}/{依赖名}@{版本号}/`，单顶层目录自动下沉一层，`bin/` 下每个文件都 `chmod 755` 并各建一条软链接进 `links/`，写 `_DEPS` |
| 15 | `surfboard/depsinstaller.sh` | 按传入的依赖者信息创建标记：被包依赖 → `.depped_pkg_wget@1.25.0`，被依赖依赖 → `.depped_dep_gettext@0.21.0` |
| 16 | `surfboard/depsinstaller.py` | 只负责装依赖，不在此时做路径替换（见第 18 步） |
| 17 | `surfboard/depsinstaller.py` | 已安装的依赖：跳过下载，只调 `tagger.sh` 补标记（例如 `libiconv` 同时被 `gettext` 和 `wget` 依赖，就会有两条标记） |
| 18 | `surfboard/depsinstaller.py` | 已安装的依赖：跳过下载，只调 `tagger.sh` 补标记（例如 `libiconv` 同时被 `gettext` 和 `wget` 依赖，就会有两条标记） |
| 18 | `pkg/pkginstaller.py` → `surfboard/depsinstaller.py` → `surfboard/transfer.sh` | 依赖与软件包全部就位后，调 `transfer_installed_artifacts()`：先收集全部 target（逐个 `deps/*/*`，再是包目录），建一个 `TemporaryDirectory` 当**共享索引目录**，然后逐个 target 处理——建「库目录」索引（产物自身 `lib/` → 该产物 `_DEPS` 列出的依赖 → 其它已安装依赖兜底），对每个 ELF 用 `patchelf --set-rpath` 把 `RUNPATH` 改写成 `$ORIGIN` 相对路径。依赖侧的两份索引跨 target 复用，只建一次 |
| 19 | `surfboard/transfer.sh` | 幂等：已正确的引用直接跳过，重复执行零副作用（可作为修复既有安装的手段） |
| 20 | `pkg/linker.py` | 路径替换完成后，把 `links/wget` 指向 `bin/wget@1.25.0/wget`（不带 `--unlink` 时）；已于 18 步建好的 `links/wget@1.25.0` 不受影响 |

### 时序

```mermaid
sequenceDiagram
    participant W as lib/wave.py
    participant P as pkg/pkginstaller.py
    participant S as pkg/pkginstaller.sh
    participant M as surfboard/depsmanager.sh
    participant D as surfboard/depsinstaller.py
    participant X as surfboard/transfer.sh

    W->>P: handle_install("wave install wget@1.25.0")
    P->>P: 版本 / bin_name / url / sha256 / deps
    P->>P: download_file()（进度条）
    P->>S: 8 行长字符串 + deps 列表
    S->>M: mw_install_artifact（binary 模式）
    M-->>S: 落盘 + links/ + _DEPS
    S-->>P: 安装成功
    P->>D: install_dependencies(7 个依赖)
    loop 每个依赖（先子后己）
        D->>D: 未装 → 拉 depsinfo 元数据
        D->>D: 递归装下层依赖
        D->>M: depsinstaller.sh（tree 模式）
    end
    P->>X: transfer_installed_artifacts(包目录)
    Note over X: 先逐个 deps/*/*，再处理包目录
```

### 为什么要这个顺序

- **路径替换必须最后统一做**：`transfer.sh` 把引用指向 `deps/…/lib` 里的真实文件，所以要求目标库已经落盘。而 `deps` 的声明顺序与实际库依赖顺序未必一致（`libidn2` 排在 `libunistring` 前，但前者引用后者），因此逐产物即时替换会漏改；统一放到“全部产物就位之后”才能一次解析干净
- **`_DEPS` 先写**：`transfer.sh` 靠它确定"该去找哪些依赖的 lib"，同时它是卸载时清理依赖的唯一依据
- **标记文件在最后打**：只有依赖真正装好了才记录"谁依赖了我"，避免中途失败留下错误标记

### 这条命令跑完后的目录形态

```
BASE_DIR/bin/wget@1.25.0/        wget 二进制 + _DEPS（7 行依赖）
BASE_DIR/deps/gettext/gettext@0.21.0/     bin/ lib/ include/ … + _DEPS + .depped_pkg_wget@1.25.0
BASE_DIR/deps/libiconv/libiconv@1.16/     … + _DEPS + .depped_pkg_wget@1.25.0 + .depped_dep_gettext@0.21.0
BASE_DIR/deps/{libidn2,libunistring,openssl,pcre2,zlib}/…  各自整树 + _DEPS + .depped_pkg_wget@1.25.0
BASE_DIR/links/                  wget@1.25.0，以及每个依赖 bin/ 下可执行文件的一条链接
                                 （如 openssl@3.0.15、iconv@1.16、msgfmt@0.21.0 …）—— 此目录已在 PATH 上
```

卸载时的逆向动作见「六、关键机制」第 3、4 条：先删自己的标记，某个依赖再无任何标记时才连同它的依赖一起级联删除。
