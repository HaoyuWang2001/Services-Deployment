"""FastAPI 应用装配与入口。"""
from __future__ import annotations

import logging
import os
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, HTMLResponse
from fastapi.staticfiles import StaticFiles

from .config import DATA_DIR, ConfigStore
from .context import ctx
from .instances import InstanceRegistry
from .routers import cluster, instances, logs, services, tasks
from .ssh import SSHPool
from .tasks import TaskManager

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
)

STATIC_DIR = Path(__file__).resolve().parent / "static"

PLACEHOLDER = """<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><title>Services-Deployment</title>
<style>body{font-family:system-ui,sans-serif;background:#f5f7fa;display:flex;
align-items:center;justify-content:center;height:100vh;margin:0}
.card{background:#fff;border-radius:8px;padding:40px 56px;box-shadow:0 2px 12px rgba(0,0,0,.08);
max-width:520px;line-height:1.8}code{background:#eef1f5;padding:2px 6px;border-radius:4px}</style>
</head><body><div class="card">
<h2 style="margin-top:0">API 已就绪，WebUI 尚未构建</h2>
<p>后端 API 正常运行，可在 <a href="/docs">/docs</a> 查看 OpenAPI 文档。</p>
<p>构建 WebUI：</p>
<p><code>cd web &amp;&amp; npm install &amp;&amp; npm run build</code></p>
<p>构建产物会输出到 <code>backend/static/</code>，刷新本页即可。</p>
</div></body></html>"""


@asynccontextmanager
async def lifespan(app: FastAPI):
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    store = ConfigStore()
    pool = SSHPool()
    registry = InstanceRegistry(DATA_DIR)
    task_manager = TaskManager(pool, store, registry, DATA_DIR)
    app.state.store = store
    app.state.pool = pool
    app.state.instances = registry
    app.state.task_manager = task_manager
    ctx.store = store
    ctx.pool = pool
    ctx.instances = registry
    ctx.task_manager = task_manager
    yield
    await pool.close_all()


app = FastAPI(
    title="Services-Deployment",
    description="集群服务部署管理：SSH 远程启停、日志归档与实时查看",
    version="0.1.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(cluster.router)
app.include_router(services.router)
app.include_router(tasks.router)
app.include_router(instances.router)
app.include_router(logs.router)


@app.get("/api/health")
async def health():
    return {"ok": True}


@app.get("/", include_in_schema=False)
async def index():
    if (STATIC_DIR / "index.html").is_file():
        return FileResponse(STATIC_DIR / "index.html")
    return HTMLResponse(PLACEHOLDER)


if (STATIC_DIR / "index.html").is_file():
    app.mount("/", StaticFiles(directory=STATIC_DIR, html=True), name="static")


if __name__ == "__main__":
    import uvicorn

    port = int(os.environ.get("PORT", "8310"))
    uvicorn.run("backend.main:app", host="0.0.0.0", port=port, log_level="info")
