"""日志 API：归档列表、快照读取、WebSocket 实时流。"""
from __future__ import annotations

import asyncio
import json
import logging
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query, WebSocket, WebSocketDisconnect
from fastapi.responses import PlainTextResponse

from .. import executor
from ..config import TOKEN_RE, ConfigStore
from ..deps import get_instances, get_pool, get_store
from ..instances import InstanceRegistry
from ..ssh import SSHPool, SSHError

log = logging.getLogger("sd.logs")

router = APIRouter(prefix="/api/logs", tags=["logs"])


def _check_token(value: str, what: str) -> str:
    if not TOKEN_RE.match(value):
        raise HTTPException(status_code=400, detail=f"{what} 非法: {value!r}")
    return value


def _resolve_service(store: ConfigStore, service: str):
    try:
        return store.service(service)
    except KeyError as e:
        raise HTTPException(status_code=404, detail=str(e)) from e


def _resolve_node(store: ConfigStore, node: str):
    try:
        return store.node(node)
    except KeyError as e:
        raise HTTPException(status_code=404, detail=str(e)) from e


async def _resolve_run_id(pool: SSHPool, store: ConfigStore, node, svc,
                          run_id: Optional[str]) -> str:
    if run_id in (None, "", "latest"):
        rid = await executor.latest_run_id(pool, node, svc)
        if not rid:
            raise HTTPException(status_code=404, detail=f"{node.name} 上暂无日志归档")
        return rid
    return _check_token(run_id, "run_id")


@router.get("/services/{service}/nodes/{node}/archives")
async def list_archives(service: str, node: str,
                        store: ConfigStore = Depends(get_store),
                        pool: SSHPool = Depends(get_pool),
                        registry: InstanceRegistry = Depends(get_instances)):
    svc = _resolve_service(store, service)
    n = _resolve_node(store, node)
    try:
        archives = await executor.list_archives(pool, n, svc)
    except (executor.ExecError, SSHError) as e:
        raise HTTPException(status_code=502, detail=str(e)) from e
    current = registry.get(service, node)
    return {
        "archives": archives,
        "current_run_id": current.run_id if current else None,
    }


@router.get("/services/{service}/nodes/{node}/content")
async def read_log(service: str, node: str,
                   run_id: Optional[str] = Query(default="latest"),
                   file: Optional[str] = Query(default=None),
                   tail: Optional[int] = Query(default=200, ge=1, le=100000),
                   download: bool = Query(default=False),
                   store: ConfigStore = Depends(get_store),
                   pool: SSHPool = Depends(get_pool)):
    svc = _resolve_service(store, service)
    n = _resolve_node(store, node)
    log_file = _check_token(file or svc.start.log, "file")
    rid = await _resolve_run_id(pool, store, n, svc, run_id)
    try:
        content = await executor.read_log(pool, n, svc, rid, log_file,
                                          None if download else tail)
    except (executor.ExecError, SSHError) as e:
        raise HTTPException(status_code=502, detail=str(e)) from e
    headers = {}
    if download:
        headers["Content-Disposition"] = (
            f'attachment; filename="{service}-{node}-{rid}-{log_file}"')
    return PlainTextResponse(content, media_type="text/plain; charset=utf-8", headers=headers)


# ------------------------------------------------------------------ WS ----
async def _send_json(ws: WebSocket, obj: dict) -> None:
    await ws.send_text(json.dumps(obj, ensure_ascii=False))


async def _stream_node(store: ConfigStore, pool: SSHPool, queue: asyncio.Queue,
                       service_name: str, node_name: str,
                       run_id: str, log_file: str, tail: int) -> None:
    async def put(obj: dict) -> None:
        await queue.put(json.dumps(obj, ensure_ascii=False))

    try:
        svc = store.service(service_name)
        node = store.node(node_name)
    except KeyError as e:
        await put({"type": "error", "node": node_name, "message": str(e)})
        return
    try:
        rid = run_id
        if rid == "latest":
            rid = await executor.latest_run_id(pool, node, svc)
            if not rid:
                await put({"type": "error", "node": node_name,
                           "message": f"{node_name} 上暂无日志归档"})
                return
        await put({"type": "meta", "node": node_name, "run_id": rid,
                   "file": log_file, "message": "已连接日志流"})
        proc = await executor.open_log_stream(pool, node, svc, rid, log_file, tail)
        assert proc.stdout is not None
        async for line in proc.stdout:
            await put({"type": "line", "node": node_name, "data": line.rstrip("\n")})
        await put({"type": "ended", "node": node_name, "message": "日志流已结束(tail 退出)"})
    except (SSHError, executor.ExecError) as e:
        await put({"type": "error", "node": node_name, "message": str(e)})
    except asyncio.CancelledError:
        raise
    except Exception as e:  # noqa: BLE001
        await put({"type": "error", "node": node_name, "message": f"未知错误: {e}"})


@router.websocket("/ws/logs")
async def ws_logs(ws: WebSocket, service: str, nodes: str = Query(...),
                  run_id: str = Query(default="latest"),
                  file: Optional[str] = Query(default=None),
                  tail: int = Query(default=100, ge=1, le=10000),
                  store: ConfigStore = Depends(get_store),
                  pool: SSHPool = Depends(get_pool)):
    await ws.accept()
    node_names = [x.strip() for x in nodes.split(",") if x.strip()]
    unknown = [n for n in node_names if store.cluster.node(n) is None]
    if service not in store.services:
        await _send_json(ws, {"type": "error", "message": f"未知服务: {service}"})
        await ws.close()
        return
    if unknown or not node_names:
        await _send_json(ws, {"type": "error", "message": f"节点无效: {unknown or '空'}"})
        await ws.close()
        return
    log_file = file if file and TOKEN_RE.match(file) else store.service(service).start.log
    tail = max(1, min(tail, 10000))

    queue: asyncio.Queue = asyncio.Queue()
    streams = [
        asyncio.create_task(_stream_node(store, pool, queue, service, name,
                                         run_id, log_file, tail))
        for name in node_names
    ]

    async def _recv_watch() -> None:
        try:
            while True:
                await ws.receive_text()  # 忽略客户端消息，仅用于感知断连
        except WebSocketDisconnect:
            pass

    recv_task = asyncio.create_task(_recv_watch())
    try:
        while True:
            try:
                frame = await asyncio.wait_for(queue.get(), timeout=1.0)
                await ws.send_text(frame)
            except asyncio.TimeoutError:
                if recv_task.done() or all(s.done() for s in streams):
                    while not queue.empty():
                        await ws.send_text(queue.get_nowait())
                    break
                continue
            if recv_task.done():
                break
    except Exception as e:  # noqa: BLE001
        log.debug("WS 日志流结束: %s", e)
    finally:
        recv_task.cancel()
        for s in streams:
            s.cancel()
        try:
            await ws.close()
        except Exception:  # noqa: BLE001
            pass
