"""运行实例注册表：记录每个 (service, node) 最近一次启动的 PID / run_id / 日志路径。"""
from __future__ import annotations

import asyncio
import json
import logging
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

from pydantic import BaseModel, Field

from . import executor
from .config import ConfigStore
from .ssh import SSHPool

log = logging.getLogger("sd.instances")


def _now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


class Instance(BaseModel):
    service: str
    node: str
    pid: Optional[int] = None
    run_id: str
    log_path: str
    created_at: str = Field(default_factory=_now_iso)
    started_at: str = Field(default_factory=_now_iso)  # 最近一次启动时间


class InstanceRegistry:
    def __init__(self, data_dir: Path) -> None:
        self._file = data_dir / "instances.json"
        self._items: dict[tuple[str, str], Instance] = {}
        self._load()

    def _load(self) -> None:
        if not self._file.is_file():
            return
        try:
            data = json.loads(self._file.read_text(encoding="utf-8"))
            for item in data.get("instances", []):
                inst = Instance(**item)
                self._items[(inst.service, inst.node)] = inst
        except Exception as e:  # noqa: BLE001
            log.warning("instances.json 加载失败(将重建): %s", e)

    def _save(self) -> None:
        self._file.parent.mkdir(parents=True, exist_ok=True)
        tmp = self._file.with_suffix(".json.tmp")
        tmp.write_text(
            json.dumps({"instances": [i.model_dump() for i in self._items.values()]},
                       ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        tmp.replace(self._file)

    def create(self, service: str, node: str, run_id: str, log_path: str) -> Instance:
        """创建实例记录（停止后保留，删除才移除）。"""
        inst = Instance(service=service, node=node, pid=None, run_id=run_id, log_path=log_path)
        self._items[(service, node)] = inst
        self._save()
        return inst

    def update_start(self, service: str, node: str, pid: Optional[int], log_path: str) -> None:
        """实例启动后更新 PID / 最近启动时间 / 日志路径（run_id 不变）。"""
        inst = self._items.get((service, node))
        if inst is None:
            return
        inst.pid = pid
        inst.log_path = log_path
        inst.started_at = _now_iso()
        self._save()

    def unregister(self, service: str, node: str) -> None:
        self._items.pop((service, node), None)
        self._save()

    def get(self, service: str, node: str) -> Optional[Instance]:
        return self._items.get((service, node))

    def all(self) -> list[Instance]:
        return sorted(self._items.values(), key=lambda i: (i.service, i.node))

    async def refresh(self, pool: SSHPool, store: ConfigStore) -> list[dict]:
        """对每个实例做 kill -0 探活，返回带状态注解的列表。"""
        items = self.all()
        if not items:
            return []

        async def _probe(inst: Instance) -> dict:
            d = inst.model_dump()
            try:
                svc = store.service(inst.service)
                node = store.node(inst.node)
            except KeyError as e:
                d["status"] = "unknown"
                d["note"] = f"配置缺失: {e}"
                return d
            st = await executor.service_status(pool, node, svc, inst.run_id)
            d["status"] = st.state  # running | dead | legacy | reused | nopidfile | nows | unknown
            d["probe_pid"] = st.pid
            d["exit_code"] = st.exit_code
            return d

        return list(await asyncio.gather(*(_probe(i) for i in items)))
