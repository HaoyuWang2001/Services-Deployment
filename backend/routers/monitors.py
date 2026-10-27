"""监控 API：命名监控项 CRUD + WebSocket 周期采集（watch 语义）。"""
from __future__ import annotations

import asyncio
import json
import logging
import time
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query, WebSocket, WebSocketDisconnect
from pydantic import BaseModel

from ..config import ConfigStore
from ..deps import get_monitors, get_pool, get_store
from ..monitors import MonitorStore
from ..ssh import SSHPool

log = logging.getLogger("sd.monitor")

router = APIRouter(prefix="/api/monitors", tags=["monitors"])

MAX_STDOUT = 200_000
MAX_STDERR = 10_000


# ---------------------------------------------------------------- CRUD ----
class MonitorCreateRequest(BaseModel):
    name: str
    cmd: str
    interval: int = 2


class MonitorUpdateRequest(BaseModel):
    name: Optional[str] = None
    cmd: Optional[str] = None
    interval: Optional[int] = None


@router.get("")
async def list_monitors(store: MonitorStore = Depends(get_monitors)):
    return {"monitors": [m.model_dump() for m in store.list()]}


@router.post("", status_code=201)
async def create_monitor(req: MonitorCreateRequest, store: MonitorStore = Depends(get_monitors)):
    try:
        m = store.create(req.name, req.cmd, req.interval)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e)) from e
    return m.model_dump()


@router.put("/{monitor_id}")
async def update_monitor(monitor_id: str, req: MonitorUpdateRequest,
                         store: MonitorStore = Depends(get_monitors)):
    try:
        m = store.update(monitor_id, req.name, req.cmd, req.interval)
    except KeyError as e:
        raise HTTPException(status_code=404, detail=str(e)) from e
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e)) from e
    return m.model_dump()


@router.delete("/{monitor_id}", status_code=204)
async def delete_monitor(monitor_id: str, store: MonitorStore = Depends(get_monitors)):
    if not store.delete(monitor_id):
        raise HTTPException(status_code=404, detail=f"监控项不存在: {monitor_id}")


# ---------------------------------------------------------------- WS ----
def build_monitor_command(cmd: str) -> str:
    """`sudo ` 前缀自动改写为 `sudo -n `，避免节点未配免密时挂死通道。"""
    stripped = cmd.lstrip()
    if stripped.startswith("sudo ") or stripped.rstrip() == "sudo":
        lead = cmd[: len(cmd) - len(stripped)]
        return f"{lead}sudo -n {stripped[5:].rstrip()}" if stripped[5:] else f"{lead}sudo -n"
    return cmd


def _trim(text: str, limit: int) -> str:
    if len(text) <= limit:
        return text
    return text[:limit] + f"\n...[输出过长，已截断，原始 {len(text)} 字符]"


@router.websocket("/ws/monitor")
async def ws_monitor(ws: WebSocket, nodes: str = Query(...),
                     interval: int = Query(default=2, ge=1, le=60),
                     cmd: str = Query(...),
                     store: ConfigStore = Depends(get_store),
                     pool: SSHPool = Depends(get_pool)):
    await ws.accept()
    node_names = [x.strip() for x in nodes.split(",") if x.strip()]
    unknown = [n for n in node_names if store.cluster.node(n) is None]
    if not cmd.strip() or not node_names or unknown:
        await ws.send_text(json.dumps(
            {"type": "error", "message": f"参数无效: 节点 {unknown or '空'} 或命令为空"},
            ensure_ascii=False))
        await ws.close()
        return

    real_cmd = build_monitor_command(cmd)
    run_timeout = min(max(interval, 5), 30)
    queue: asyncio.Queue = asyncio.Queue()

    async def _loop(node_name: str) -> None:
        async def put(obj: dict) -> None:
            await queue.put(json.dumps(obj, ensure_ascii=False))

        try:
            node = store.node(node_name)
        except KeyError as e:
            await put({"type": "error", "node": node_name, "message": str(e)})
            return
        await put({"type": "meta", "node": node_name, "cmd": real_cmd, "interval": interval})
        while True:
            started = time.monotonic()
            try:
                res = await pool.run(node, real_cmd, timeout=run_timeout)
                await put({"type": "output", "node": node_name,
                           "stdout": _trim(res.stdout, MAX_STDOUT),
                           "stderr": _trim(res.stderr, MAX_STDERR),
                           "exit_code": res.exit_code, "ts": time.time()})
            except asyncio.CancelledError:
                raise
            except Exception as e:  # noqa: BLE001  SSHError 等，报错后下一轮继续
                await put({"type": "error", "node": node_name,
                           "message": str(e), "ts": time.time()})
            elapsed = time.monotonic() - started
            await asyncio.sleep(max(0.2, interval - elapsed))

    tasks = [asyncio.create_task(_loop(n)) for n in node_names]

    async def _recv_watch() -> None:
        try:
            while True:
                await ws.receive_text()
        except WebSocketDisconnect:
            pass

    recv_task = asyncio.create_task(_recv_watch())
    try:
        while True:
            try:
                frame = await asyncio.wait_for(queue.get(), timeout=1.0)
                await ws.send_text(frame)
            except asyncio.TimeoutError:
                if recv_task.done():
                    break
                continue
    except Exception as e:  # noqa: BLE001
        log.debug("监控 WS 结束: %s", e)
    finally:
        recv_task.cancel()
        for t in tasks:
            t.cancel()
        try:
            await ws.close()
        except Exception:  # noqa: BLE001
            pass
