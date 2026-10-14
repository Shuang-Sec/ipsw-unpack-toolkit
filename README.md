# ipsw-unpack-toolkit

从 Apple **公开** IPSW 固件中解包 dyld shared cache 的工具集。
全程离线可用，**不需要真机、不需要越狱、不需要开发者账号**。

重点解决两件实际卡人的事：

1. **没有 apfs-fuse 也能解包** —— 用 `IPSW_APFS_FUSE_PATH` 注入伪挂载器，让 7-Zip 代替真挂载，
   并把解包量从 3.8 GB 压到约 520 MB
2. **7-Zip 解不出的透明压缩** —— APFS `decmpfs` 的 **LZBitmap（type 14）没有公开规范**，
   上游工具一律报 `Unsupported Method` 并留下 0 字节文件；本仓库提供零依赖的 C 实现

---

## 快速开始

```bash
git clone https://github.com/Shuang-Sec/ipsw-unpack-toolkit.git
cd ipsw-unpack-toolkit

# 1) 编译 LZBitmap 解压工具（零依赖，只需 C 编译器）
make -C src/lzbitmap
export PATH="$PWD/src/lzbitmap:$PATH"

# 2) 解包一个版本（以 iPhone 14 Pro / iOS 26.6.2 为例）
./src/run_ipsw_unpack.sh iPhone15,2 23G90 ./work
```

跑完会得到：

```
work/dsc_iPhone15_2__23G90/System/Library/Caches/com.apple.dyld/
├── dyld_shared_cache_arm64e            主缓存
├── dyld_shared_cache_arm64e.atlas      索引
├── dyld_shared_cache_arm64e.01.dylddata  数据段
├── dyld_shared_cache_arm64e.<N>        大框架的独立子缓存
└── ⋮
```

批量跑：

```bash
./src/batch_unpack.sh examples/devices.txt ./work
```

---

## 仓库结构

```
├── docs/
│   ├── 01-ipsw-fetch.md        IPSW 获取与 AEA1/WKMS 解密
│   ├── 02-apfs-unpack.md       无 apfs-fuse 环境下的解包方案
│   ├── 03-lzbitmap.md          ★ decmpfs type 14 格式与实现（核心）
│   └── 04-batch-pipeline.md    批量长跑的工程实践
├── src/
│   ├── lzbitmap/               ★ LZBitmap 解压库与 CLI（纯 C，零依赖）
│   │   ├── libzbitmap.c/.h
│   │   ├── zbm.c
│   │   └── Makefile
│   ├── decmpfs_fix.py          批量扫描并修复 0 字节的透明压缩文件
│   ├── fake-apfs-fuse          伪挂载器（供 ipsw 调用）
│   ├── run_ipsw_unpack.sh      单版本：查地址 → 提取 → 解包 → 修复
│   └── batch_unpack.sh         批量：断点续跑 / 重试 / 超时 / 磁盘保护
├── examples/devices.txt        组合列表示例
└── tools/PUT_TOOLS_HERE.md     外部依赖获取说明
```

---

## 三个技术要点

### 1. LZBitmap 独立实现

APFS 的透明压缩属性 `decmpfs` 有一系列压缩类型，其中 **type 14 = `CMP_RSRC_LZBITMAP`**
没有公开规范。7-Zip 会报 `Unsupported Method` 并把文件留成 0 字节 —— 这很隐蔽：
文件在、名字对，内容却是空的，后续解析只会得到莫名其妙的结果。

`src/lzbitmap/` 是一个零依赖的纯 C 实现。**实现时最容易踩的坑**：

```c
// 返回 0 表示成功，负值才是错误码 —— 与多数 C 库的习惯相反
int zbm_decompress(void *dest, size_t dest_size,
                   const void *src, size_t src_size, size_t *out_len);
```

写成 `if (ret > 0)` 会让每一块都被判为失败。细节见 [docs/03-lzbitmap.md](docs/03-lzbitmap.md)。

