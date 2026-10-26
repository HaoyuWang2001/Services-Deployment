#!/usr/bin/env bash
# 自定义停止脚本模板（可选；若不提供 stop.sh，管理端默认按 PID kill，超时后强杀）
set -euo pipefail

echo "[$(date '+%F %T')] stopping on $(hostname)"
if [ -f run/service.pid ]; then
  kill "$(cat run/service.pid)" 2>/dev/null || true
fi
