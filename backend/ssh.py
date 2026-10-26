"""asyncssh 连接池：每节点一条连接，多路复用 channel，失效自动重连一次。"""
from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass
from pathlib import Path

import asyncssh

from .config import Node

log = logging.getLogger("sd.ssh")


class SSHError(RuntimeError):
    pass


@dataclass
class RunResult:
    exit_code: int | None
    stdout: str
    stderr: str

    @property
    def ok(self) -> bool:
        return self.exit_code == 0


class SSHPool:
    def __init__(self) -> None:
        self._conns: dict[str, asyncssh.SSHClientConnection] = {}
        self._lock = asyncio.Lock()

    async def _connect(self, node: Node) -> asyncssh.SSHClientConnection:
        key_path = Path(node.private_key).expanduser()
        client_keys = [str(key_path)] if key_path.exists() else None
        if client_keys is None:
            log.warning("节点 %s 的私钥 %s 不存在，回退到 ssh-agent/默认密钥", node.name, node.private_key)
        try:
            conn = await asyncssh.connect(
                host=node.ip,
                port=node.port,
                username=node.username,
                known_hosts=None,
                client_keys=client_keys,
                connect_timeout=node.connect_timeout,
                keepalive_interval=15,
                keepalive_count_max=4,
            )
        except (asyncssh.Error, OSError) as e:
            raise SSHError(f"连接 {node.name}({node.ip}:{node.port}) 失败: {e}") from e
        log.info("已连接节点 %s(%s:%s)", node.name, node.ip, node.port)
        return conn

    async def connect_dedicated(self, node: Node) -> asyncssh.SSHClientConnection:
        """为长生命周期通道（日志流等）建立独立连接：不受连接池丢弃/重建影响。"""
        conn = await self._connect(node)
        log.info("节点 %s 建立日志流专用连接", node.name)
        return conn

    async def get(self, node: Node) -> asyncssh.SSHClientConnection:
        conn = self._conns.get(node.name)
        if conn is not None and not conn.is_closed():
            return conn
        async with self._lock:
            conn = self._conns.get(node.name)
            if conn is not None and not conn.is_closed():
                return conn
            conn = await self._connect(node)
            self._conns[node.name] = conn
            return conn

    async def drop(self, name: str) -> None:
        conn = self._conns.pop(name, None)
        if conn is not None:
            try:
                conn.close()
            except Exception:  # noqa: BLE001
                pass

    async def run(self, node: Node, command: str, timeout: float | None = None) -> RunResult:
        """执行远程命令；连接失效时丢弃重连并重试一次。"""
        last_err: Exception | None = None
        for _attempt in (1, 2):
            try:
                conn = await self.get(node)
                result = await asyncio.wait_for(
                    conn.run(command, timeout=timeout, encoding="utf-8", errors="replace"),
                    timeout=(timeout + 15) if timeout else None,
                )
                return RunResult(result.exit_status, result.stdout or "", result.stderr or "")
            except asyncio.TimeoutError as e:
                raise SSHError(f"在 {node.name} 上执行命令超时(>{timeout}s)") from e
            except (asyncssh.Error, OSError) as e:
                last_err = e
                await self.drop(node.name)
                log.warning("节点 %s 连接异常，重连重试: %s", node.name, e)
        raise SSHError(f"在 {node.name} 上执行命令失败: {last_err}")

    async def sftp(self, node: Node) -> asyncssh.SFTPClient:
        conn = await self.get(node)
        try:
            return await conn.start_sftp_client()
        except (asyncssh.Error, OSError) as e:
            await self.drop(node.name)
            raise SSHError(f"在 {node.name} 上打开 SFTP 失败: {e}") from e

    async def close_all(self) -> None:
        for name in list(self._conns):
            await self.drop(name)
