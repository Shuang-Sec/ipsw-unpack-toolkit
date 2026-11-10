# ipsw-unpack-toolkit

[English](README.md) | **简体中文**

从 Apple **公开** IPSW 固件中解包 `dyld_shared_cache` 的工具集 ——
不需要真机、不需要越狱、不需要开发者账号。

这个仓库只围绕**三个具体问题**展开，每个问题都按「现象 → 根因 → 怎么解」写清楚。

---

## 解决什么问题

### 问题一：没有 `apfs-fuse` 就解不开 APFS

**现象**

```
$ ipsw extract --dyld --remote <IPSW_URL> -o out/
[!] failed to find apfs-fuse
```

什么都解不出来。`ipsw` 已经把镜像解密了，但没有挂载器就读不了里面的文件系统。

**根因**

`ipsw` 通过调用 `apfs-fuse` 来挂载 APFS 卷，而这个二进制很难依赖：

- 需要 FUSE 内核模块，容器和 CI 环境通常没有；
- 链接旧版 `libcrypto`，在新发行版上经常编译失败；
- 挂载卷需要 root。

**方案**

`ipsw` 支持用 `IPSW_APFS_FUSE_PATH` 替换挂载器。`src/fake-apfs-fuse` 正是利用这一点：
它**根本不挂载**，而是把一份包含列表交给 7-Zip，只解出
`System/Library/Caches/com.apple.dyld/` 下的文件。

除了"能跑起来"，还有两个实际收益：

| | 完整挂载 | 本工具集 |
| :--- | ---: | ---: |
| 解出的 APFS 内容 | 约 3.8 GB | 约 520 MB |
| 需要 root | 是 | **否** |
| 需要 FUSE | 是 | **否** |

中间镜像在解包后立即删除，所以磁盘峰值稳定在 5 GB 左右。

---

### 问题二：文件解出来是 0 字节

**现象**

```
dyld_shared_cache_arm64e.35.dylddata      0 字节
```

7-Zip 报 `ERROR: Unsupported Method`，然后留下一个空文件。文件在、名字对，所以下游解析器
报的是莫名其妙的"没有数据"，而不是一个明显的解压失败。

**根因**

APFS 上部分文件是**透明压缩**（`decmpfs`）存储的：压缩数据放在
`<文件>:com.apple.ResourceFork`，头部信息放在 `<文件>:com.apple.decmpfs`。

压缩类型 **14 = `CMP_RSRC_LZBITMAP`** **没有公开规范**。7-Zip 和主流压缩库都不支持，
于是文件被静默地解成空。

在部分机型上，`.dylddata` 段（字符串池和常量数组所在）恰好就是这么存的。
跳过这一步，你拿到的是一堆"存在但没有内容"的文件。

**方案**

`src/lzbitmap/` 是 LZBitmap 解压器的零依赖 C 实现（`libzbitmap.c`，约 1,200 行）
加一个命令行工具（`zbm`）。`src/decmpfs_fix.py` 扫描解包目录，找出带 decmpfs 属性的
0 字节文件并逐个还原。

> **最容易踩的坑**：`zbm_decompress()` **返回 0 表示成功**，负值才是错误码。
> 写成 `if (ret > 0)` 会让**每一块**都被判为失败；而且 0 看起来也像"没写入字节"，
> 错误路径给不出任何有用信息。详细说明见 [docs/03-lzbitmap.md](docs/03-lzbitmap.md)。

---

### 问题三：批量跑几百个会中断

**现象**

无人值守跑几百个"机型 × 版本"组合时，总会出岔子：网络抖动、`ipsw` 进程卡在 0% CPU、
磁盘写满。

**方案**

`src/batch_unpack.sh` 在单组合脚本外面加了四道保护：

| 保护 | 做法 |
| :--- | :--- |
| **断点续跑** | 判断依据是**磁盘上的产物**，不是完成清单 |
| **失败重试** | 每个组合最多 2 次，中间清理临时目录 |
| **卡死保护** | 给提取步骤套 `timeout` |
| **磁盘保护** | 剩余空间低于阈值时清理临时目录 |

断点续跑为什么不用状态文件：早期版本把"已完成"记在状态文件里，结果一个 bug 导致产物
**根本没被移动到位** —— **日志说"完成"，输出目录却是空的**。改用产物本身判断之后，
这类 bug 就不可能再藏住。细节见 [docs/04-batch-pipeline.md](docs/04-batch-pipeline.md)。

---

## 快速开始

