# LinuxWave 完整安装示例

把 LinuxWave 安装到 `/home/linuxwave/.linuxwave`，并让**任意用户**都能使用 `wave`。

这套做法参照 **Linuxbrew** 的 `/home/linuxbrew` 模式：一个专用系统用户持有安装目录，其余用户通过共享读取 + 系统级配置来使用。

下例中操作者是 `mike`（安装目标用户固定为 `linuxwave`）。

---

## ① 前置：创建专用用户 + 安装 patchelf

```console
mike@mike-Inspiron-16-Plus-7640:~$ sudo useradd -m -d /home/linuxwave -s /bin/bash linuxwave
mike@mike-Inspiron-16-Plus-7640:~$ sudo apt install -y patchelf
```

`patchelf` 是**必需**的：它负责把每个 ELF 的 `RUNPATH` 重写成指向 LinuxWave 自己目录树内的相对路径。缺少它，安装器只打印警告并跳过重定位，装了带依赖的包（`wget`、`tmux`、`htop`、`ncdu`…）会跑不起来。

`linuxwave` 用户的 `$HOME` 必须是 `/home/linuxwave` —— 安装器用它来判定"是否需要 sudo"，也用它来定位用户级配置目录。

---

## ② 离线镜像（可选）

`raw.githubusercontent.com` 在本机并不稳定（实测成功率约 20%），而安装器要**串行**下载约 20 个文件并带 `set -e`，任何一次失败都会整体中止。此时可以改用本地镜像。

```console
mike@mike-Inspiron-16-Plus-7640:~/Projects/LinuxWave$ mkdir -p /tmp/lw-mirror/main /tmp/lw-mirror/configdata
mike@mike-Inspiron-16-Plus-7640:~/Projects/LinuxWave$ cp -r main/lib main/pkg main/surfboard /tmp/lw-mirror/main/
mike@mike-Inspiron-16-Plus-7640:~/Projects/LinuxWave$ cp -r configdata/versiondata configdata/updatedata /tmp/lw-mirror/configdata/
mike@mike-Inspiron-16-Plus-7640:~/Projects/LinuxWave$ cp main/lib/install.sh /tmp/lw-mirror/install-offline.sh
mike@mike-Inspiron-16-Plus-7640:~/Projects/LinuxWave$ sed -i 's|^BASE_URL=.*|BASE_URL="file:///tmp/lw-mirror/main"|' /tmp/lw-mirror/install-offline.sh
mike@mike-Inspiron-16-Plus-7640:~/Projects/LinuxWave$ sed -i 's|^CONFIGDATA_URL=.*|CONFIGDATA_URL="file:///tmp/lw-mirror/configdata"|' /tmp/lw-mirror/install-offline.sh
mike@mike-Inspiron-16-Plus-7640:~/Projects/LinuxWave$ chmod -R a+rX /tmp/lw-mirror
```

只改了 `BASE_URL` 与 `CONFIGDATA_URL` 两行，安装器其余逻辑原样不动（`curl` 直接支持 `file://`）。

> **网络正常时跳过本步**，直接用官方一行命令：
>
> ```console
> mike@mike-Inspiron-16-Plus-7640:~$ /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Sha0huaZhang/LinuxWave/HEAD/lib/install.sh)"
> ```

> 注意：镜像放在 `/tmp` 下，重启后可能被清理。

---

## ③ 安装

```console
mike@mike-Inspiron-16-Plus-7640:~$ sudo HOME=/home/linuxwave bash /tmp/lw-mirror/install-offline.sh
[sudo: authenticate] 密码：
🌊 Welcome to LinuxWave 2.5!

🌊 Detected architecture: x86_64
Where do you want to install LinuxWave? (Enter the number)
1. ~/.local/linuxwave
2. /opt/linuxwave
3. /usr/local/linuxwave
4. other (enter custom directory)

Enter your choice:
4
Please enter the installation directory:
/home/linuxwave/.linuxwave
🌊 Fetching the file list...
🌊 Configuration saved to /home/linuxwave/.config/linuxwave_config/config.json
🌊 Version saved to /home/linuxwave/.config/linuxwave_config/VERSION.json
🌊 patchelf detected (dependency library relocation enabled).
🌊 Downloading 20 file(s) from branch: HEAD

🌊 Downloading lib/wave.py...
🌊 Downloading lib/help.py...
🌊 Downloading lib/configerror.py...
🌊 Downloading lib/configpaths.py...
🌊 Downloading lib/selfupdate.py...
🌊 Downloading lib/selfupdate.sh...
🌊 Downloading pkg/pkginstaller.py...
🌊 Downloading pkg/pkginstaller.sh...
🌊 Downloading pkg/pkginfohelper.py...
🌊 Downloading pkg/uninstaller.py...
🌊 Downloading pkg/pkgversionparser.py...
🌊 Downloading pkg/pkgunzip.sh...
🌊 Downloading pkg/linker.py...
🌊 Downloading surfboard/depsinstaller.py...
🌊 Downloading surfboard/depsinstaller.sh...
🌊 Downloading surfboard/depsmanager.sh...
🌊 Downloading surfboard/depsversionparser.py...
🌊 Downloading surfboard/querier.py...
🌊 Downloading surfboard/tagger.sh...
🌊 Downloading surfboard/transfer.sh...
🌊 Checking Python dependencies...
🌊 'requests' library is already installed.
🌊 'packaging' library is already installed.
🌊 'rich' library is already installed.
🌊 Adding LinuxWave to PATH in /home/linuxwave/.bashrc

🌊 Installation complete!
🌊 LinuxWave installed to: ~/.linuxwave
🌊 Architecture: x86_64

🌊 To use 'wave' immediately in this terminal, run:
    source ~/.bashrc
🌊 Or simply open a new terminal window.


Please read the agreement before use (see bottom of https://linuxwave.macwave.org).
Have you read and agreed to the agreement? [Y/n]
y
You have agreed to the agreement. Installation continues.
```

