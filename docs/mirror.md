# 镜像站怎么接

> 目标：用户只改**域名**，安装器里所有下载（包括 `install.sh` 自己）都走镜像。
> 做法是不发明新路径 —— 镜像站原样复刻上游的路径形状。

## 为什么只需要改域名

客户端从不「猜」地址，它只会做一件事：拿一个域，拼一段固定的后缀。

| 变量 | 客户端拼出来的 |
| --- | --- |
| `LINUXWAVE_CORE_DOMAIN` | `<域>/<分支>/lib/…`、`/pkg/…`、`/surfboard/…` |
| `LINUXWAVE_SELFUPDATE_DOMAIN` | `<域>/linuxwavedata/latest.toml`、`/linuxwavedata/<版本>/update_commands.sh` |
| `LINUXWAVE_API_DOMAIN` | `<域>/pkg/pkginfo_<arch>/versions`（镜像自己提供的清单） |
| `MACWAVE_CORE_DOMAIN` | `<域>/<分支>/lib/…` |
| `MACWAVE_SELFUPDATE_DOMAIN` | `<域>/macwavedata/latest.toml`、`/rcdata/latest.toml` |
| `MACWAVE_PYTHON_DOMAIN` | `<域>/pythondata/latest.toml`、`/pythondata/<版本>/…` |
| `MACWAVE_API_DOMAIN` | `<域>/pkg/pkginfo_<arch>/versions` |
| `MACWAVE_BOTTLE_DOMAIN` | `<域>/<包名>/<资产>`（GitHub Releases 的同形路径） |
| `MACWAVE_DEPS_DOMAIN` | `<域>/<依赖名>/<资产>` |

所以镜像上摆成这样，后缀自然就对上了（`Org` 取 `LinuxWave` / `MacWave`）：

```
<root>/<Org>/<repo>/<ref>/<仓库内路径>
```

`install.sh` 自己也在里面，不需要为它单开规则：

```
https://mirror.example.com/LinuxWave/LinuxWave/4.0/lib/install.sh
https://mirror.example.com/MacWave/MacWave/4.4/lib/install.sh
```

## 最常见的配错：API 域名少了 ref 段

`LINUXWAVE_API_DOMAIN` / `MACWAVE_API_DOMAIN` 必须**写到 ref 段为止** ——
客户端会在它后面直接拼 `/pkg/pkginfo_<arch>/…`：

```
对： https://mirror.example.com/MacWave/infosource/HEAD
错： https://mirror.example.com/MacWave/infosource      ← 拼出来是 …/infosource/pkg/… → 404 / 401
```

症状是 `wave search`、`wave install <包>` 一律报「读不到包名清单」，而报错里的
URL 已经少了那一段。镜像上哪个 ref 有货取决于同步脚本：

| 镜像 | infosource 的 ref |
| --- | --- |
| LinuxWave | `main` |
| MacWave | `HEAD` |

`wave mirror` 会打印当前生效值与来源，`--raw` 可直接粘进 shell 配置。

## 每个项目要哪几棵树

| 项目 | 仓库 | ref | 用途 |
| --- | --- | --- | --- |
| LinuxWave | `LinuxWaveOrg/configdata` | `main` | `linuxwavedata/latest.toml`、`update_commands.sh`、便携解释器数据 |
| LinuxWave | `LinuxWaveOrg/LinuxWave` | 发布分支（读自 `latest.toml` 的 `branch`）+ `main` | 程序文件 |
| LinuxWave | `LinuxWaveOrg/infosource` | `main` | 索引 |
| MacWave | `MacWaveOrg/Selfupdate` | `HEAD`（默认分支） | `macwavedata/`、`rcdata/` |
| MacWave | `MacWaveOrg/MacWave` | 发布分支 + `main` | 程序文件 |
| MacWave | `MacWaveOrg/Python` | `HEAD` | 便携 CPython |
| MacWave | `MacWaveOrg/infosource` | `HEAD` | 索引 |
| MacWave | `Bottle` / `Deps` 的 Release 资产 | 资产 | 二进制包与依赖（按 `<名>/<文件>` 平铺，见下） |

注意 MacWave 的上游 URL 里 **`HEAD` 是真实的一段路径**（`…/Selfupdate/HEAD/…`），
镜像目录就照写 `HEAD`，不要改成 `main`。

## 同步

仓库里的 [`scripts/mirror_sync.sh`](../scripts/mirror_sync.sh) 一次管两个项目：
发布分支从各自的 `latest.toml` 里读（换版本不用改脚本），顺手生成索引清单。

```bash
sudo install -m 755 scripts/mirror_sync.sh /usr/local/bin/mirror_sync.sh
sudo mirror_sync.sh --root /srv/mirror --project all        # 先加 -n 看它要做什么
```

定时（cron，root）：

```
*/15 * * * * /usr/local/bin/mirror_sync.sh >/dev/null 2>&1
```

临时演练某个分支（例如还未发布的 `4.0-dev`）：

```bash
sudo mirror_sync.sh --extra LinuxWaveOrg/LinuxWave:4.0-dev
sudo mirror_sync.sh --extra MacWaveOrg/MacWave:test/arglen   # 带斜杠的分支会多一层目录
```

### `versions` 清单只有镜像能提供

上游的索引是「一个包一个目录、一个版本一个文件」（`_jq@1.8.2`、`_jq@common`）。
客户端在**设了 API 域**时不去问 GitHub 的 contents API，而是读镜像给的清单：

