# LinuxWave 的签名密钥（说明）

这里放**公钥**。私钥从不进仓库。

## 当前状态

**已启用**（4.4.0 起）：`lib/install.sh` 里内嵌了真公钥，`linuxwavedata/latest.toml`
带 `.sig`，不符合时按「警告 + 继续」处理，`LINUXWAVE_STRICT_HASHES=1` 时失败。

两把钥各自的职责：

| 钥 | 用途 | 放在哪 |
| --- | --- | --- |
| RSA（`linuxwave-rsa.pub.pem`） | 签 `linuxwavedata/latest.toml`，客户端用 `openssl dgst -verify` 验 | 本目录 + 内嵌进 `lib/install.sh` |
| GPG（`D0E229FB.asc`） | 签 Release 附件的 `SHA256SUMS`，`net/signature.py` 验 | 本目录 + 安装树的 `Keys/` |

**RSA 那把与 MacWave 共用同一份密钥**（同一个维护者在发这两个产品）：私钥在
`~/MD/密钥/private/macwave-rsa.key`，这里只是它的公钥副本，文件名沿用 LinuxWave
自己的命名（`scripts/embed_rsa_pub.py` 按 `Keys/linuxwave-rsa.pub.pem` 找文件）。
共用不等于可以混用：两个产品的 `latest.toml` 各签各的，轮换时两边都要重签。

**GPG 那把也是同一把**（指纹 `7220E218395DE865AACC339167F14E52D0E229FB`），
`net/signature.py` 的 `PINNED_FINGERPRINTS` 里写的就是它。

## 结构

```
Keys/linuxwave-rsa.pub.pem    RSA 公钥（PEM），由 scripts/embed_rsa_pub.py 嵌进 lib/install.sh
Keys/D0E229FB.asc             GPG 公钥（ASCII armor），net/signature.py 用它在安装树里验 SHA256SUMS.asc
Keys/description.md           本文件
```

`lib/install.sh` 是被 `curl` 下来直接执行的，没法 `source` 外部文件，所以验
`linuxwavedata/latest.toml` 的签名时只能用脚本里自带的那一份公钥 —— 由
`scripts/embed_rsa_pub.py` 从本目录同步过去。

**刻意不读安装树里的 `Keys/*.pem`**：那份和 `latest.toml` 走同一条下载通道，
能换数据的人也能换公钥，拿它验等于自证。脚本内置的这份是「上一次可信安装」留下
的锚点。

## 生成密钥（管理员，一次性）

当前用的是与 MacWave 共用的那把钥，**不需要再生成**。真要为 LinuxWave 单独起一把时：

```bash
# 私钥留在自己机器上，永不上传；口令请用强口令
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 \
    -aes-256-cbc -out ~/MD/密钥/private/linuxwave-rsa.key

# 导出公钥（覆盖共用的那一份）
openssl pkey -in ~/MD/密钥/private/linuxwave-rsa.key -pubout \
    -out Keys/linuxwave-rsa.pub.pem

# 嵌进 lib/install.sh（别手工改，少一个字符就验不过，而验不过是警告）
python3 scripts/embed_rsa_pub.py
```

GPG 那把若也要换，用 `gpg --armor --export <新指纹> > Keys/<KEYID>.asc` 导出，
同时改 `net/signature.py` 的 `PINNED_FINGERPRINTS`（旧指纹先留着，已发布的旧版
仍要用它验）。

## 签发自更新数据

```bash
openssl dgst -sha256 -sign ~/MD/密钥/private/macwave-rsa.key \
    -out latest.toml.sig latest.toml
```

`latest.toml.sig` 放在 `linuxwavedata/` 下与探针并列。客户端取不到它（404）时
按「这一版没签名」处理，不报错。

## 轮换

1. 生成新钥 → 导出公钥覆盖 `Keys/linuxwave-rsa.pub.pem`
2. `python3 scripts/embed_rsa_pub.py` 重嵌公钥，提交
3. 用新私钥重签 `latest.toml`，推送 `.sig`
4. **顺序很重要**：先发带新公钥的客户端，再换签名。反过来会让还在用旧公钥的
   客户端把新签名判成「不符」—— 实验期只是警告，`LINUXWAVE_STRICT_HASHES=1`
   的用户则会直接失败。

## 严格模式

实验期验不过是**警告**。要让它变成硬失败：

```bash
LINUXWAVE_STRICT_HASHES=1 bash install.sh
```

`wave selfupdate` 同理（该开关在两边含义一致）。
