"""监控项持久化：命名的 watch 命令（cmd + interval），存 data/monitors.json。"""
from __future__ import annotations

import json
import logging
import time
import uuid
from pathlib import Path
from typing import Optional

from pydantic import BaseModel, Field, field_validator

log = logging.getLogger("sd.monitors")

MAX_CMD_LEN = 2000


class Monitor(BaseModel):
    id: str
    name: str
    cmd: str
    interval: int = Field(default=2, ge=1, le=60)
    created_at: float = Field(default_factory=time.time)

    @field_validator("name")
    @classmethod
    def _check_name(cls, v: str) -> str:
        v = v.strip()
        if not v or len(v) > 64:
            raise ValueError("名称不能为空且不超过 64 字符")
        return v

    @field_validator("cmd")
    @classmethod
    def _check_cmd(cls, v: str) -> str:
        v = v.strip()
        if not v or len(v) > MAX_CMD_LEN:
            raise ValueError(f"命令不能为空且不超过 {MAX_CMD_LEN} 字符")
        if "\n" in v:
            raise ValueError("命令不能包含换行")
        return v


class MonitorStore:
    def __init__(self, data_dir: Path) -> None:
        self._file = data_dir / "monitors.json"
        self._items: dict[str, Monitor] = {}
        self._load()

    def _load(self) -> None:
        if not self._file.is_file():
            return
        try:
            data = json.loads(self._file.read_text(encoding="utf-8"))
            for item in data.get("monitors", []):
                m = Monitor(**item)
                self._items[m.id] = m
        except Exception as e:  # noqa: BLE001
            log.warning("monitors.json 加载失败(将重建): %s", e)

    def _save(self) -> None:
        self._file.parent.mkdir(parents=True, exist_ok=True)
        tmp = self._file.with_suffix(".json.tmp")
        tmp.write_text(
            json.dumps({"monitors": [m.model_dump() for m in self._items.values()]},
                       ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        tmp.replace(self._file)

    def list(self) -> list[Monitor]:
        return sorted(self._items.values(), key=lambda m: m.name)

    def get(self, id_: str) -> Optional[Monitor]:
        return self._items.get(id_)

    def _name_taken(self, name: str, exclude_id: Optional[str] = None) -> bool:
        return any(m.name == name and m.id != exclude_id for m in self._items.values())

    def create(self, name: str, cmd: str, interval: int) -> Monitor:
        if self._name_taken(name):
            raise ValueError(f"监控项名称已存在: {name}")
        m = Monitor(id=uuid.uuid4().hex[:12], name=name, cmd=cmd, interval=interval)
        self._items[m.id] = m
        self._save()
        log.info("监控项已创建: %s (每 %ss 执行)", name, interval)
        return m

    def update(self, id_: str, name: Optional[str] = None, cmd: Optional[str] = None,
               interval: Optional[int] = None) -> Monitor:
        m = self._items.get(id_)
        if m is None:
            raise KeyError(f"监控项不存在: {id_}")
        # 未提供的字段保持原值
        new = Monitor(id=m.id, created_at=m.created_at,
                      name=name if name is not None else m.name,
                      cmd=cmd if cmd is not None else m.cmd,
                      interval=interval if interval is not None else m.interval)
        if self._name_taken(new.name, exclude_id=id_):
            raise ValueError(f"监控项名称已存在: {new.name}")
        self._items[id_] = new
        self._save()
        return new

    def delete(self, id_: str) -> bool:
        if self._items.pop(id_, None) is None:
            return False
        self._save()
        return True