```
<api>/pkg/pkginfo_<arch>/versions          → 一行一个包名（目录名）
<api>/pkg/pkginfo_<arch>/<包>/versions      → 一行一个**文件名**（_jq@1.8.2、_jq@common）
```

第二份给的是文件名而不是版本号 —— 客户端自己 `split("@")`，也会跳过 `@common`。
`mirror_sync.sh` 每次同步后会重新生成它们（它们未跟踪，`git reset --hard` 不会删掉）。

## nginx

一个站点根指向 `--root`，再按项目开前缀。两条硬规则：

1. **`alias` 的尾斜杠必须与 `location` 成对**，否则路径会多拼或漏拼一层；
2. MacWave **不要写成 `location ^~ /MacWave/`** —— 那会把 `/MacWave/deps/…`、
   `/MacWave/bottle/…` 这些产物路径一起抢走（它们靠更细的 `location ~ "@"` 处理
   `包名@版本` 形式的文件名），装包会当场坏掉。用更长的前缀。

```nginx
# 程序树 / 数据树：只放行匿名只读，不带凭据也能装
location ^~ /LinuxWave/ {
    alias /srv/mirror/LinuxWave/;
    auth_basic off;
    default_type text/plain;
    charset utf-8;
}
location ^~ /MacWave/MacWave/ {
    alias /srv/mirror/MacWave/MacWave/;
    auth_basic off;
    default_type text/plain;
    charset utf-8;
}
location ^~ /MacWave/Selfupdate/ { alias /srv/mirror/MacWave/Selfupdate/; auth_basic off; default_type text/plain; charset utf-8; }
location ^~ /MacWave/Python/     { alias /srv/mirror/MacWave/Python/;     auth_basic off; default_type text/plain; charset utf-8; }
location ^~ /MacWave/infosource/ { alias /srv/mirror/MacWave/infosource/; auth_basic off; default_type text/plain; charset utf-8; }
```

`/MacWave/bottle/` 与 `/MacWave/deps/` 按需要保留鉴权（付费带宽之类）—— 客户端支持
`https://用户:口令@mirror.example.com/...` 这种写法，日志里会被掩成 `用户:***@…`。
但**不要把带凭据的域名写进公开文档**：那行会被贴进 issue，也会出现在 `ps` 里。

## 验证

```bash
M=https://mirror.example.com
for u in \
  LinuxWave/LinuxWave/main/lib/install.sh \
  LinuxWave/configdata/main/linuxwavedata/latest.toml \
  LinuxWave/infosource/main/pkg/pkginfo_amd64/versions \
  MacWave/MacWave/4.4/lib/install.sh \
  MacWave/Selfupdate/HEAD/macwavedata/latest.toml \
  MacWave/Python/HEAD/pythondata/latest.toml \
  MacWave/infosource/HEAD/pkg/pkginfo_arm64/versions
do
  printf '%-54s ' "$u"
  curl -sS -o /dev/null -w '%{http_code} %{size_download}\n' "$M/$u"
done
```

全 `200` 之后，再按下面两条真跑一遍（`--dry-run`，不落盘）。

## 用户侧

LinuxWave：

```bash
LINUXWAVE_CORE_DOMAIN=https://mirror.example.com/LinuxWave/LinuxWave \
LINUXWAVE_SELFUPDATE_DOMAIN=https://mirror.example.com/LinuxWave/configdata/main \
LINUXWAVE_API_DOMAIN=https://mirror.example.com/LinuxWave/infosource/main \
  /bin/bash -c "$(curl -fsSL https://mirror.example.com/LinuxWave/LinuxWave/main/lib/install.sh)"
```

MacWave（**必须用管道**，见下面第 2 条）：

```bash
export MACWAVE_CORE_DOMAIN=https://mirror.example.com/MacWave/MacWave
export MACWAVE_SELFUPDATE_DOMAIN=https://mirror.example.com/MacWave/Selfupdate/HEAD
export MACWAVE_PYTHON_DOMAIN=https://mirror.example.com/MacWave/Python/HEAD
export MACWAVE_API_DOMAIN=https://mirror.example.com/MacWave/infosource/HEAD
export MACWAVE_BOTTLE_DOMAIN=https://mirror.example.com/MacWave/bottle
export MACWAVE_DEPS_DOMAIN=https://mirror.example.com/MacWave/deps
curl -fsSL https://mirror.example.com/MacWave/MacWave/4.4/lib/install.sh | /bin/bash -s -- --dry-run
```

## 三个容易踩的点

1. **`HEAD` 是路径的一部分**（MacWave 的三个数据仓库）。镜像目录名照抄，别改成 `main`。
2. **单参数 131 071 B 上限**：MacWave 的 `install.sh` 已经 139 949 B，`/bin/bash -c "$(curl …)"`
   在 Linux 上会直接 `Argument list too long`（macOS 没有这条限制，所以 MacWave 官方命令是
   `-c` 形式）。在 Linux 上一律用 `curl … | /bin/bash -s -- <参数>`。
3. **pip 索引不在镜像范围**：`LINUXWAVE_PIP_INDEX` / `MACWAVE_PIP_INDEX` 默认指向 PyPI，
   装 `requests` 等依赖那次请求仍出网。要彻底离线，自建一个 PEP 503 索引再指过去。
