#!/bin/bash
# 批量解包多个 iOS 固件的 dyld shared cache。
#
# 面向无人值守的长跑场景，内置四种保护：
#   - 断点续跑：已解出的组合自动跳过
#   - 失败重试：每个组合最多尝试 2 次
#   - 卡死保护：单次提取超时即放弃（timeout）
#   - 磁盘保护：剩余空间低于阈值时清理临时目录
#
# 用法
#   ./batch_unpack.sh <组合列表文件> [输出目录]
#
# 列表文件格式（每行一条，# 开头为注释）
#   iPhone14,8 23G90
#   iPhone13,1 22E240
#
# 示例
#   ./batch_unpack.sh examples/devices.txt ./work
#
# 环境变量
#   MIN_FREE_KB   磁盘保护阈值（KB），默认 7000000（约 7 GB）
set -u

if [ $# -lt 1 ]; then
  echo "用法: $0 <组合列表文件> [输出目录]" >&2
  echo "示例: $0 examples/devices.txt ./work" >&2
  exit 2
fi

LIST="$1"
WORK="${2:-$PWD/work}"
MIN_FREE_KB="${MIN_FREE_KB:-7000000}"
HERE="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$WORK" || exit 1

TOTAL=$(grep -cvE '^\s*(#|$)' "$LIST")
N=0; OK=0; SKIP=0; BAD=0; START=$(date +%s)

echo "===== 批量解包开始 $(date -Is)  共 $TOTAL 个组合 ====="

while read -r DEV BUILD _; do
  case "$DEV" in ''|'#'*) continue;; esac
  [ -n "${BUILD:-}" ] || continue
  N=$((N+1))
  LABEL="$(echo "$DEV" | tr ',' '_')__${BUILD}"
  D="$WORK/dsc_$LABEL/System/Library/Caches/com.apple.dyld"

  if [ -d "$D" ] && [ "$(ls "$D" 2>/dev/null | wc -l)" -gt 10 ]; then
    SKIP=$((SKIP+1)); continue
  fi

  printf '\n[%d/%d] %-14s %-10s %s\n' "$N" "$TOTAL" "$DEV" "$BUILD" "$(date +%H:%M:%S)"

  # 磁盘保护
  AVAIL=$(df --output=avail -k "$WORK" 2>/dev/null | tail -1 | tr -d ' ')
  if [ "${AVAIL:-0}" -lt "$MIN_FREE_KB" ]; then
    echo "  ! 磁盘仅 $((AVAIL/1024/1024)) GB，清理临时文件"
    rm -rf "$WORK"/dsc_*/System/Library/Caches/com.apple.dyld/../.. 2>/dev/null
    rm -rf "$WORK/tmp" /tmp/ipsw_extract_remote_dyld* 2>/dev/null
  fi

  SUCCESS=0
  for attempt in 1 2; do
    [ "$attempt" -gt 1 ] && echo "  · 第 $attempt 次尝试"
    bash "$HERE/run_ipsw_unpack.sh" "$DEV" "$BUILD" "$WORK" >/dev/null 2>&1
    if [ -d "$D" ] && [ "$(ls "$D" 2>/dev/null | wc -l)" -gt 10 ]; then
      SUCCESS=1; break
    fi
    rm -rf "$WORK/tmp" 2>/dev/null; sleep 5
  done

  if [ "$SUCCESS" -eq 1 ]; then
    OK=$((OK+1))
    printf '  完成 %d | 跳过 %d | 失败 %d\n' "$((OK+SKIP))" "$SKIP" "$BAD"
  else
    BAD=$((BAD+1)); echo "  ✗ 失败"
  fi

  rm -rf "$WORK/tmp" /tmp/ipsw_extract_remote_dyld* 2>/dev/null

  if [ $((N % 20)) -eq 0 ]; then
    echo "  ===== 进度 $N/$TOTAL（已用 $(( ($(date +%s)-START)/60 )) 分钟）====="
  fi
done < "$LIST"

echo
echo "===== 结束 $(date -Is)  耗时 $(( ($(date +%s)-START)/60 )) 分钟 ====="
echo "  总计 $TOTAL | 成功 $OK | 跳过 $SKIP | 失败 $BAD"
