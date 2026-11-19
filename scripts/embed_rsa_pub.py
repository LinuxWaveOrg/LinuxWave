#!/usr/bin/env python3
"""把 Keys/linuxwave-rsa.pub.pem 嵌进 lib/install.sh。

`lib/install.sh` 是被 curl 下来直接执行的，没法 source，所以验 latest.toml 签名
时用的公钥只能是脚本里自带的一份。公钥变了（轮换）就跑这个脚本重嵌一次，别手工
改 —— 少一个字符就是验不过，而验不过是**警告**，很容易上线之后才发现。

    python3 scripts/embed_rsa_pub.py           # 重嵌
    python3 scripts/embed_rsa_pub.py --check   # 只检查是否同步（测试用）

密钥还没生成时（本次移植的初始状态），重嵌会把内置公钥写成空串，于是验签整段
跳过 —— 与 4.4 之前的客户端行为一致。
"""

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PUBKEY = ROOT / "Keys" / "linuxwave-rsa.pub.pem"
TARGETS = (ROOT / "lib" / "install.sh",)

BEGIN = "# >>> RSA public key"
END = "# <<< RSA public key"
BLOCK_HEAD = "# >>> RSA public key (managed by scripts/embed_rsa_pub.py) >>>"


def block(pem: str) -> str:
    body = pem.strip("\n")
    return f"{BLOCK_HEAD}\nLW_RSA_PUB_PEM='{body}'\n# <<< RSA public key <<<"


def spliced(text: str, replacement: str, path: Path) -> str:
    start = text.find(BEGIN)
    end = text.find(END)
    if start < 0 or end < 0 or end < start:
        sys.exit(f"error: {path} 里找不到 RSA public key 标记")
    end += len(END)
    newline = text.find("\n", end)
    return text[:start] + replacement + text[newline:]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="只检查，不写文件")
    args = parser.parse_args()

    if PUBKEY.is_file():
        pem = PUBKEY.read_text()
    else:
        pem = ""
        print(f"注意：{PUBKEY.relative_to(ROOT)} 不存在，内置公钥将为空（验签跳过）")

    want = block(pem)
    stale = []
    for path in TARGETS:
        text = path.read_text()
        updated = spliced(text, want, path)
        if updated == text:
            continue
        stale.append(path.relative_to(ROOT))
        if not args.check:
            path.write_text(updated)

    if stale and args.check:
        print("❌ 内置公钥与 Keys/linuxwave-rsa.pub.pem 不一致：" + ", ".join(map(str, stale)))
        print("   跑 python3 scripts/embed_rsa_pub.py 重嵌")
        return 1
    if stale:
        print("已重嵌：" + ", ".join(map(str, stale)))
    else:
        print("内置公钥已同步")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