### 2. 伪挂载器

`ipsw` 通过 `IPSW_APFS_FUSE_PATH` 支持替换挂载器。本仓库的 `src/fake-apfs-fuse`
不真正挂载 APFS，而是用 7-Zip 直接解出目标目录：

- 不需要 root、不需要 FUSE 内核模块
- 只解 dyld 目录，跳过整卷：**3.8 GB → 约 520 MB**
- 解完立即删除源 dmg，磁盘峰值约 5 GB

细节（含密封卷的坑）见 [docs/02-apfs-unpack.md](docs/02-apfs-unpack.md)。

### 3. 批量长跑的鲁棒性

跑几百个组合时，失败来自网络抖动、上游工具卡死、磁盘写满。
`src/batch_unpack.sh` 内置四重保护：

| 机制 | 说明 |
| :--- | :--- |
| 断点续跑 | 用**产物本身**判断，不用状态文件（避免"日志说完成、目录却是空的"） |
| 失败重试 | 每个组合最多 2 次，中间清理临时目录 |
| 卡死保护 | `timeout` 兜底，应对 ipsw 偶发无响应 |
| 磁盘保护 | 剩余空间低于阈值时自动清理 |

细节见 [docs/04-batch-pipeline.md](docs/04-batch-pipeline.md)。

---

## 依赖

| 依赖 | 版本 | 用途 | 获取 |
| :--- | :--- | :--- | :--- |
| `ipsw` | v3.1.x 实测 | 固件拉流、解密、调度挂载器 | [blacktop/ipsw](https://github.com/blacktop/ipsw) |
| 7-Zip | **21.02+** | APFS 解包（旧版不支持 APFS） | [7-zip.org](https://www.7-zip.org/) |
| `python3` | 3.8+ | `decmpfs_fix.py` | 系统自带 |
| `curl` / `jq` | — | 查询固件下载地址 | 系统自带 |
| C 编译器 | — | 编译 `zbm` | `gcc` / `clang` |

---

## 环境变量

| 变量 | 默认 | 说明 |
| :--- | :--- | :--- |
| `DSC_DEST` | — | **必填**，解包目标目录（由 `fake-apfs-fuse` 读取） |
| `IPSW_BIN` | `ipsw` | ipsw 可执行文件路径 |
| `SEVEN_ZIP` | `7zz` | 7-Zip 可执行文件路径 |
| `ZBM_BIN` | `zbm` | LZBitmap 解压工具路径 |
| `TIMEOUT_SEC` | `900` | 单次提取超时（秒） |
| `DSC_FULL` | `0` | 设为 1 则解出全部子缓存（排查用） |
| `KEEP_DMG` | `0` | 设为 1 则保留源 dmg |
| `MIN_FREE_KB` | `7000000` | 批量模式的磁盘保护阈值 |

---

## 已知问题与提示

- **`ipsw` 报 `failed to find dyld_shared_cache(s) in DMG` 并保留 backing image** ——
  使用替代挂载器时会出现，实际内容已解出，可忽略。
- **不要把 `TMPDIR` 指向 `tmpfs`** —— 固件数 GB，会把内存写满并报 `EDQUOT`。
  脚本已显式将 `TMPDIR` 指向工作盘。
- **部分机型的 `.dylddata` 恒为 0 字节** —— 就是透明压缩，跑 `decmpfs_fix.py` 即可。
  这也是本仓库存在的直接原因。

---

## 说明

本项目仅使用 Apple 公开发布的固件与开源工具，用于固件格式研究与互操作性分析。
相关格式知识（APFS、decmpfs、dyld shared cache）在 Apple 平台逆向社区中有公开讨论。

LZBitmap 的算法实现参考了 [blacktop/lzfse-cgo](https://github.com/blacktop/lzfse-cgo)，
整理为独立可复用的 C 库。详见 [docs/03-lzbitmap.md](docs/03-lzbitmap.md)。

## License

MIT
