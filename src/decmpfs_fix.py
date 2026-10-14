#!/usr/bin/env python3
"""解开 7-Zip 无法处理的 decmpfs 透明压缩文件。

背景
    部分文件在 APFS 上以 decmpfs 压缩属性存储（属性写在 <文件>:com.apple.decmpfs，
    压缩数据在 <文件>:com.apple.ResourceFork）。7-Zip 能列出这些附属文件，
    但解主文件时只会留下 **0 字节**。

    其中 CMP_RSRC_LZBITMAP（decmpfs type 14）没有公开规范，7-Zip 报
    "Unsupported Method"。本脚本调用 zbm（见 src/lzbitmap/）从 ResourceFork
    还原出原始内容。

用法
    decmpfs_fix.py <解包目录>

环境变量
    ZBM_BIN     zbm 可执行文件路径（默认在 PATH 中查找 zbm）

退出码
    0  全部成功（或无需处理）
    1  存在未能解出的文件
    2  参数错误
"""
import glob
import os
import shutil
import subprocess
import sys

TARGETS = ('.dylddata', '.dyldreadonly', '.symbols')


def find_zbm():
    return os.environ.get('ZBM_BIN') or shutil.which('zbm')


def fix(zbm, path):
    decmpfs = path + ':com.apple.decmpfs'
    rsrc = path + ':com.apple.ResourceFork'
    if not (os.path.exists(decmpfs) and os.path.exists(rsrc)):
        return False, '缺少 decmpfs / ResourceFork 附属文件'
    r = subprocess.run([zbm, decmpfs, rsrc, path], capture_output=True, text=True)
    if r.returncode == 0 and os.path.getsize(path) > 0:
        tail = r.stderr.strip().splitlines()
        return True, tail[-1] if tail else ''
    return False, (r.stderr.strip().replace('\n', ' | ')[:180] or 'zbm 返回非零')


def main():
    if len(sys.argv) < 2:
        print(__doc__.strip().splitlines()[-3].strip(), file=sys.stderr)
        return 2

    zbm = find_zbm()
    if not zbm:
        print('✗ 未找到 zbm，请先编译 src/lzbitmap/（make）或设置 ZBM_BIN', file=sys.stderr)
        return 2

    d = sys.argv[1]
    if not os.path.isdir(d):
        print(f'✗ 目录不存在: {d}', file=sys.stderr)
        return 2

    tried = fixed = 0
    for f in sorted(glob.glob(os.path.join(d, '*'))):
        base = os.path.basename(f)
        # 跳过 decmpfs/ResourceFork 等附属文件；只看已知会被压缩的几类
        if ':com.apple.' in base or not any(t in base for t in TARGETS):
            continue
        if os.path.getsize(f) > 0:
            continue
        tried += 1
        ok, msg = fix(zbm, f)
        if ok:
            fixed += 1
            print('  ✓ %-44s %d 字节' % (base, os.path.getsize(f)))
        else:
            print('  ✗ %-44s %s' % (base, msg))

    print('  decmpfs 修复: 尝试 %d, 成功 %d' % (tried, fixed))
    return 0 if tried == fixed else 1


if __name__ == '__main__':
    sys.exit(main())
