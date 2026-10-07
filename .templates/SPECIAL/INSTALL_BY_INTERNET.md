# LinuxWave 网络安装

通过 GitHub 从网络安装 LinuxWave 到 `/home/linuxwave/.linuxwave`，并让**任意用户**都能使用 `wave`。

与 [INSTALL-EXAMPLE.md](INSTALL-EXAMPLE.md) 的目标相同，区别是**不使用本地镜像**，直接按官方方式从 GitHub 拉取文件。适用于没有任何本地源码副本的场景。

下例中操作者是 `mike`（安装目标用户固定为 `linuxwave`）。

---

## ① 创建专用用户

```console
mike@mike-Inspiron-16-Plus-7640:~$ sudo useradd -m -d /home/linuxwave -s /bin/bash linuxwave
```

`linuxwave` 用户的 `$HOME` 必须是 `/home/linuxwave`：安装器用它判定"是否需要 sudo"，也用它定位用户级配置目录。

## ② 安装 patchelf

```console
mike@mike-Inspiron-16-Plus-7640:~$ sudo apt install -y patchelf
```

**必需**。`patchelf` 负责把每个 ELF 的 `RUNPATH` 重写成指向 LinuxWave 自己目录树内的相对路径。缺少它时安装器只打印警告并跳过重定位，装了带依赖的包（`wget`、`tmux`、`htop`、`ncdu`…）会跑不起来。

其他发行版：

```console
# Fedora / RHEL
mike@mike-Inspiron-16-Plus-7640:~$ sudo dnf install -y patchelf

# Arch
mike@mike-Inspiron-16-Plus-7640:~$ sudo pacman -S patchelf
```

## ③ 确认 Python 版本

```console
mike@mike-Inspiron-16-Plus-7640:~$ python3 --version
Python 3.14.4
```

需要 **Python 3.14 或以上**。原因是 `.conda` 归档要用标准库 `compression.zstd`（3.14 新增）解压；`.tar.bz2` 则用到 3.12 起才有的 `tarfile` filter 参数。

发行版自带的 Python 通常偏旧，若低于 3.14 需要自行升级（发行版仓库、pyenv、或从源码编译）。

## ④ 安装

一条命令，从仓库的默认分支拉取安装器：

```console
mike@mike-Inspiron-16-Plus-7640:~$ /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/LinuxWaveOrg/LinuxWave/HEAD/lib/install.sh)"
```

交互共三处：

| 提示 | 输入 |
| --- | --- |
| `Where do you want to install LinuxWave? (Enter the number)` | `4`（shared, all users） |
| `Have you read and agreed to the agreement? [Y/n]` | `Y`（或直接回车） |

选 `4` 即共享安装，安装器会直接使用 `/home/linuxwave/.linuxwave` 并打印前置准备清单，**无需**再手工输入该路径。

> 选项 `4` 在 **2.5** 及更早版本上是「自定义目录」。若你用的是旧安装器，请选 `4` 并手工输入 `/home/linuxwave/.linuxwave`。

> 回答 `n` 时脚本会执行 `rm -rf "$BASE_DIR"`，把目标目录整个删掉。

### 为什么不是 `sudo bash install.sh`

安装器判定"是否需要 sudo"的规则是：**安装目录是否落在当前 `$HOME` 之下**。

- 直接 `sudo bash install.sh`：`HOME` 是 `/root`，而目标目录是 `/home/linuxwave/.linuxwave`，不在其下 → 判定为**系统级**，配置写进 `/etc/linuxwave_config`，且所有文件属主变成 `root`（还得再手工 `chown`）
- 直接以 `linuxwave` 身份运行：`HOME` 是 `/home/linuxwave`，目标目录在其下 → 判定为**用户级**，配置写进 `~/.config/linuxwave_config`，安装过程内部**完全不需要 sudo**

因此推荐后者。若无法切换到该用户（例如 sudoers 不允许 `sudo -u`），可以显式指定 `HOME` 并事后交出属主：