### 两个要点

**为什么写成 `sudo HOME=/home/linuxwave`？**
`sudo` 只提权，**不会**修改 `HOME`（在部分发行版上还会重置它）。因此显式把 `HOME` 指过去，安装器才会走"用户级安装"分支：配置写入 `~/.config/linuxwave_config` 而不是 `/etc/linuxwave_config`，且安装过程内部不再需要 sudo。

**为什么目录填绝对路径？**
因为此时 `HOME=/home/linuxwave`，但安装器对 `~` 的展开基于 `$HOME`。填绝对路径 `/home/linuxwave/.linuxwave` 最稳妥，不会因为 `HOME` 被重置而装错地方。

**安装器会问三次**：目录菜单（选 `4`）、自定义目录（填绝对路径）、许可协议（`Y` 或回车 —— 回答 `n` 会执行 `rm -rf "$BASE_DIR"` 把目标目录删掉）。

---

## ④ 把属主交给 linuxwave

```console
mike@mike-Inspiron-16-Plus-7640:~$ sudo chown -R linuxwave:linuxwave /home/linuxwave
```

③ 是以 root 身份创建的目录，不交出属主的话，`linuxwave` 自己无法 `wave install`（需要写 `bin/`、`deps/`、`pkg/installed.json`）。

---

## ⑤ 建立系统级配置（跨用户使用的关键）

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
2. `~/.config/linuxwave_config` —— 否则回落到当前用户的

也就是说，其他用户运行 `wave` 时，用户级路径会解析到**他们自己**的 `$HOME`（如 `/home/mike/.config/linuxwave_config`），那里面什么都没有。没有这份系统级配置，`mike` 跑 `wave` 只会得到"配置未找到，请重新运行安装脚本"。

`base_dir` 指向 LinuxWave 的实际安装位置，而**不是** `$HOME` 展开的结果 —— 这正是它存在的意义。

---

## ⑥ 放开权限（Linuxbrew 式）

```console
mike@mike-Inspiron-16-Plus-7640:~$ sudo chmod 755 /home/linuxwave
mike@mike-Inspiron-16-Plus-7640:~$ sudo chmod -R a+rX /home/linuxwave/.linuxwave
```

`useradd -m` 默认把家目录建成 `750`，其他用户**连进入都不行**。改成 `755` 后其余用户才可读取与执行。

`a+rX` 中大写的 `X` 表示"仅对目录和原本就可执行的文件添加 `x`"，因此不会把普通文件误变成可执行文件。

---

## ⑦ 让 mike 也能用

```console
mike@mike-Inspiron-16-Plus-7640:~$ echo 'export PATH="/home/linuxwave/.linuxwave/bin:/home/linuxwave/.linuxwave/links:/home/linuxwave/.linuxwave/lib:$PATH"' >> ~/.bashrc
```

三个目录各有用途：`bin/` 放带版本号的可执行文件、`links/` 放不带版本号的软链接（`wave link` 生成）、`lib/` 放 `wave` 本体。

---

## ⑧ 验证

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
| 依赖库重定位 | 已启用（`patchelf detected`） |

---

## 后续：安装软件包

`wave install` 会实时从 `infosource` 分支拉取索引数据（`pkginfo_*` 与依赖数据），因此**需要能访问 `raw.githubusercontent.com`**。若该域名不通，会出现拉取索引失败，处理方式与 ② 同理（可用本地索引镜像绕开）。

```console
mike@mike-Inspiron-16-Plus-7640:~$ wave install wget@1.25.0
```

> 软件包本体大多来自 `conda.anaconda.org` 或各项目自己的 GitHub Releases，与索引走的域名不同。

---

## 可选：让多个用户都能安装软件包

⑥ 只授予了「读 + 执行」，其他用户仍**不能写入**。要做成真正可共享安装的 Linuxbrew，需要引入用户组与 setgid：

```console
mike@mike-Inspiron-16-Plus-7640:~$ sudo groupadd -f linuxwave
mike@mike-Inspiron-16-Plus-7640:~$ sudo usermod -aG linuxwave linuxwave mike
mike@mike-Inspiron-16-Plus-7640:~$ sudo chgrp -R linuxwave /home/linuxwave/.linuxwave
mike@mike-Inspiron-16-Plus-7640:~$ sudo chmod -R g+w /home/linuxwave/.linuxwave
mike@mike-Inspiron-16-Plus-7640:~$ sudo find /home/linuxwave/.linuxwave -type d -exec chmod g+s {} +
```

`g+s` 让新建文件继承父目录的组，避免不同用户创建的文件互相不可写。

**执行后需要重新登录**（或 `newgrp linuxwave`）组身份才生效。

> 多用户共享写入意味着任何人（组内）都能改动整个安装树，包括 `lib/` 里的 `wave` 本体。若不需要多人安装，**建议只做 ⑥**，保持最简、最安全的共享读取模式。
