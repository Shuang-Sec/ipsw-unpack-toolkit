# 外部依赖

本仓库**不包含**第三方二进制。请自行获取以下工具，并让它们在 `PATH` 中
（或用环境变量 `IPSW_BIN` / `SEVEN_ZIP` 指定路径）。

## 1. ipsw

固件拉流、解密与解包调度。

**方式 A — 直接下载发行版**

从 <https://github.com/blacktop/ipsw/releases> 取对应平台的压缩包，解压后得到 `ipsw` 单文件：

```bash
mkdir -p ~/.local/bin
tar xzf ipsw_*_Linux_x86_64.tar.gz -C /tmp
install -m 0755 /tmp/ipsw ~/.local/bin/ipsw
ipsw version        # 验证
```

**方式 B — 用 Go 编译**

```bash
go install github.com/blacktop/ipsw/cmd/ipsw@latest
```

> 实测版本：v3.1.732。其他版本一般也可用，但 `--remote` 流式提取的行为可能略有差异。

## 2. 7-Zip（21.02 以上）

APFS 解包。**低于 21.02 的版本不支持 APFS**，会直接失败。

```bash
# Debian / Ubuntu
sudo apt install p7zip-full        # 注意：仓库里的版本可能偏旧，务必确认 >= 21.02

# 或从官网取最新静态版（推荐）
curl -LO https://www.7-zip.org/a/7z2301-linux-x64.tar.xz
tar xf 7z2301-linux-x64.tar.xz
install -m 0755 7zz ~/.local/bin/7zz
7zz | head -3                       # 验证
```

本仓库的脚本默认调用 `7zz`（新版命名）；若你的环境里是 `7z`，用 `SEVEN_ZIP=7z` 覆盖。

## 3. 其他

| 工具 | 用途 | 备注 |
| :--- | :--- | :--- |
| `python3` | 运行 `decmpfs_fix.py` | 3.8+，无第三方包依赖 |
| `curl` | 查询固件地址 | 系统一般自带 |
| `jq` | 解析 ipsw.me 返回的 JSON | `apt install jq` |
| C 编译器 | 编译 `zbm` | `gcc` / `clang` 均可 |

## 4. 验证环境

```bash
./src/run_ipsw_unpack.sh iPhone15,2 23G90 ./work
```

若输出了 `✓ 完成：N 个文件`，说明依赖齐全。

## 5. 占位文件说明

本目录保留在仓库中，用于说明外部依赖的获取方式。你也可以把自己编译好的工具放在这里，
但请注意 `.gitignore` 已排除编译产物，避免误提交大文件。