```console
mike@mike-Inspiron-16-Plus-7640:~$ sudo HOME=/home/linuxwave bash -c "$(curl -fsSL https://raw.githubusercontent.com/LinuxWaveOrg/LinuxWave/HEAD/lib/install.sh)"
mike@mike-Inspiron-16-Plus-7640:~$ sudo chown -R linuxwave:linuxwave /home/linuxwave
```

> `sudo` 只提权，**不会**修改 `HOME`（部分发行版还会重置它），所以必须显式指过去。

完整的终端实录见 [INSTALL-INTERACTION.md](INSTALL-INTERACTION.md)。

## ⑤ 交出属主

```console
mike@mike-Inspiron-16-Plus-7640:~$ sudo chown -R linuxwave:linuxwave /home/linuxwave
```

若第 ④ 步是**以 linuxwave 身份**运行的，这一步可以跳过。若是用 `sudo HOME=...` 运行的，则必须执行——否则 `linuxwave` 自己无法 `wave install`（需要写 `bin/`、`deps/`、`pkg/installed.json`）。

## ⑥ 建立系统级配置

```console
mike@mike-Inspiron-16-Plus-7640:~$ sudo mkdir -p /etc/linuxwave_config
mike@mike-Inspiron-16-Plus-7640:~$ sudo tee /etc/linuxwave_config/config.json > /dev/null <<'EOF'
{"base_dir": "/home/linuxwave/.linuxwave"}
EOF
mike@mike-Inspiron-16-Plus-7640:~$ sudo tee /etc/linuxwave_config/VERSION.json > /dev/null <<'EOF'
{"version": "2.5", "components": {"installer": "2.5", "parser": "2.5"}}
EOF
mike@mike-Inspiron-16-Plus-7640:~$ sudo chmod 755 /etc/linuxwave_config
mike@mike-Inspiron-16-Plus-7640:~$ sudo chmod 644 /etc/linuxwave_config/config.json /etc/linuxwave_config/VERSION.json
```

### 为什么必须建

`wave` 定位配置目录的规则是**系统级优先**：

1. `/etc/linuxwave_config` —— 只要 `config.json` 存在就用它
2. `~/.config/linuxwave_config` —— 否则回落到**当前用户自己**的

第 ④ 步写的是 `linuxwave` 家目录里的那一份。其他用户运行 `wave` 时，第 2 项会解析到**他们自己**的 `$HOME`，那里什么都没有，于是得到：

```console
mike@mike-Inspiron-16-Plus-7640:~$ wave --version
🌊 Error: Configuration file not found or invalid.
🌊 Please run the install script again to reinstall LinuxWave.
```

这句提示是误导的——用户并没有装过。`/etc` 那一份就是给所有人提供公共的解析目标，缺了它就只有 `linuxwave` 本人能用。

`base_dir` 填的是 LinuxWave 的**实际安装位置**，而不是 `$HOME` 展开的结果，这正是该字段存在的意义。

## ⑦ 放开权限

```console
mike@mike-Inspiron-16-Plus-7640:~$ sudo chmod 755 /home/linuxwave
mike@mike-Inspiron-16-Plus-7640:~$ sudo chmod -R a+rX /home/linuxwave/.linuxwave
```

`useradd -m` 默认把家目录建成 `750`，其他用户**连进入都不行**。

`a+rX` 里大写的 `X` 表示"仅对目录和原本就可执行的文件添加 `x`"，不会把普通文件误变成可执行文件。

## ⑧ 让 mike 也能用

```console
mike@mike-Inspiron-16-Plus-7640:~$ echo 'export PATH="/home/linuxwave/.linuxwave/bin:/home/linuxwave/.linuxwave/links:/home/linuxwave/.linuxwave/lib:$PATH"' >> ~/.bashrc
```

## ⑨ 验证

