#!/usr/bin/env bash
# 启动管理端 Backend（Linux / macOS）
set -e
cd "$(dirname "$0")/.."
PORT="${PORT:-8310}"
echo "Services-Deployment backend -> http://0.0.0.0:${PORT} (docs: /docs)"
exec python3 -m uvicorn backend.main:app --host 0.0.0.0 --port "${PORT}"
