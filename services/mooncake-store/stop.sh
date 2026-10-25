#!/usr/bin/env bash
# Mooncake Store 自定义停止脚本示例（无此文件时管理端默认按 PID kill）
set -euo pipefail

echo "[$(date '+%F %T')] stopping mooncake-store on $(hostname)"
if [ -f run/mooncake-store.pid ]; then
  kill "$(cat run/mooncake-store.pid)" 2>/dev/null || true
fi