```console
mike@mike-Inspiron-16-Plus-7640:~$ source ~/.bashrc && wave --version
🌊 LinuxWave 2.5
mike@mike-Inspiron-16-Plus-7640:~$ ls -ld /home/linuxwave/.linuxwave && cat /etc/linuxwave_config/config.json
drwxr-xr-x 9 linuxwave linuxwave 4096 Oct  6 22:21 /home/linuxwave/.linuxwave
{"base_dir": "/home/linuxwave/.linuxwave"}
mike@mike-Inspiron-16-Plus-7640:~$
```

---

## 结果

| 项 | 值 |
| --- | --- |
| 安装目录 | `/home/linuxwave/.linuxwave`（属主 `linuxwave:linuxwave`，权限 755） |
| 安装内容 | 20 个文件，7 个子目录：`bin` `deps` `downloads` `lib` `links` `pkg` `surfboard` |
| 系统级配置 | `/etc/linuxwave_config/`（属主 `root:root`，权限 644） |
| 用户级配置 | `/home/linuxwave/.config/linuxwave_config/` |
| 可用性 | 任意用户均可运行 `wave` |
| 依赖库重定位 | 已启用（安装时输出 `patchelf detected`） |

---

## 网络相关的注意事项

### 安装器要下载约 20 个文件，且任一失败即中止

安装器先取一份文件清单（`configdata/versiondata/files_info`，**有 3 次重试**），再从 `raw.githubusercontent.com` **串行**拉取 `lib/`、`pkg/`、`surfboard/` 下的全部代码文件。

逐个下载的部分**没有重试**，而脚本带 `set -e`——任何一次请求失败，整个安装立即停止。已下载的文件会留在目标目录，重跑安装器会覆盖它们（脚本只在"拒绝许可协议"时才删除目录）。

若 `raw.githubusercontent.com` 在本网络下不稳定，常见现象是：

```console
curl: (35) Recv failure: 连接被对方重置
curl: (28) Failed to connect ... timed out
```

**对策**：直接重跑同一条命令，直到走完。若该域名长期不可用，改用 [INSTALL-EXAMPLE.md](INSTALL-EXAMPLE.md) 里的本地镜像方式。

### 索引数据同样来自该域名

`wave install` / `search` / `info` 会实时从 `infosource` 分支拉取索引（`pkginfo_*` 与依赖数据），也走 `raw.githubusercontent.com`。索引不通时的表现是"无法获取软件包数据"，而不是包本身下载失败。

### 软件包本体来自其他域名

包文件大多托管在 `conda.anaconda.org` 或各项目自己的 GitHub Releases，与索引走的域名不同，因此**索引能通不代表包能下**，反之亦然。

### `wave selfupdate`

自更新同样按 `HEAD` 拉取代码文件，与安装器走同一路径，网络要求一致。

---

## 可选：让多个用户都能安装软件包

⑦ 只授予了「读 + 执行」，其他用户仍**不能写入**（`wave install` 会因权限失败）。要做成真正可共享安装的 Linuxbrew，需要引入用户组与 setgid：

```console
mike@mike-Inspiron-16-Plus-7640:~$ sudo groupadd -f linuxwave
mike@mike-Inspiron-16-Plus-7640:~$ sudo usermod -aG linuxwave linuxwave mike
mike@mike-Inspiron-16-Plus-7640:~$ sudo chgrp -R linuxwave /home/linuxwave/.linuxwave
mike@mike-Inspiron-16-Plus-7640:~$ sudo chmod -R g+w /home/linuxwave/.linuxwave
mike@mike-Inspiron-16-Plus-7640:~$ sudo find /home/linuxwave/.linuxwave -type d -exec chmod g+s {} +
```

**执行后需要重新登录**（或 `newgrp linuxwave`）组身份才生效。

> 多用户共享写入意味着组内任何人都能改动整个安装树，包括 `lib/` 里的 `wave` 本体。若不需要多人安装，**建议只做 ⑦**。
