"""运行实例注册表 + 状态机调和。

实例状态机（registry `state` 为持久化基础，探活调和出展示状态）：
  created → starting → running → (自行退出: exited) → stopping → stopped → deleting → 移除
  exited 按 exit_code 展示为 completed(0) / abnormal(≠0 或无码)
展示状态集合：notdeployed / created / starting / running / stopping / stopped /
  deleting / completed / abnormal / legacy / reused / deploying / degraded
"""
from __future__ import annotations

import asyncio
import json
import logging
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

from pydantic import BaseModel, Field

from . import executor
from .config import ConfigStore, ServiceConfig
from .ssh import SSHPool

log = logging.getLogger("sd.instances")

# 可持久化的基础状态
BASE_STATES = ("created", "starting", "running", "stopping", "stopped", "deleting", "exited")
# 瞬态（任务执行期间，拒绝其它操作）
TRANSIENT_STATES = ("starting", "stopping", "deleting")
# 瞬态超过此时长仍未落库（后端中断/崩溃遗留）→ 刷新时按探活自动收敛；
# 远大于任何真实操作上限（stop.timeout ≤ 300s + 60s 余量、启动 60s）
TRANSIENT_TTL = 600.0
# 展示状态 → 允许的操作（deploying/degraded 为心跳派生态，进程均存活 → 同 running）
CAN_STOP = ("running", "abnormal", "completed", "degraded", "deploying")
CAN_START = ("created", "stopped", "completed", "notdeployed")
CAN_RESTART = ("running", "degraded", "deploying")  # 重启 = 链接 停止→启动
CAN_DELETE = ("created", "stopped", "completed", "notdeployed",
              "running", "degraded", "deploying")  # running = 链接 停止→删除


def _now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


class Instance(BaseModel):
    service: str
    node: str
    pid: Optional[int] = None
    run_id: str
    log_path: str
    state: str = "created"  # created/starting/running/stopping/stopped/deleting/exited
    state_ts: float = 0.0  # 进入当前 state 的时间戳（瞬态 TTL 收敛用；旧记录 0=立即过期）
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
    # 冻结的停止配置快照（创建 / 最近一次启动时）：
    # 服务配置被删除后，实例仍可用这些字段完成停止 / 删除。
    # workspace 为空 = 无快照的旧实例（服务存在时由 refresh 自动补齐）。
    workspace: str = ""
    stop_script: Optional[str] = None
    stop_timeout: float = 10.0
    log_file: str = "service.log"

    def as_service_config(self) -> ServiceConfig:
        """由冻结快照重建停止 / 删除所需的 ServiceConfig（不含启动上传所需信息）。"""
        return ServiceConfig(
            name=self.service,
            workspace=self.workspace,
            start={"script": "start.sh", "log": self.log_file},
            stop={"script": self.stop_script, "timeout": self.stop_timeout},
        )


