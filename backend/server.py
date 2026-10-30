#!/usr/bin/env python3
"""Services-Deployment 管理端启动入口。

用法：
    python backend/server.py --host 127.0.0.1 --port 8310
    python -m backend.server --port 8310
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

# 以脚本方式运行时 sys.path[0] 是 backend/ 而非仓库根，需引导以支持包内导入
REPO_ROOT = Path(__file__).resolve().parent.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

import uvicorn  # noqa: E402

from backend.main import app  # noqa: E402


def main() -> None:
    parser = argparse.ArgumentParser(description="Services-Deployment 管理端（集群服务部署管理）")
    parser.add_argument("--host", default="127.0.0.1",
                        help="监听地址（默认 127.0.0.1；局域网访问请用 0.0.0.0）")
    parser.add_argument("--port", type=int, default=8310, help="监听端口（默认 8310）")
    args = parser.parse_args()
    # timeout_graceful_shutdown：开着日志/监控 WS 时（尤其 Windows）优雅关闭会挂住，5 秒强制退出
    uvicorn.run(app, host=args.host, port=args.port, log_level="info",
                timeout_graceful_shutdown=5)


if __name__ == "__main__":
    main()
