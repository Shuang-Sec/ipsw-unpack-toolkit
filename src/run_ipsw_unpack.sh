#!/bin/bash
# 下载并解包**单个** iOS 固件的 dyld shared cache。
#
# 全程只依赖 Apple 公开的 IPSW 与开源工具，不需要真机、不需要越狱。
# 典型耗时 2~5 分钟（大部分是网络下载），磁盘峰值约 5 GB。
#
# 用法
#   ./run_ipsw_unpack.sh <机型标识> <build> [输出目录]
#
# 示例
#   ./run_ipsw_unpack.sh iPhone14,8 23G90 ./work
#   ./run_ipsw_unpack.sh iPhone12,1 22E240 /data/ipsw
#
# 依赖
#   ipsw   https://github.com/blacktop/ipsw   （v3.1.x 实测）
#   7zz    7-Zip 21.02 以上（带 APFS 支持）
#   curl / jq / python3
#
# 环境变量
#   IPSW_BIN       ipsw 可执行文件（默认 PATH 中的 ipsw）
#   SEVEN_ZIP      7-Zip 可执行文件（默认 7zz）
#   ZBM_BIN        zbm 可执行文件（默认 PATH 中的 zbm）
#   TIMEOUT_SEC    单次提取超时，默认 900 秒
set -u

if [ $# -lt 2 ]; then
  echo "用法: $0 <机型标识> <build> [输出目录]" >&2
  echo "示例: $0 iPhone15,2 23G90 ./work" >&2
  exit 2
fi

DEV="$1"; BUILD="$2"
WORK="${3:-$PWD/work}"

IPSW="${IPSW_BIN:-ipsw}"
ZBM="${ZBM_BIN:-zbm}"
LABEL="$(echo "$DEV" | tr ',' '_')__${BUILD}"
DSC_DIR="$WORK/dsc_$LABEL"
D="$DSC_DIR/System/Library/Caches/com.apple.dyld"
LOGD="$WORK/logs"

mkdir -p "$DSC_DIR" "$LOGD" "$WORK/tmp"

# 临时目录放在工作盘上，避免 tmpfs 被固件撑爆
export TMPDIR="$WORK/tmp"

# ---------- 断点续跑 ----------
if [ -d "$D" ] && [ "$(ls "$D" 2>/dev/null | wc -l)" -gt 10 ]; then
  echo "[$LABEL] 复用已解包缓存（$(ls "$D" | wc -l) 个文件）"
  exit 0
fi

# ---------- 查下载地址 ----------
URL="$(curl -s --max-time 60 "https://api.ipsw.me/v4/device/$DEV?type=ipsw" \
       | jq -r ".firmwares[] | select(.buildid==\"$BUILD\") | .url")"
if [ -z "$URL" ] || [ "$URL" = "null" ]; then
  echo "[$LABEL] ✗ 该机型/版本组合没有可用固件（ipsw.me 未收录）"
  exit 1
fi

echo "[$LABEL] $DEV / $BUILD"
echo "[$LABEL] 远程提取并解包中（只拉取所需分卷，不会下载整个固件）..."

# ipsw 会把固件拉流解密后交给"挂载器"；我们用伪挂载器跳过真正的 APFS 挂载
DSC_DEST="$DSC_DIR" SEVEN_ZIP="${SEVEN_ZIP:-7zz}" \
IPSW_APFS_FUSE_PATH="$(dirname "$0")/fake-apfs-fuse" \
  timeout "${TIMEOUT_SEC:-900}" "$IPSW" extract \
      --dyld --dyld-arch arm64e --remote "$URL" -o "$WORK/tmp/out_$LABEL" \
      >> "$LOGD/$LABEL.log" 2>&1
RC=$?

rm -rf "$WORK/tmp" /tmp/ipsw_extract_remote_dyld* 2>/dev/null

if [ ! -d "$D" ] || [ "$(ls "$D" 2>/dev/null | wc -l)" -le 10 ]; then
  echo "[$LABEL] ✗ 未解出 dyld cache（ipsw exit=$RC）"
  tail -5 "$LOGD/$LABEL.log" 2>/dev/null | sed 's/^/    /'
  exit 2
fi

echo "[$LABEL] ✓ 完成：$(ls "$D" | wc -l) 个文件，$(du -sh "$DSC_DIR" 2>/dev/null | cut -f1)"
echo "[$LABEL]   目录: $D"
