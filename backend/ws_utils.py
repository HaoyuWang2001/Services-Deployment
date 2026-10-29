"""WebSocket 泵：把异步任务产出的帧队列转发给客户端，并管理生命周期。

供日志流（routers/logs.py）与监控采集（routers/monitors.py）共用。
退出条件：客户端断开，或全部流任务结束（剩余帧排空后收尾）。
"""
from __future__ import annotations

import asyncio
import logging

from fastapi import WebSocket, WebSocketDisconnect

log = logging.getLogger("sd.ws")


async def run_ws_pump(ws: WebSocket, streams: list[asyncio.Task],
                      queue: asyncio.Queue) -> None:
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
        log.debug("WS 泵结束: %s", e)
    finally:
        recv_task.cancel()
        for s in streams:
            s.cancel()
        try:
            await ws.close()
        except Exception:  # noqa: BLE001
            pass
