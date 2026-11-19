# LinuxWave 的签名密钥（说明）

这里放**公钥**。私钥从不进仓库。

## 当前状态

**尚未生成。** 也就是说 `lib/install.sh` 里内嵌的公钥是空串，验签整段跳过 ——
客户端行为与 4.4 之前一致：能装，但不校验自更新数据的签名。生成密钥并重嵌之后
才会真的验。

## 结构

```
Keys/linuxwave-rsa.pub.pem    RSA 公钥（PEM），由 scripts/embed_rsa_pub.py 嵌进 lib/install.sh
Keys/description.md           本文件
```

`lib/install.sh` 是被 `curl` 下来直接执行的，没法 `source` 外部文件，所以验
`linuxwavedata/latest.toml` 的签名时只能用脚本里自带的那一份公钥 —— 由
`scripts/embed_rsa_pub.py` 从本目录同步过去。

**刻意不读安装树里的 `Keys/*.pem`**：那份和 `latest.toml` 走同一条下载通道，
能换数据的人也能换公钥，拿它验等于自证。脚本内置的这份是「上一次可信安装」留下
的锚点。

## 生成密钥（管理员，一次性）

```bash
# 私钥留在自己机器上，永不上传；口令请用强口令
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 \
    -aes-256-cbc -out ~/密钥/private/linuxwave-rsa.key

# 导出公钥
openssl pkey -in ~/密钥/private/linuxwave-rsa.key -pubout \
    -out Keys/linuxwave-rsa.pub.pem

# 嵌进 lib/install.sh（别手工改，少一个字符就验不过，而验不过是警告）
python3 scripts/embed_rsa_pub.py
```

## 签发自更新数据

```bash
openssl dgst -sha256 -sign ~/密钥/private/linuxwave-rsa.key \
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
