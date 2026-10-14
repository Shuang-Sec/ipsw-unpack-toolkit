# 01 · 获取并解密 IPSW

## IPSW 是什么

IPSW 是 Apple 发布的**完整设备固件包**，任何人都能从官方 CDN 下载，无需登录、无需开发者账号。
一个现代 iPhone 的 IPSW 约 8–11 GB，内部是一个 zip64 归档，包含：

```
BuildManifest.plist
kernelcache.*
        ⋮
<一个大 dmg>             ← 系统卷，AEA1 加密
<另一个 dmg>             ← 通常是系统数据卷
```

我们关心的 `dyld_shared_cache`（下面简称 dyld 缓存）就在那个大 dmg 里。

## 查下载地址

Apple 不提供"版本 → 链接"的公开接口，社区维护的 [ipsw.me](https://ipsw.me) 有：

```bash
curl -s "https://api.ipsw.me/v4/device/iPhone14,8?type=ipsw" \
  | jq -r '.firmwares[] | select(.buildid=="23G90") | .url'
```

返回形如 `https://updates.cdn-apple.com/2026SummerFCS/fullrestores/.../iPhone14,8_23G90_Restore.ipsw`。

> **旧版本不会消失**：实测 2025-09 发布的 18.7 仍在线上，HTTP 200。Apple 会撤下签名，但归档文件长期保留。

## 解密：AEA1 / WKMS

那个 dmg 不是普通镜像，而是 **AEA1 格式** 的加密归档，密钥封装在 `com.apple.wkms` 里。

手工解密这一层相当麻烦（需要拿到设备的 HW crypto 密钥派生链）。实务做法是用
[`ipsw`](https://github.com/blacktop/ipsw) —— 它是纯 Go 实现，能直接处理：

```bash
ipsw extract --dyld --dyld-arch arm64e <本地.ipsw> -o out/
```

## 关键技巧：不下载整个固件

IPSW 托管在 CDN 上，**支持 HTTP Range 请求**，响应头带 `Accept-Ranges: bytes`。
`ipsw` 的 `--remote` 模式正是利用这一点：

```bash
ipsw extract --dyld --dyld-arch arm64e --remote <IPSW_URL> -o out/
```

它先取 zip 中央目录，算出需要的那几个分卷的字节区间，**只拉取这些区间**再本地解密。
实测：10.7 GB 的固件只需要传输约 5 GB，省掉近一半流量和等待时间。

## 这一阶段的实际开销

| 项 | 实测值 |
| :--- | :--- |
| 单次提取总耗时 | 2–5 分钟（视 CDN 速度） |
| 其中网络占比 | 约 70–80% |
| 磁盘峰值 | 约 5 GB（解密后的 dmg） |
| 解出内容 | 约 500 MB（解包后） |

> **两个容易踩的提示**
>
> 1. `ipsw` 常报 `failed to find dyld_shared_cache(s) in DMG` 并保留一个 backing image ——
>    这在用替代挂载器时会正常出现，实际内容已解出，可忽略。
> 2. 临时目录别放 `tmpfs`（`/tmp` 常常是内存盘）。固件动辄数 GB，会直接把内存写满并报 `EDQUOT`。
>    在脚本里显式设置 `TMPDIR` 指向磁盘上的目录。

## 下一步

解出来的 dmg 需要用"挂载器"展开 —— 见 [02 · APFS 解包](02-apfs-unpack.md)。
