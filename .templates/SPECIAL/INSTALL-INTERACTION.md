# 安装交互实录

> 该实录取自 **2.5** 版的安装器。自 **2.5.1** 起菜单新增了共享安装项，选项编号已变：自定义目录由 `4` 移到 `5`，共享安装为 `4`（`/usr/local/linuxwave` 也对 arm64 开放）。以下输出保留当时原样。

只记录终端交互，不含说明。操作者 `mike`，安装目标用户 `linuxwave`。

```console
mike@mike-Inspiron-16-Plus-7640:~$ sudo useradd -m -d /home/linuxwave -s /bin/bash linuxwave
mike@mike-Inspiron-16-Plus-7640:~$ sudo apt install -y patchelf
mike@mike-Inspiron-16-Plus-7640:~$ mkdir -p /tmp/lw-mirror/main /tmp/lw-mirror/configdata
mike@mike-Inspiron-16-Plus-7640:~$ cp -r main/lib main/pkg main/surfboard /tmp/lw-mirror/main/
mike@mike-Inspiron-16-Plus-7640:~$ cp -r configdata/versiondata configdata/updatedata /tmp/lw-mirror/configdata/
mike@mike-Inspiron-16-Plus-7640:~$ cp main/lib/install.sh /tmp/lw-mirror/install-offline.sh
mike@mike-Inspiron-16-Plus-7640:~$ sed -i 's|^BASE_URL=.*|BASE_URL="file:///tmp/lw-mirror/main"|' /tmp/lw-mirror/install-offline.sh
mike@mike-Inspiron-16-Plus-7640:~$ sed -i 's|^CONFIGDATA_URL=.*|CONFIGDATA_URL="file:///tmp/lw-mirror/configdata"|' /tmp/lw-mirror/install-offline.sh
mike@mike-Inspiron-16-Plus-7640:~$ chmod -R a+rX /tmp/lw-mirror
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
mike@mike-Inspiron-16-Plus-7640:~$ sudo chown -R linuxwave:linuxwave /home/linuxwave
mike@mike-Inspiron-16-Plus-7640:~$ sudo mkdir -p /etc/linuxwave_config
mike@mike-Inspiron-16-Plus-7640:~$ sudo tee /etc/linuxwave_config/config.json > /dev/null <<'EOF'
{"base_dir": "/home/linuxwave/.linuxwave"}
EOF
mike@mike-Inspiron-16-Plus-7640:~$ sudo tee /etc/linuxwave_config/VERSION.json > /dev/null <<'EOF'
{"version": "2.5", "components": {"installer": "2.5", "parser": "2.5"}}
EOF
mike@mike-Inspiron-16-Plus-7640:~$ sudo chmod 755 /etc/linuxwave_config
mike@mike-Inspiron-16-Plus-7640:~$ sudo chmod 644 /etc/linuxwave_config/config.json /etc/linuxwave_config/VERSION.json
mike@mike-Inspiron-16-Plus-7640:~$ sudo chmod 755 /home/linuxwave
mike@mike-Inspiron-16-Plus-7640:~$ sudo chmod -R a+rX /home/linuxwave/.linuxwave
mike@mike-Inspiron-16-Plus-7640:~$ echo 'export PATH="/home/linuxwave/.linuxwave/bin:/home/linuxwave/.linuxwave/links:/home/linuxwave/.linuxwave/lib:$PATH"' >> ~/.bashrc
mike@mike-Inspiron-16-Plus-7640:~$ source ~/.bashrc && wave --version
🌊 LinuxWave 2.5
mike@mike-Inspiron-16-Plus-7640:~$ ls -ld /home/linuxwave/.linuxwave && cat /etc/linuxwave_config/config.json
drwxr-xr-x 9 linuxwave linuxwave 4096 Oct  6 22:21 /home/linuxwave/.linuxwave
{"base_dir": "/home/linuxwave/.linuxwave"}
mike@mike-Inspiron-16-Plus-7640:~$
```

---

本实录以本地镜像启动（原因见 [INSTALL-EXAMPLE.md](INSTALL-EXAMPLE.md)）。改用网络安装时，只把最后那条启动命令换成：

```console
mike@mike-Inspiron-16-Plus-7640:~$ /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Sha0huaZhang/LinuxWave/HEAD/lib/install.sh)"
```

其后的提示、选项与输出完全相同，流程见 [INSTALL_BY_INTERNET.md](INSTALL_BY_INTERNET.md)。
