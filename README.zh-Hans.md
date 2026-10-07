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

2.6.5，发布于 2026-10-08

## 🌊 LinuxWave 是什么？

LinuxWave 是 MacWave 的官方 Linux 移植版。从 MacWave 2.0 起，MacWave 主线不再支持 Linux，LinuxWave 承接了这部分支持。它运行在 Linux（x86_64 / arm64）上，是一个为 Linux 软件开发者托管常用软件包的**包管理器**。

## 🌊 为什么选择 LinuxWave

1. **一条命令，安装常用软件包。** 不再需要到处寻找下载链接。
2. **版本化存储。** 每个二进制文件都以 `package@version` 形式存储，因此多个版本可以共存，且不会与系统工具冲突。
3. **可选的无版本号链接。** `wave link <包名>` 会建立一个指向最高已安装版本的普通快捷方式，并在安装或卸载版本时自动改指。
4. **无缓存，始终最新。** 软件包元数据实时从 `infosource` 分支获取。
5. **支持 10 种归档格式，经 CI 验证。** 支持无扩展名二进制文件、`.zip`、`.tar.gz`、`.tar.bz2`、`.tar.xz`、`.tar`、`.gz`、`.xz`、`.bz2`、`.conda`。
6. **先校验，后解压。** 解压前先校验 SHA256。
7. **支持断点续传。** 下载中断了？用 `-C` 继续。单个文件传输失败会自动重试，最多 5 次；
   按 `Ctrl-C` 只会打印一行提示，不再喷出 Python traceback。
8. **轻量透明。** 纯 Python + Shell，无重型运行时，无隐藏行为。
9. **自动管理依赖。** 支持带依赖的软件包，采用引用计数与自动依赖管理，无需手动处理依赖。

## 🌊 安装 LinuxWave

在终端中运行：

```
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/LinuxWaveOrg/LinuxWave/HEAD/lib/install.sh)" && source ~/.bashrc
```

（如果你使用的是 zsh 而非 bash，请运行 ```source ~/.zshrc```）

**环境要求：Linux（x86_64 / arm64）、Python（3.14 及以上）、patchelf（用于依赖库重定位）。**

### 无人值守安装

面向脚本与批量场景，安装器提供若干参数，全程不会停下来等待输入：

```
# script already on disk
bash install.sh --silent --dir-option=4

# straight from the repository
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/LinuxWaveOrg/LinuxWave/HEAD/lib/install.sh)" \
  -- --silent --dir-option=4
```

`--silent`（`-S`）会自动应答目录菜单与许可协议；当选中的目录需要提权时，它要求免密 sudo
或以 root 运行。不带 `--dir-option` 时它会选用默认项 `1`（`~/.local/linuxwave`）并说明
用的是哪个默认值，而不是去读一个可能并不存在的终端。`--dir-option=N` 免菜单直接选定第 `N` 项
（1-5）；自定义项要在 `=` 之后附上路径，例如 `--dir-option=5=/opt/mylw`。完整参数列表可运行
`install.sh --help` 查看。

> **用 `/bin/bash -c` 取脚本，并把参数放在 `--` 之后。** 以绝对路径调用 `/bin/bash`，
> 意味着被篡改的 `PATH` 无法决定由哪个 shell 来执行脚本；而 `curl` 会先跑完，`bash` 才开始
> 执行，因此下载中途失败的内容不会被一边到达一边执行。`--` 会结束 bash 自身的选项，其后的
> 一切都原样传给安装器。若写成 `… --silent`，`--silent` 就成了脚本名（`$0`）而被静默丢弃，
> 安装器会停在一个没人看的提示符上；当安装器发现 `$0` 里是选项时会给出警告。

`uninstall.sh` 同样支持脚本化调用：`--force` 跳过两次确认并**保留** `linuxwave` 账号；
`--remove-user` 则会连同该账号一并删除。两者同时使用即可完全无人值守地卸载。

