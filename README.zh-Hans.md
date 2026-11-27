> **🌊 迁移提示：官网已迁至 <https://summerwave.org/>；本仓库已归档，开发转到 <https://github.com/SummerwaveOrg/Summerwave>。**
> **🌊 Migration notice: the official site is now <https://summerwave.org/>. This repository is archived — development continues at <https://github.com/SummerwaveOrg/Summerwave>.**
>
## 🌊 LinuxWave

面向 Linux 软件开发者的包管理器。

macOS 用户？请看 [MacWave](https://github.com/MacWaveOrg/MacWave)

[English](./README.md) · **简体中文**

> **站点公告**：官网已迁移至 **[linuxwave.org](https://linuxwave.org)**（原 linuxwave.macwave.org）。

## 🌊 官方网站

[linuxwave.org](https://linuxwave.org)

## 🌊 支持的平台
Linux (x86_64 / arm64)
## 🌊 最新版本

4.6.0，发布于 2026-11-24

## 🌊 LinuxWave 是什么？

LinuxWave 是 MacWave 的官方 Linux 移植版。从 MacWave 2.0 起，MacWave 主线不再支持 Linux，LinuxWave 承接了这部分支持。它运行在 Linux（x86_64 / arm64）上，是一个为 Linux 软件开发者托管常用软件包的**包管理器**。

> **定位是补充，不是取代。** 和 Linuxbrew 一样，LinuxWave 只负责发行版包管理器没提供、或者版本太旧的常用开发软件；系统自带的 `apt` / `dnf` / `pacman` 依旧是装系统组件、库和驱动的地方。两者并存而不互相接管：LinuxWave 不安装、不升级、也不删除任何由发行版管理的包，除自己那棵安装树、配置目录和 shell 启动文件之外不写别处。

## 🌊 为什么选择 LinuxWave

1. **轻量化设计，节约磁盘空间。** 采用安装脚本拉取文件的安装方式代替 clone，节约你的磁盘空间。
2. **一条命令，安装常用软件包。** 不再需要到处寻找下载链接。
3. **版本化存储。** 每个二进制文件都以 `package@version` 形式存储，因此多个版本可以共存，且不会与系统工具冲突。
4. **可选的无版本号链接。** `wave link <包名>` 会建立一个指向最高已安装版本的普通快捷方式，并在安装或卸载版本时自动改指。
5. **无缓存，始终最新。** 软件包元数据实时从 `infosource` 分支获取。
6. **支持 10 种归档格式，经 CI 验证。** 支持无扩展名二进制文件、`.zip`、`.tar.gz`、`.tar.bz2`、`.tar.xz`、`.tar`、`.gz`、`.xz`、`.bz2`、`.conda`。
7. **先校验，后解压。** 解压前先校验 SHA256。
8. **支持断点续传。** 下载中断了？用 `-C` 继续。单个文件传输失败会自动重试，最多 5 次；
   按 `Ctrl-C` 只会打印一行提示，不再喷出 Python traceback。
9. **轻量透明。** 纯 Python + Shell，无重型运行时，无隐藏行为。
10. **自动管理依赖。** 支持带依赖的软件包，采用引用计数与自动依赖管理，无需手动处理依赖。

## 🌊 安装 LinuxWave

在终端中运行：

```
curl -fsSL https://raw.githubusercontent.com/LinuxWaveOrg/LinuxWave/HEAD/lib/install.sh | /bin/bash
```

（安装结束时，安装器会打印出让 `wave` 在当前终端立刻可用的确切命令。）

**安装后建议阅读手册。[点击阅读](Foreword/Foreword-zh.md)。**

**环境要求：Linux（x86_64 / arm64）、Python（3.14 及以上）、patchelf（用于依赖库重定位）。**

### 无人值守安装

面向脚本与批量场景，安装器提供若干参数，全程不会停下来等待输入：

```
# script already on disk
bash install.sh --ci

# straight from the repository
curl -fsSL https://raw.githubusercontent.com/LinuxWaveOrg/LinuxWave/HEAD/lib/install.sh | /bin/bash -s -- --ci
```

`--ci` 会自动应答目录菜单与许可协议；当选中的目录需要提权时，它要求免密 sudo
或以 root 运行。不带 `--dir-option` 时它会选用推荐默认项 `1`（`/home/linuxwave/.linuxwave`，
共享安装）并说明用的是哪个默认值，而不是去读一个可能并不存在的终端。`--dir-option=N` 免菜单直接选定第 `N` 项
（1-5）；自定义项要附上路径，写成 `--dir-option=5=/opt/mylw`，或直接写 `--dir-option=~/mylw`。
完整参数列表可运行 `install.sh --help` 查看。

> **关于这条命令。** 安装脚本被直接送进 `/bin/bash` 执行，不会先存到磁盘。请在网络状况良好时
> 运行，并在执行过程中尽量避免按 `Ctrl-C`：数据流一旦中断，安装就会停在半途，重新执行同一条
> 命令即可。
>
> **请照这一种写法用。** 不要改成 `/bin/bash -c "$(curl …)"`：那会把整份脚本塞进命令行里的
> 一个参数，而 Linux 对单个参数有 131 071 字节的上限（`Argument list too long`），这个安装
> 脚本已经接近那个尺寸。也不要接 `sudo bash`：`sudo` 会重置环境（`PATH` 与代理变量都在其中），
> 并绕过安装器自己的提权流程与提示。需要传参数时写成 `/bin/bash -s -- <参数>`。

`uninstall.sh` 同样支持脚本化调用：`--force` 跳过两次确认并**保留** `linuxwave` 账号；
`--remove-user` 则会连同该账号一并删除。两者同时使用即可完全无人值守地卸载。

> **不加 `--force` 时，卸载器需要一个终端。** 它从 `/dev/tty` 读取确认，读不到就**中止**，
> 而不会把已关闭的 stdin 当作「同意」——删除不可逆。脚本与 CI 必须显式写上 `--force`。

## 🌊 下载目录
已安装的二进制文件存储于（可选）：    
```
1. /home/linuxwave/.linuxwave (shared, all users) [recommended]
2. ~/.local/linuxwave
3. /opt/linuxwave
4. /usr/local/linuxwave
5. Custom
```
配置文件存储于（系统级安装始终优先）：
```
1. /etc/linuxwave_config          system-level install (needs sudo)
2. ~/.config/linuxwave_config     user-level install (no sudo)
```
共享安装（选项 1，推荐项）始终使用 `/etc/linuxwave_config`，以保证全机所有用户解析到同一个安装。
它需要 `patchelf`、Python 3.14+，以及一次性提供 `sudo`；若 `linuxwave` 账号不存在会自动创建。

> **共享安装是组共享的（Linuxbrew 式）。** 安装树归 `linuxwave` 组，运行安装器的人自动入组，
> 于是装包就是以你自己的身份在写——无需 `sudo`，也无需写全路径：
> ```
> wave install <package>
> ```
> 组身份只在新的登录会话里生效，第一次装包前请退出重登一次（或在当前 shell 跑
> `newgrp linuxwave`）。升级旧的共享安装同理——`wave selfupdate` 也会把安装树交给该组并把你
> 加进去，所以那之后同样要重登一次。若重登后仍然写不进去，说明首次登录时启动的用户管理器
> （`systemd --user`）还握着旧凭据：请执行 `systemctl --user exit` 后重新登录一次（重启亦可）。
> 让更多用户也能装：`sudo usermod -aG linuxwave <用户>`
> （他们同样要重登）。组内成员可以改动整棵树，包括 `lib/wave` 本体。`wave selfupdate` 仍然
> 需要 `sudo`：它要重写 root 属主的 `/etc/linuxwave_config`。不在组内的用户会在报错信息里拿到
> 一条可用的 `sudo` 命令——`sudo wave install …` 本身跑不通，因为 `sudo` 用的是它自己那套 `PATH`。

> **非共享的系统级安装归 `root:root`、权限 755。** 选项 2、3（`/opt/linuxwave`、
> `/usr/local/linuxwave`）以及家目录之外的自定义目录都属于这一类：装好的包所有人照样能运行，
> 但装包、升级、卸载都需要 `sudo`，而 `sudo` 用的是它自己的 `PATH`，所以要写全路径：
> ```
> sudo /opt/linuxwave/lib/wave install <包名>
> ```
> 这棵树不能对普通用户可写：它的二进制在系统 `PATH` 上，谁能替换 `links/<名>`，谁就可能让它被
> 别的账号甚至 root 执行。想要「`wave install` 不带 `sudo`」，请用共享安装（选项 1，推荐项）。

## 🌊 写脚本时

要让 `wave` 的输出不打搅你的脚本，它用的是与 `curl` 同一套写法：

```bash
wave install jq -s          # 什么都不打印，退出码是唯一信号
wave install jq -sS         # 同上，但保留错误（行首不带 🌊，方便 grep）
```

`-s` 只适用于「有过程可安静」的命令 —— `install`、`upgrade`、`uninstall`、
`link`、`unlink`、`selfupdate`。给只读命令（`list`、`search`、`info`、
`linkquery`、`mirror`）加 `-s` 会报错，而不是安静地什么都不做：打印正是这些命令的
用途。`-s` 优先于 `-v`，两者都可以和其它短旗标合并（`-sX`、`-CsX`）。

询问会被跳过而不是干等：`-s` 下「是否重试下载」按「否」处理，「要卸哪个版本」直接
取消，所以无人值守的脚本不会卡住。

## 卸载 LinuxWave

要从系统中彻底移除 LinuxWave，请在终端中运行以下命令：

```
curl -fsSL https://raw.githubusercontent.com/LinuxWaveOrg/LinuxWave/HEAD/lib/uninstall.sh | /bin/bash
```

## 🌊 运行软件包
要运行某个软件包，请使用带版本号的名称：
```
{package_name}@{version}
```
或者先用 `wave link {package_name}` 创建一次免版本号的快捷方式，之后直接运行：
```
{package_name}
```

## 🌊 软链接管理
建立不含版本号的软链接后，LinuxWave 会自动维护它指向的版本：

1. 最高版本被卸载后，不含版本号的软链接会改指向剩余版本中的最高版本，被卸载版本自己的软链接一并撤销。
2. 安装会把不含版本号的软链接指向本次安装的版本；本次安装加上 `--unlink` 可跳过这一步。
3. 某软件包不再有任何版本时，不含版本号的软链接会被撤销。
4. 无论何种情况，含版本号的名称始终可以调用，即使存在不含版本号的软链接。

手动 `wave unlink {package_name}` 过的软件包会被记住，之后的卸载不会重新为它建立链接。

## 🌊 命令参考

```
Usage:
  wave <command> [package] [flags]

Commands:
  install     Install a package (latest version)
  upgrade     Install a package at the latest version
  reinstall   Reinstall the version(s) already installed
  transfer    Make installed packages independent of the install directory
  uninstall   Uninstall a package
  list        List installed packages
  search      Search for a package in the index
  info        Display detailed information about a package
  selfupdate  Update LinuxWave itself to the latest version
  link        Link installed packages without a version number
  unlink      Remove those unversioned links
  linkquery   Show which version an unversioned link points to
  mirror      Show which addresses packages are fetched from
  basedir     Print LinuxWave's install root (the base_dir in config.json)
  doctor      Check the install tree for problems (read-only)
  latest      Show which packages have a newer version available
  shellenv    Print the shell code that puts LinuxWave on your PATH
  manual      Show the full manual (same text as man and info)

Flags:
  -h, --help              Show help for any command
  -V, --version           Print version information
  -v, --verbose           Enable verbose output (show detailed logs)

Global Flags (can be used with any command):
  -C, --continue          Resume interrupted downloads (like curl -C -)
      --proxy string      Specify an HTTP/HTTPS proxy (e.g., http://127.0.0.1:8080)
      --skip-ssl          Skip SSL certificate verification (insecure)
      --limit-rate string Limit download speed (e.g., 200K, 1M, 5M)
      --ver string        Install a specific version of the package

Special Flags:
wave install <pkgname>@<version>   Download certain version(s) of a package
    --no-link                      Leave the unversioned link alone (install / uninstall; the old name --unlink works too)
    --all, -a                      Apply to every installed package (upgrade / link / unlink / linkquery)

Unversioned Links:
wave link <name>                   Link a package to its highest installed version
wave linkquery <name>              Show what <name> is linked to (e.g. 🌊 ffmpeg@9.0)
wave unlink <name>                 Remove that link

Shell setup:
wave shellenv                      Print the code that puts wave on your PATH (for eval)
```

卸载某个版本会把链接改指向次高版本，没有版本剩余时则删除该链接。`uninstall --unlink`
保持链接原样，但**拒绝执行**会让链接指向“你正在卸载的那个版本”的操作。
## 🌊 演示图片

<p align="center">
  <img src="images/demo1.png" alt="demo1" width="80%" style="max-width: 720px;">
</p>

## 🌊 支持的软件包
（按字母顺序排列）

```

7zz              by Igor Pavlov
act              by nektos
actionlint       by rhysd
age              by FiloSottile
atuin            by atuinsh
bat              by David Peter
btm              by Clement Tsang
btop             by Aristocratos
chezmoi          by twpayne
circleci         by CircleCI
cloudflared      by cloudflare
columbula        by Sha0huaZhang
cosign           by Sigstore
delta            by dandavison
difft            by Wilfred Hughes
direnv           by direnv
docker-compose   by Docker
doggo            by mr-karan
duckdb           by duckdb
dust             by bootandy
eza              by Christina Sørensen and the eza community
fd               by David Peter
ffmpeg           by FFmpeg Team
flyctl           by superfly
fx               by antonmedv
fzf              by Junegunn Choi
gh               by cli
git-lfs          by git-lfs
gitleaks         by gitleaks
glow             by charmbracelet
golangci-lint    by golangci
gping            by orf
grpcurl          by fullstorydev
gwget            by GNU Project
hadolint         by Hadolint
htop             by Hisham Muhammad and the htop team
hyperfine        by sharkdp
ipsw             by blacktop
jj               by Jujutsu contributors
jless            by Paul Julius Martinez
jq               by Stephen Dolan, Nicolas Williams, William Langford, Owen Ou, itchyny, Mattias Wadman, Emanuele Torre, Asaf Meizner, avid Korczynski, et al.
just             by Casey Rodarmor
k9s              by derailed
kind             by Kubernetes SIG Testing
kubecolor        by kubecolor
kubeconform      by yannh
kubectx          by ahmetb
kustomize        by Kubernetes SIG CLI
lazydocker       by Jesse Duffield
lazygit          by jesseduffield
ldid             by Jay Freeman (saurik) / Procursus Team
lefthook         by Evil Martians
linuxwave        by Orhun Parmaksız
lsd              by Abin Simon
mise             by jdx
mkcert           by FiloSottile
ncdu             by Yoran Heling
nvim             by neovim
ollama           by ollama
palera1n         by palera1n Team
pandoc           by John MacFarlane
rclone           by rclone
restic           by restic
rg               by Andrew Gallant
robinsing        by Sha0huaZhang
ruff             by astral-sh
scc              by Ben Boyter
shellcheck       by koalaman
shfmt            by mvdan
sk               by skim-rs
sops             by getsops
spf              by yorukot
starship         by starship
stern            by stern
syncthing        by Syncthing contributors
taskwarrior-tui  by kdheepak
tldr             by tealdeer-rs
tmux             by Nicholas Marriott and contributors
tofu             by opentofu
tree             by Steve Baker, Thomas Moore, Francesc Rocher, Florian Sesser, Kyosuke Tokoro
trivy            by aquasecurity
trollrestore     by JJTech (@JJTech0130)
ty               by Astral
typst            by typst
uv               by astral-sh
vhs              by charmbracelet
watchexec        by Watchexec contributors
websocat         by vi
xh               by ducaale
yazi             by sxyazi
yq               by Mike Farah
yt-dlp           by yt-dlp
zellij           by zellij-org
zoxide           by Ajeet D'Souza
```
## 🌊 许可证

本项目基于 **Apache License 2.0** 发布 —— 全文见 [LICENSE](LICENSE)，署名说明见 [NOTICE](NOTICE)。LinuxWave 安装的软件包各自保留自己的许可证。

各版本的许可证：

| 版本 | 许可证 |
| :--- | :--- |
| `1.0.0` – `4.5.2` | MIT |
| `4.6.0` 及以后 | Apache License 2.0 |

`4.5.2` 及更早的版本都是按 MIT 发布的，并且继续按 MIT 算 —— 已经发出去的版本不会被追溯
改协议。Apache-2.0 从 `4.6.0` 开始生效，这一版会重新询问你是否同意协议，原因也在这里。

## 🌊 联系我们

Email：[hi@macwave.org](mailto:hi@macwave.org)