def reconcile(reg_state: str, probe: str, exit_code: Optional[int],
              deploy_state: Optional[str] = None) -> str:
    """registry 基础状态 + 探活结果 + 部署心跳 → 展示状态（纯函数）。

    probe: service_status 原始状态（running/dead/legacy/reused/nopidfile/nows/unknown）
    deploy_state: run/deploy.status 首 token（STARTING/READY/DEGRADED/-；None=无心跳）
      STARTING → deploying（部署中）；DEGRADED → degraded（异常中，持续监测）；
      其余（READY/-/None）→ running
    """
    if reg_state in TRANSIENT_STATES:
        return reg_state
    if probe == "nows":
        return "notdeployed"
    if probe in ("legacy", "reused", "unknown"):
        return probe
    if probe == "running":
        if deploy_state == "DEGRADED":
            return "degraded"
        if deploy_state == "STARTING":
            return "deploying"
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
    if display_state in ("created", "starting", "running", "notdeployed",
                         "deploying", "degraded"):
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
               args: Optional[list[str]] = None,
               cfg: Optional[ServiceConfig] = None) -> Instance:
        """创建实例记录（state=created）；variables/args/cfg 为冻结的完整快照。"""
        inst = Instance(service=service, node=node, pid=None, run_id=run_id,
                        log_path=log_path, variables=variables or {},
                        args=list(args) if args is not None else None,
                        workspace=cfg.workspace if cfg is not None else "",
                        stop_script=cfg.stop.script if cfg is not None else None,
                        stop_timeout=cfg.stop.timeout if cfg is not None else 10.0,
                        log_file=cfg.start.log if cfg is not None else "service.log")
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
        inst.state_ts = time.time()
        inst.stop_result = "none"  # 新一轮运行，历史手动停止结果作废
        self._save()

    def set_state(self, service: str, node: str, state: str) -> None:
        inst = self._items.get((service, node))
        if inst is None:
            return
        inst.state = state
        inst.state_ts = time.time()
        self._save()

    def resolve_transient(self, inst: Instance, probe_state: str) -> Optional[str]:
        """瞬态卡死收敛（TTL 超时自动 / 手动「解除」共用）。

        - deleting：该状态仅在停止管线成功后才设置 → 直接补完注销
        - 进程存活 → running；其余 → exited（清理状态列保留节点真实结果）
        返回说明文本（deleting 补删）或 None。
        """
        if inst.state not in TRANSIENT_STATES:
            return None
        if inst.state == "deleting":
            self.unregister(inst.service, inst.node)
            return "删除中卡死已自动补完删除（实例记录已移除）"
        self.set_state(inst.service, inst.node,
                       "running" if probe_state == "running" else "exited")
        return None

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

    def set_config(self, service: str, node: str, cfg: ServiceConfig) -> None:
        """刷新实例的停止配置快照（每次启动成功后调用；workspace 可能已变）。"""
        inst = self._items.get((service, node))
        if inst is None:
            return
        inst.workspace = cfg.workspace
        inst.stop_script = cfg.stop.script
        inst.stop_timeout = cfg.stop.timeout
        inst.log_file = cfg.start.log
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
                node = store.node(inst.node)
            except KeyError as e:
                d["status"] = "unknown"
                d["note"] = f"配置缺失: {e}"
                d["exit_code"] = None
                d["cleanup_status"] = "none"
                return d
            try:
                svc = store.service(inst.service)
            except KeyError:
                svc = None
            if svc is not None and not inst.workspace:
                # 旧实例懒补齐停止配置快照（服务仍存在时自愈）
                self.set_config(inst.service, inst.node, svc)
                d.update(workspace=svc.workspace, stop_script=svc.stop.script,
                         stop_timeout=svc.stop.timeout, log_file=svc.start.log)
            if svc is None:
                if not inst.workspace:
                    d["status"] = "unknown"
                    d["note"] = "服务配置已删除且实例无配置快照，无法自动操作；请在节点上手动清理"
                    d["exit_code"] = None
                    d["cleanup_status"] = "none"
                    return d
                d["note"] = "服务配置已删除（实例仍可停止/删除）"
                svc = inst.as_service_config()
            st = await executor.service_status(pool, node, svc, inst.run_id)
            # 瞬态 TTL 收敛：后端中断/崩溃遗留的 starting/stopping/deleting
            if inst.state in TRANSIENT_STATES and (time.time() - inst.state_ts) > TRANSIENT_TTL:
                note = self.resolve_transient(inst, st.state)
                if self.get(inst.service, inst.node) is None:
                    # deleting 已补完：本轮返回终态行，下次刷新即消失
                    d["status"] = "stopped"
                    d["note"] = note or "删除中卡死已自动补完删除"
                    d["deploy_state"] = None
                    d["exit_code"] = None
                    d["cleanup_status"] = "none"
                    return d
                inst = self.get(inst.service, inst.node) or inst
                d["state"] = inst.state
            display = reconcile(inst.state, st.state, st.exit_code, st.deploy_state)
            # 自动落库：running 检测到死亡 → exited；exited 检测到复活（外部重启）→ running
            if inst.state == "running" and display in ("completed", "abnormal"):
                self.set_state(inst.service, inst.node, "exited")
            elif inst.state == "exited" and display == "running":
                self.set_state(inst.service, inst.node, "running")
            d["status"] = display
            d["probe_pid"] = st.pid
            d["deploy_state"] = st.deploy_state if display in ("deploying", "degraded") else None
            d["exit_code"] = st.exit_code if display in ("completed", "abnormal") else None
            d["cleanup_status"] = cleanup_display(display, inst.stop_result, st.cleanup_code)
            return d

        return list(await asyncio.gather(*(_probe(i) for i in items)))