> **不加 `--force` 时，卸载器需要一个终端。** 它从 `/dev/tty` 读取确认，读不到就**中止**，
> 而不会把已关闭的 stdin 当作「同意」——删除不可逆。脚本与 CI 必须显式写上 `--force`。

## 🌊 下载目录
已安装的二进制文件存储于（可选）：    
```
1. ~/.local/linuxwave
2. /opt/linuxwave
3. /usr/local/linuxwave
4. /home/linuxwave/.linuxwave (shared, all users)
5. Custom
```
配置文件存储于（系统级安装始终优先）：
```
1. /etc/linuxwave_config          system-level install (needs sudo)
2. ~/.config/linuxwave_config     user-level install (no sudo)
```
共享安装（选项 4）始终使用 `/etc/linuxwave_config`，以保证全机所有用户解析到同一个安装。
它需要 `patchelf`、Python 3.14+，以及一次性提供 `sudo`；若 `linuxwave` 账号不存在会自动创建。

> **共享安装是组共享的（Linuxbrew 式）。** 安装树归 `linuxwave` 组，运行安装器的人自动入组，
> 于是装包就是以你自己的身份在写——无需 `sudo`，也无需写全路径：
> ```
> wave install <package>
> ```
> 组身份只在新的登录会话里生效，第一次装包前请退出重登一次（或在当前 shell 跑
> `newgrp linuxwave`）。升级旧的共享安装同理——`wave selfupdate` 也会把安装树交给该组并把你
> 加进去，所以那之后同样要重登一次。让更多用户也能装：`sudo usermod -aG linuxwave <用户>`
> （他们同样要重登）。组内成员可以改动整棵树，包括 `lib/wave` 本体。`wave selfupdate` 仍然
> 需要 `sudo`：它要重写 root 属主的 `/etc/linuxwave_config`。不在组内的用户会在报错信息里拿到
> 一条可用的 `sudo` 命令——`sudo wave install …` 本身跑不通，因为 `sudo` 用的是它自己那套 `PATH`。
## 卸载 LinuxWave

要从系统中彻底移除 LinuxWave，请在终端中运行以下命令：

```
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/LinuxWaveOrg/LinuxWave/HEAD/lib/uninstall.sh)"
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
  install     Install a package (Latest Version)
  uninstall   Uninstall a package
  list        List installed packages
  search      Search for a package in the index
  info        Display detailed information about a package
  selfupdate  Update LinuxWave itself
  link        Link installed packages without a version number
  unlink      Remove those unversioned links
  linkquery   Show which version an unversioned link points to

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
    --unlink                       Leave the unversioned link alone (install / uninstall)
    --all, -a                      Apply to every installed package (link / unlink / linkquery)

Unversioned Links:
wave link <name>                   Link a package to its highest installed version
wave linkquery <name>              Show what <name> is linked to (e.g. 🌊 ffmpeg@9.0)
wave unlink <name>                 Remove that link

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
bat           by David Peter
btop          by Aristocratos
dust          by bootandy
eza           by Christina Sørensen and the eza community
fd            by David Peter
ffmpeg        by FFmpeg Team
fzf           by Junegunn Choi
htop          by Hisham Muhammad and the htop team
ipsw          by blacktop
jq            by Stephen Dolan, Nicolas Williams, et al.
ldid          by Jay Freeman (saurik) / Procursus Team
lsd           by Abin Simon
ncdu          by Yoran Heling
palera1n      by palera1n Team
pandoc        by John MacFarlane
rg            by Andrew Gallant
tmux          by Nicholas Marriott and contributors
trollrestore  by JJTech (@JJTech0130)
wget          by GNU Project
zoxide        by Ajeet D'Souza
```
## 🌊 许可证

本项目基于 **MIT 许可证** 发布 —— 详见 [LICENSE](LICENSE) 文件。

## 🌊 联系我们

Email：[hi@macwave.org](mailto:hi@macwave.org)


