# 待办

按「谁受影响」排序，不按发现时间。

## 镜像站

- [ ] **`mirror.repohub.top` 上给出的安装命令要按 `<Org>/<repo>/<ref>/…` 复核一遍**
  2026-11-20 发现的实例：`MACWAVE_API_DOMAIN` 停在 `…/MacWave/infosource`（少了
  `/HEAD`），于是 `wave search` / `wave install` 一律报「读不到包名清单」，URL 里
  那个 404 看起来又像镜像挂了。客户端现在会把「域名要含 ref」直接说出来
  （见 `pkg/pkginfohelper.py` 的 `explain_unreachable_name_list`），但**页面上
  贴出来的命令**同样要写成带 ref 的形状，否则用户照抄就踩坑。

  需要复核的地方：
  - 镜像站首页 / 使用说明里的 `LD_LIBRARY_PATH`、`export …_DOMAIN=`、`curl … install.sh` 示例
  - 每个项目的 ref 不一样（实测：LinuxWave 的 infosource 在 `main`，MacWave 的在 `HEAD`）
  - 带凭据的地址只能出现在需要认证的路径上；给用户抄的命令里不要内嵌 `user:password@`

## 移植

- [ ] 其余 MacWave 脚本按需搬运：`LOCAL-cache_probe.py`、`build_portable_python.sh`
      （macOS 交叉编译，Linux 侧可能不需要）、`known-bad-records.txt`
- [ ] `minos_test.sh`、`rc_channel_test.sh` 不移植（macOS 专属 / rc 通道暂不做）

## 发布

- [ ] 4.0.0 之后的补丁版本：`info --json/--yaml/--toml/--raw`、`upgrade --all`、
      man 页与 MANPATH 都在 `4.0-dev` 上，尚未发版
