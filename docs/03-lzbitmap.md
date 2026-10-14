# 03 · APFS 透明压缩与 LZBitmap（decmpfs type 14）

> 这是本仓库的核心组件。`libzbitmap.c` 是 CMP_RSRC_LZBITMAP 的一个独立实现 ——
> 该算法**没有公开规范**，且现有开源工具（含 7-Zip）都不支持。

## decmpfs 是什么

APFS 支持**按文件透明压缩**：文件内容压缩后存放，读取时由内核解压，应用无感知。
压缩元数据放在扩展属性里：

```
<文件>                      主文件（通常长度为 0，或存少量内联数据）
<文件>:com.apple.decmpfs     压缩头：magic + 压缩类型 + 原始长度
<文件>:com.apple.ResourceFork  压缩后的数据块
```

`com.apple.decmpfs` 的头部布局（小端）：

| 偏移 | 长度 | 含义 |
| ---: | ---: | :--- |
| 0x00 | 4 | 魔数 `cmpf` |
| 0x04 | 4 | 压缩类型 |
| 0x08 | 8 | 原始（解压后）长度 |

压缩类型中，**type 14 = `CMP_RSRC_LZBITMAP`** 就是本文的主角。

## ResourceFork 的存储格式

压缩数据不是一整块，而是切成固定 **64 KB** 的原始块分别压缩。ResourceFork 文件结构：

```
┌─────────────────────────────┐
│ 偏移表：uint32 × N（小端）    │  第 i 项 = 第 i 个压缩块相对本文件起点的偏移
├─────────────────────────────┤
│ 压缩块 0                     │
│ 压缩块 1                     │
│ ⋮                            │
└─────────────────────────────┘
```

第 i 块的压缩长度 = `offset[i+1] - offset[i]`，最后一块到文件尾。

所以解压流程是：

```
读 decmpfs 头 → 取原始长度
读 ResourceFork 偏移表 → 得到块数 N 与各块边界
for i in 0..N-1:
    zbm_decompress(dest + i*64KB, 剩余空间, fork + offset[i], 该块长度, &out_len)
拼接 → 与 decmpfs 头的原始长度核对
```

## ★ 实现时最容易踩的坑

**`zbm_decompress` 返回 0 表示成功，负值才是错误码。**

```c
int zbm_decompress(void *dest, size_t dest_size,
                   const void *src, size_t src_size, size_t *out_len);
```

这与多数 C 库"返回实际写入字节数、0 表示失败"的习惯相反。写成 `if (r > 0)` 会导致
**每一块都被判为失败**，而错误信息又看不出所以然（因为返回值本身是"成功"的 0）。

另一个坑：**输出长度必须通过 `out_len` 出参取**。有的语言绑定会丢弃这个出参
（例如部分 Go 封装只返回 error），那样就无法知道解出了多少字节 —— 这也是本仓库
直接用 C 实现、不经语言封装的原因。

## 编译与使用

```bash
cd src/lzbitmap
make                 # 产出 zbm

# 解一个文件
./zbm <文件>:com.apple.decmpfs <文件>:com.apple.ResourceFork <输出文件>
```

对整目录批量处理：

```bash
python3 src/decmpfs_fix.py /path/to/System/Library/Caches/com.apple.dyld
```

脚本会扫描 `.dylddata` / `.dyldreadonly` / `.symbols`，挑出**大小为 0 且带 decmpfs 属性**的
文件逐个还原。

## 实测影响

在部分机型上，dyld 缓存的数据段（`.dylddata`，字符串池与常量数组所在）正是以
LZBitmap 存储的。不解这一步，这些文件恒为 0 字节 —— 后续任何解析都会"看起来文件在、
内容却是空的"，且 7-Zip 只给一行 `ERROR: Unsupported Method`，很难定位。

| 项 | 值 |
| :--- | :--- |
| 典型块大小 | 64 KB（原始） |
| 单文件解压耗时 | 秒级 |
| 影响的文件 | 部分机型的 `.dylddata` / `.dyldreadonly` / `.symbols` |

## 代码来源与致谢

`libzbitmap.c` 的算法实现参考了 [blacktop/lzfse-cgo](https://github.com/blacktop/lzfse-cgo)
中的 LZBitmap 部分（Apple 的 LZFSE 压缩族衍生算法）。本仓库将其整理为
**零依赖的纯 C 库 + 命令行工具**，并补充了上文两个坑的说明与正确处理。

Apple 未公开 LZBitmap 的格式规范，实现依据为对压缩数据的逆向分析与既有开源实现的交叉验证。
