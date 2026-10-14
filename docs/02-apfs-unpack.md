# 02 · APFS 解包（无 apfs-fuse 环境）

## 问题

`ipsw` 解出 dmg 后，需要把它当文件系统读取。官方路径是调用 `apfs-fuse`（Linux/macOS 上的
APFS 用户态实现）。但 `apfs-fuse` 经常装不上：

- 需要 FUSE 内核模块（容器里通常没有）
- 编译依赖旧版 `libcrypto`，在新发行版上失败
- 挂载整个卷需要 root

## 思路：把"挂载器"换掉

`ipsw` 并不硬编码 `apfs-fuse`，它读环境变量 **`IPSW_APFS_FUSE_PATH`**：

```
IPSW_APFS_FUSE_PATH=<你的脚本>  ipsw extract --dyld --remote <URL> -o out/
```

调用约定是 `<脚本> <dmg 路径> <挂载点>`。既然只需要 dyld 缓存那几个文件，
**完全不必真的挂载** —— 用 7-Zip 直接解出来即可（7-Zip 21.02+ 原生支持 APFS）。

这就是 `src/fake-apfs-fuse` 做的事：接收 ipsw 的调用，用 7-Zip 解包到 `DSC_DEST`，然后删掉 dmg 释放空间。

## 收益：只解需要的部分

全量解包 dyld 缓存目录约 **3.8 GB**（所有子缓存）。实际只需要：

| 文件 | 作用 | 大小 |
| :--- | :--- | ---: |
| `dyld_shared_cache_arm64e` | 主缓存（符号表、大部分镜像） | ~1.5 GB |
| `dyld_shared_cache_arm64e.atlas` | 索引 | 小 |
| `*.dylddata` | 数据段（字符串池、常量数组等） | 数百 MB |
| `dyld_shared_cache_arm64e.<N>` | 大框架被拆出的独立子缓存 | 每个数百 MB |

关键是**最后一行**：dyld 会把体积大的框架单独放到数字子缓存里。用 7-Zip 逐个流式扫描、
命中特征字符串的才解出来，就能把解包量压到 **约 520 MB**，同时省掉大量 I/O。

```bash
for f in $(7zz l "$DMG" | awk '/dyld_shared_cache_arm64e\.[0-9]+$/ {print $NF}'); do
  if 7zz x -so "$DMG" "$f" | grep -qaE 'WebCore|JavaScriptCore'; then
    7zz x "$DMG" -o"$DEST" "$f" -y; break
  fi
done
```

## 坑：密封卷读不到根目录

如果你尝试用 Python 的 APFS 库（如 `pyfsapfs`）替代，会遇到：

```
container 打开正常（偏移 0x20 处有 NXSB 魔数，能看到卷）
volume.get_root_directory()  →  None
volume.get_size()            →  OSError: failed to retrieve size
```

原因是现代 iOS 的系统卷是**密封卷（sealed volume）**，文件系统树由签名的哈希树保护，
未解锁时库拿不到目录项。

**7-Zip 走的是另一条路**：它按 B-tree 直接遍历记录，不依赖卷的完整挂载语义，
所以能绕过这个问题。这也是本方案选择 7-Zip 而非各种 APFS 库的原因。

## 坑：透明压缩

解出来的部分文件是 **0 字节** —— 这不是解包失败，而是文件以 APFS 透明压缩存储
（`decmpfs` 属性），7-Zip 报 `ERROR: Unsupported Method` 后留空。

处理方法见 [03 · LZBitmap](03-lzbitmap.md)。

## 用法

```bash
export DSC_DEST=/path/to/out
export SEVEN_ZIP=7zz
export IPSW_APFS_FUSE_PATH=$PWD/src/fake-apfs-fuse
ipsw extract --dyld --dyld-arch arm64e --remote <IPSW_URL> -o ./tmp
```

或用封装好的 `src/run_ipsw_unpack.sh <机型> <build> <输出目录>`。

| 环境变量 | 说明 |
| :--- | :--- |
| `DSC_DEST` | 必填，解包目标目录 |
| `SEVEN_ZIP` | 7-Zip 可执行文件（默认 `7zz`） |
| `DSC_FULL=1` | 解出全部子缓存（排查问题时用） |
| `KEEP_DMG=1` | 保留源 dmg（默认解完即删） |
| `APFS_FUSE_LOG` | 日志路径 |
