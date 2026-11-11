"""运行实例注册表 + 状态机调和。

实例状态机（registry `state` 为持久化基础，探活调和出展示状态）：
  created → starting → running → (自行退出: exited) → stopping → stopped → deleting → 移除
  exited 按 exit_code 展示为 completed(0) / abnormal(≠0 或无码)
展示状态集合：notdeployed / created / starting / running / stopping / stopped /
  deleting / completed / abnormal / legacy / reused
"""
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

# 可持久化的基础状态
BASE_STATES = ("created", "starting", "running", "stopping", "stopped", "deleting", "exited")
# 瞬态（任务执行期间，拒绝其它操作）
TRANSIENT_STATES = ("starting", "stopping", "deleting")
# 展示状态 → 允许的操作
CAN_STOP = ("running", "abnormal", "completed")
CAN_START = ("created", "stopped", "completed", "notdeployed")
CAN_RESTART = ("running",)  # 重启 = 链接 停止→启动，仅运行中
CAN_DELETE = ("created", "stopped", "completed", "notdeployed", "running")  # running = 链接 停止→删除


def _now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


class Instance(BaseModel):
    service: str
    node: str
    pid: Optional[int] = None
    run_id: str
    log_path: str
    state: str = "created"  # created/starting/running/stopping/stopped/deleting/exited
    stop_result: str = "none"  # 手动停止结果：none/ok/failed:N/killfail
    created_at: str = Field(default_factory=_now_iso)
    started_at: str = Field(default_factory=_now_iso)  # 最近一次启动时间
    # 冻结的完整变量快照（service.json 默认值 + 用户覆盖）：
    # 创建实例时落库，后续启动 / 重启原样沿用；显式携带变量的启动合并更新。
    # 空 dict = 旧实例（本字段引入前创建），沿用当前 service 默认变量。
    variables: dict[str, str] = Field(default_factory=dict)
    # 冻结的完整启动参数快照（service.start.args 静态参数 + 用户追加参数）：
    # 创建实例时落库，后续启动 / 重启原样沿用；显式携带 args 的启动替换快照。
    # None = 旧实例（本字段引入前创建），回退当前 service.start.args。
    args: Optional[list[str]] = None


def reconcile(reg_state: str, probe: str, exit_code: Optional[int]) -> str:
    """registry 基础状态 + 探活结果 → 展示状态（纯函数）。

    probe: service_status 原始状态（running/dead/legacy/reused/nopidfile/nows/unknown）
    """
    if reg_state in TRANSIENT_STATES:
        return reg_state
    if probe == "nows":
        return "notdeployed"
    if probe in ("legacy", "reused", "unknown"):
        return probe
    if probe == "running":
        return "running"  # 含 stopped/created 下检测到外部重启
    if probe == "dead":
        if reg_state == "stopped":
            return "stopped"  # 已停止为准（pid 文件可能已变动）
        if exit_code == 0:
            return "completed"
        return "abnormal"  # 码=N 或无码（被终止）
    # probe == nopidfile
    if reg_state == "stopped":
        return "stopped"
    if reg_state == "exited":
        return "completed" if exit_code == 0 else "abnormal"
    if reg_state == "running":
        return "abnormal"  # pid 文件被外部删除
    return "created"


def cleanup_display(display_state: str, stop_result: str,
                    cleanup_code: Optional[int]) -> str:
    """展示状态 + 手动停止结果 + 节点 cleanup_code → 清理状态列取值。

    返回：none / running / ok / failed:N / killfail / unclean
    """
    if display_state == "stopping":
        return "running"  # 执行中
    if display_state in ("created", "starting", "running", "notdeployed"):
        return "none"
    if display_state == "stopped" and stop_result not in ("none", ""):
        return stop_result  # ok / failed:N / killfail
    # completed / abnormal / stopped(无手动记录) → 依节点最近一次 stop.sh 退出码
    if cleanup_code is None:
        return "unclean"
    if cleanup_code == 0:
        return "ok"
    return f"failed:{cleanup_code}"


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
            for raw in data.get("instances", []):
                # 旧格式迁移：stopped 布尔标记 → state；有 pid → running；否则 created
                if "state" not in raw:
                    if raw.get("stopped"):
                        raw["state"] = "stopped"
                    elif raw.get("pid"):
                        raw["state"] = "running"
                    else:
                        raw["state"] = "created"
                    raw.pop("stopped", None)
                inst = Instance(**raw)
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

    def create(self, service: str, node: str, run_id: str, log_path: str,
               variables: Optional[dict[str, str]] = None,
               args: Optional[list[str]] = None) -> Instance:
        """创建实例记录（state=created）；variables/args 为冻结的完整快照。"""
        inst = Instance(service=service, node=node, pid=None, run_id=run_id,
                        log_path=log_path, variables=variables or {},
                        args=list(args) if args is not None else None)
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
        inst.state = "running"
        inst.stop_result = "none"  # 新一轮运行，历史手动停止结果作废
        self._save()

    def set_state(self, service: str, node: str, state: str) -> None:
        inst = self._items.get((service, node))
        if inst is None:
            return
        inst.state = state
        self._save()

    def set_stop_result(self, service: str, node: str, result: str) -> None:
        inst = self._items.get((service, node))
        if inst is None:
            return
        inst.stop_result = result
        self._save()

    def set_variables(self, service: str, node: str, variables: dict[str, str]) -> None:
        """更新实例的变量快照（显式携带变量的启动合并后调用）。"""
        inst = self._items.get((service, node))
        if inst is None:
            return
        inst.variables = dict(variables)
        self._save()

    def set_args(self, service: str, node: str, args: list[str]) -> None:
        """更新实例的启动参数快照（显式携带 args 的启动替换后调用）。"""
        inst = self._items.get((service, node))
        if inst is None:
            return
        inst.args = list(args)
        self._save()

    def unregister(self, service: str, node: str) -> None:
        self._items.pop((service, node), None)
        self._save()

    def get(self, service: str, node: str) -> Optional[Instance]:
        return self._items.get((service, node))

    def all(self) -> list[Instance]:
        return sorted(self._items.values(), key=lambda i: (i.service, i.node))

    async def refresh(self, pool: SSHPool, store: ConfigStore) -> list[dict]:
        """探活调和出展示状态与清理状态；running→exited 自动落库（不自动清理）。"""
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
                d["exit_code"] = None
                d["cleanup_status"] = "none"
                return d
            st = await executor.service_status(pool, node, svc, inst.run_id)
            display = reconcile(inst.state, st.state, st.exit_code)
            # 自动落库：running 检测到死亡 → exited；exited 检测到复活（外部重启）→ running
            if inst.state == "running" and display in ("completed", "abnormal"):
                self.set_state(inst.service, inst.node, "exited")
            elif inst.state == "exited" and display == "running":
                self.set_state(inst.service, inst.node, "running")
            d["status"] = display
            d["probe_pid"] = st.pid
            d["exit_code"] = st.exit_code if display in ("completed", "abnormal") else None
            d["cleanup_status"] = cleanup_display(display, inst.stop_result, st.cleanup_code)
            return d

        return list(await asyncio.gather(*(_probe(i) for i in items)))