```bash
git clone https://github.com/Shuang-Sec/ipsw-unpack-toolkit.git
cd ipsw-unpack-toolkit

# 1) 编译 LZBitmap 解压工具（纯 C，无第三方依赖）
make -C src/lzbitmap
export PATH="$PWD/src/lzbitmap:$PATH"

# 2) 解包一个版本（以 iPhone 14 Pro / iOS 26.6.2 为例）
./src/run_ipsw_unpack.sh iPhone15,2 23G90 ./work
```

跑完会得到：

```
work/dsc_iPhone15_2__23G90/System/Library/Caches/com.apple.dyld/
├── dyld_shared_cache_arm64e              主缓存
├── dyld_shared_cache_arm64e.atlas        索引
├── dyld_shared_cache_arm64e.01.dylddata  数据段（字符串池、常量）
├── dyld_shared_cache_arm64e.<N>          大框架拆出的独立子缓存
└── ⋮
```

批量模式：

```bash
./src/batch_unpack.sh examples/devices.txt ./work
```

---

## 仓库结构

```
├── docs/
│   ├── 01-ipsw-fetch.md        IPSW 获取与解密（AEA1/WKMS）
│   ├── 02-apfs-unpack.md       无 apfs-fuse 环境下解包 APFS
│   ├── 03-lzbitmap.md          ★ decmpfs type 14：格式与实现
│   └── 04-batch-pipeline.md    批量长跑的工程实践
├── src/
│   ├── lzbitmap/               ★ LZBitmap 解压库（纯 C，零依赖）
│   │   ├── libzbitmap.c/.h
│   │   ├── zbm.c
│   │   └── Makefile
│   ├── decmpfs_fix.py          批量修复 0 字节的透明压缩文件
│   ├── fake-apfs-fuse          供 ipsw 调用的伪挂载器
│   ├── run_ipsw_unpack.sh      单组合
│   └── batch_unpack.sh         批量驱动（含四道保护）
├── examples/devices.txt        组合列表示例
└── tools/PUT_TOOLS_HERE.md     外部依赖的获取方式
```

---

## 依赖

| 依赖 | 版本 | 用途 |
| :--- | :--- | :--- |
| [`ipsw`](https://github.com/blacktop/ipsw) | 实测 v3.1.x | 固件拉流、解密、调度挂载器 |
| [7-Zip](https://www.7-zip.org/) | **21.02 以上** | APFS 解包（旧版不支持 APFS） |
| `python3` | 3.8+ | `decmpfs_fix.py`（无需第三方包） |
| `curl`、`jq` | — | 查询下载地址 |
| C 编译器 | — | 编译 `zbm` |

安装说明见 [`tools/PUT_TOOLS_HERE.md`](tools/PUT_TOOLS_HERE.md)。

---

## 环境变量

| 变量 | 默认值 | 含义 |
| :--- | :--- | :--- |
| `DSC_DEST` | — | **必填**，解包目标目录（由 `fake-apfs-fuse` 读取） |
| `IPSW_BIN` | `ipsw` | `ipsw` 可执行文件路径 |
| `SEVEN_ZIP` | `7zz` | 7-Zip 可执行文件路径 |
| `ZBM_BIN` | `zbm` | LZBitmap 解压工具路径 |
| `TIMEOUT_SEC` | `900` | 单次提取超时（秒） |
| `DSC_FULL` | `0` | 设为 1 则解出全部子缓存（排查用） |
| `KEEP_DMG` | `0` | 设为 1 则保留中间镜像 |
| `MIN_FREE_KB` | `7000000` | 批量模式的磁盘保护阈值 |

---

## 已知问题

- **`ipsw` 报 `failed to find dyld_shared_cache(s) in DMG` 并保留 backing image** ——
  使用替代挂载器时会正常出现。内容其实已经解出，这条消息可以忽略。
- **别把 `TMPDIR` 指向 `tmpfs`。** 固件动辄数 GB，会把内存写满并报 `EDQUOT`。
  脚本已显式把 `TMPDIR` 指到工作盘。
- **`.dylddata` 是 0 字节** 就是透明压缩，跑 `decmpfs_fix.py` 即可 ——
  这也是这个仓库存在的直接原因。

---

## 说明

本项目只使用 Apple 公开发布的固件与开源工具，用于固件格式研究与互操作性分析。
涉及的格式知识（APFS、decmpfs、dyld shared cache）在 Apple 平台逆向社区中有公开讨论。

LZBitmap 的实现参考了 [blacktop/lzfse-cgo](https://github.com/blacktop/lzfse-cgo)，
整理为独立可复用的 C 库。

## License

MIT
