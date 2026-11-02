"""任务管理：一次操作（deploy/create/start/stop/delete/clean）在 N 个节点上并发执行。"""
from __future__ import annotations

import asyncio
import json
import re
import logging
import time
import uuid
from datetime import datetime
from pathlib import Path
from typing import Optional

from pydantic import BaseModel, Field

from . import executor
from .config import ACTIONS, ENV_NAME_RE, WORKSPACE_RE, ConfigStore, Node, ServiceConfig
from .deploy_history import DeployHistory
from .deployer import deploy_service
from .instances import InstanceRegistry
from .ssh import SSHPool

log = logging.getLogger("sd.tasks")

MAX_HISTORY = 300


class SubTask(BaseModel):
    node: str
    status: str = "running"  # running | success | failed
    detail: str = ""
    error: Optional[str] = None
    pid: Optional[int] = None
    run_id: Optional[str] = None
    log_path: Optional[str] = None
    uploaded: Optional[int] = None
    started_at: float = Field(default_factory=time.time)
    finished_at: Optional[float] = None


class Task(BaseModel):
    id: str
    service: str
    action: str
    nodes: list[str]
    variables: dict[str, str] = Field(default_factory=dict)
    auto_start: bool = True  # create 动作：创建后是否立即启动
    paths: list[str] = Field(default_factory=list)  # clean 动作：补录的待清理目录
    status: str = "running"  # running | completed | partial | failed
    run_id: Optional[str] = None
    created_at: float = Field(default_factory=time.time)
    finished_at: Optional[float] = None
    subtasks: list[SubTask] = Field(default_factory=list)

    def summary(self) -> dict:
        d = self.model_dump(exclude={"subtasks"})
        counts = {"success": 0, "failed": 0, "running": 0}
        for s in self.subtasks:
            counts[s.status] = counts.get(s.status, 0) + 1
        d["counts"] = counts
        return d


class TaskError(ValueError):
    pass


def _state_guidance(display: str, st=None, inst=None) -> str:
    """按展示状态给出操作引导信息。"""
    if display == "running":
        return "实例运行中（如为重复启动请先停止）"
    if display in ("starting", "stopping", "deleting"):
        return f"操作进行中（{display}），请等待完成后重试"
    if display == "stopped":
        return "实例已停止，无需停止；可直接「启动」或「删除」"
    if display == "completed":
        return f"实例已完成(0){'，退出码 ' + str(st.exit_code) if st and st.exit_code is not None else ''}；可直接「启动」或「删除」，或「停止」重跑清理"
    if display == "abnormal":
        code = ""
        if st is not None and st.exit_code is not None:
            code = f"(码={st.exit_code})"
        return (f"实例处于异常态{code}，进程已异常退出且不会自动清理；"
                "请先执行「停止」进入已停止状态，再启动或删除")
    if display == "created":
        return "实例未启动（尚未运行过），无需停止；可直接「启动」或「删除」"
    if display == "notdeployed":
        return "节点上未找到部署目录（workspace 缺失）；可直接「启动」（将重新部署）或「删除」"
    if display == "legacy":
        return f"存在旧格式运行实例(PID {st.pid if st else '?'})，请按提示手动处理"
    if display == "reused":
        return "PID 已被其他进程复用，无法安全操作；可「删除」实例"
    return f"实例状态异常({display})"


class TaskManager:
    def __init__(self, pool: SSHPool, store: ConfigStore, instances: InstanceRegistry,
                 data_dir: Path, history: DeployHistory) -> None:
        self.pool = pool
        self.store = store
        self.instances = instances
        self.history = history
        self._file = data_dir / "tasks.json"
        self._tasks: list[Task] = []  # 新的在前
        self._used_run_ids: set[str] = set()
        self._start_locks: dict[tuple[str, str], asyncio.Lock] = {}
        self._load()

    def _start_lock(self, service: str, node: str) -> asyncio.Lock:
        key = (service, node)
        lock = self._start_locks.get(key)
        if lock is None:
            lock = self._start_locks[key] = asyncio.Lock()
        return lock

    # ------------------------------------------------------------ 持久化 ----
    def _load(self) -> None:
        if not self._file.is_file():
            return
        try:
            data = json.loads(self._file.read_text(encoding="utf-8"))
            for item in data.get("tasks", []):
                task = Task(**item)
                self._tasks.append(task)
                if task.run_id:
                    self._used_run_ids.add(task.run_id)
        except Exception as e:  # noqa: BLE001
            log.warning("tasks.json 加载失败(将重建): %s", e)
        self._tasks.sort(key=lambda t: t.created_at, reverse=True)
        self._tasks = self._tasks[:MAX_HISTORY]

    def _persist(self) -> None:
        self._file.parent.mkdir(parents=True, exist_ok=True)
        tmp = self._file.with_suffix(".json.tmp")
        tmp.write_text(
            json.dumps({"tasks": [t.model_dump() for t in self._tasks]},
                       ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        tmp.replace(self._file)

    # ------------------------------------------------------------ 创建 ----
    def new_run_id(self) -> str:
        base = datetime.now().strftime("%Y%m%d-%H%M%S")
        run_id, i = base, 0
        while run_id in self._used_run_ids:
            i += 1
            run_id = f"{base}-{i}"
        self._used_run_ids.add(run_id)
        return run_id

    def validate(self, service_name: str, action: str, nodes: list[str],
                 variables: dict[str, str]) -> tuple[ServiceConfig, list[Node], dict[str, str]]:
        if action not in ACTIONS:
            raise TaskError(f"action 必须是 {list(ACTIONS)}，收到: {action!r}")
        try:
            service = self.store.service(service_name)
        except KeyError as e:
            raise TaskError(str(e)) from e
        if service.hidden:
            raise TaskError(f"{service_name} 是模板服务（hidden），不可直接操作；请先克隆为新服务")
        if not nodes:
            raise TaskError("nodes 不能为空")
        unknown = [n for n in nodes if self.store.cluster.node(n) is None]
        if unknown:
            raise TaskError(f"未知节点: {unknown}")
        if service.nodes:
            not_allowed = [n for n in nodes if n not in service.nodes]
            if not_allowed:
                raise TaskError(
                    f"节点不在服务 {service_name} 的目标节点列表 {service.nodes} 中: {not_allowed}")
        if len(set(nodes)) != len(nodes):
            raise TaskError("nodes 存在重复")
        merged = dict(service.variables)
        for k, v in (variables or {}).items():
            if not ENV_NAME_RE.match(k):
                raise TaskError(f"变量名非法: {k!r}")
            merged[k] = str(v)
        resolved_nodes = [self.store.node(n) for n in nodes]
        return service, resolved_nodes, merged

    async def create(self, service_name: str, action: str, nodes: list[str],
                     variables: dict[str, str] | None = None,
                     auto_start: bool = True,
                     paths: list[str] | None = None) -> Task:
        service, resolved_nodes, merged_vars = self.validate(
            service_name, action, nodes, variables or {})
        clean_paths: list[str] = []
        if action == "clean":
            for p in (paths or [])[:16]:
                p = p.strip()
                if not WORKSPACE_RE.match(p):
                    raise TaskError(f"补录路径非法: {p!r}（须为绝对路径或 ~/ 开头，仅字母数字._-/）")
                clean_paths.append(p)
        task = Task(
            id=uuid.uuid4().hex[:12],
            service=service_name,
            action=action,
            nodes=list(nodes),
            variables={} if action in ("stop", "delete", "clean") else merged_vars,
            auto_start=auto_start,
            paths=clean_paths,
            run_id=self.new_run_id() if action == "create" else None,
            subtasks=[SubTask(node=n.name) for n in resolved_nodes],
        )
        self._tasks.insert(0, task)
        self._tasks = self._tasks[:MAX_HISTORY]
        self._persist()
        asyncio.get_running_loop()  # 确认事件循环存在
        asyncio.create_task(self._execute(task, service))
        log.info("任务已创建 %s: %s %s on %s", task.id, action, service_name, task.nodes)
        return task

    # ------------------------------------------------------------ 执行 ----
    def get(self, task_id: str) -> Optional[Task]:
        for t in self._tasks:
            if t.id == task_id:
                return t
        return None

    def list(self, limit: int = 50) -> list[Task]:
        return self._tasks[:limit]

    async def _execute(self, task: Task, service: ServiceConfig) -> None:
        sub_by_node = {s.node: s for s in task.subtasks}
        await asyncio.gather(
            *(self._run_subtask(task, service, node_name, sub_by_node[node_name])
              for node_name in task.nodes),
            return_exceptions=True,
        )
        results = [s.status for s in task.subtasks]
        if all(r == "success" for r in results):
            task.status = "completed"
        elif all(r == "failed" for r in results):
            task.status = "failed"
        else:
            task.status = "partial"
        task.finished_at = time.time()
        self._persist()
        log.info("任务 %s 结束: %s", task.id, task.status)

    async def _run_subtask(self, task: Task, service: ServiceConfig,
                           node_name: str, sub: SubTask) -> None:
        node = self.store.node(node_name)
        try:
            if task.action == "deploy":
                n = await deploy_service(self.pool, node, service)
                sub.uploaded = n
                sub.detail = f"已下发 {n} 个文件 → {service.workspace}"
                self._record_ws(service, node_name)

            elif task.action == "create":
                async with self._start_lock(service.name, node_name):
                    existing = self.instances.get(service.name, node_name)
                    if existing is not None:
                        raise executor.ExecError(
                            f"节点 {node_name} 已存在服务 {service.name} 的实例"
                            f"（run_id {existing.run_id}），请在实例列表中操作")
                    st = await executor.service_status(self.pool, node, service)
                    if st.state in ("running", "legacy"):
                        raise executor.ExecError(
                            f"节点 {node_name} 上存在运行中的进程但无实例记录"
                            f"（状态 {st.state}，PID {st.pid}），请先停止或删除后再创建")
                    self.instances.create(service.name, node_name, task.run_id,
                                          service.log_path(task.run_id))
                    await executor.create_dirs(self.pool, node, service, task.run_id)
                    self._record_ws(service, node_name)
                    sub.run_id = task.run_id
                    sub.log_path = service.log_path(task.run_id)
                    sub.detail = f"实例已创建（run_id {task.run_id}）"
                    if task.auto_start:
                        await self._launch(task, service, node, node_name, sub, task.run_id)

            elif task.action == "start":
                async with self._start_lock(service.name, node_name):
                    inst = self.instances.get(service.name, node_name)
                    if inst is None:
                        # API 兼容：实例不存在时自动创建
                        run_id = self._ensure_instance(task, service, node_name)
                        self.instances.set_state(service.name, node_name, "starting")
                        try:
                            await self._launch(task, service, node, node_name, sub, run_id)
                        except Exception:
                            self.instances.set_state(service.name, node_name, "created")
                            raise
                    else:
                        st = await executor.service_status(self.pool, node, service, inst.run_id)
                        from .instances import CAN_START, reconcile
                        display = reconcile(inst.state, st.state, st.exit_code)
                        if display not in CAN_START:
                            raise executor.ExecError(
                                f"当前状态不允许启动；{_state_guidance(display, st, inst)}")
                        prev = inst.state
                        self.instances.set_state(service.name, node_name, "starting")
                        try:
                            await self._launch(task, service, node, node_name, sub, inst.run_id)
                        except Exception:
                            self.instances.set_state(service.name, node_name, prev)
                            raise

            elif task.action == "stop":
                # 状态机：仅 running / abnormal / completed 可停止（走停止中 → 已停止）
                async with self._start_lock(service.name, node_name):
                    inst = self.instances.get(service.name, node_name)
                    if inst is None:
                        raise executor.ExecError(
                            f"节点 {node_name} 无服务 {service.name} 的实例记录，无法停止")
                    st = await executor.service_status(self.pool, node, service, inst.run_id)
                    from .instances import CAN_STOP, reconcile
                    display = reconcile(inst.state, st.state, st.exit_code)
                    if display not in CAN_STOP:
                        raise executor.ExecError(
                            f"当前状态不允许停止；{_state_guidance(display, st, inst)}")
                    run_id = inst.run_id
                    self.instances.set_state(service.name, node_name, "stopping")
                    try:
                        out = await executor.stop_service(self.pool, node, service, run_id=run_id)
                        sub.detail = out
                        self.instances.set_state(service.name, node_name, "stopped")
                        self.instances.set_stop_result(service.name, node_name, "ok")
                    except executor.ExecError as e:
                        msg = str(e)
                        if "stop.sh 失败" in msg:
                            m = re.search(r"stop\.sh 失败\(exit=(\d+)\)", msg)
                            code = m.group(1) if m else "?"
                            self.instances.set_stop_result(
                                service.name, node_name, f"failed:{code}")
                        else:
                            self.instances.set_stop_result(service.name, node_name, "killfail")
                        # 状态回退：按探活判定（活→running，死→exited）
                        st2 = await executor.service_status(self.pool, node, service, run_id)
                        self.instances.set_state(
                            service.name, node_name,
                            "running" if st2.state == "running" else "exited")
                        raise
                    sub.run_id = run_id
                    sub.log_path = inst.log_path

            elif task.action == "restart":
                # 重启 = 链接「停止→启动」，仅运行中；停止失败中止并如实报错，等待用户排查
                async with self._start_lock(service.name, node_name):
                    inst = self.instances.get(service.name, node_name)
                    if inst is None:
                        raise executor.ExecError(
                            f"节点 {node_name} 无服务 {service.name} 的实例记录，无法重启")
                    st = await executor.service_status(self.pool, node, service, inst.run_id)
                    from .instances import CAN_RESTART, reconcile
                    display = reconcile(inst.state, st.state, st.exit_code)
                    if display not in CAN_RESTART:
                        # 停止失败残留的异常态也拒绝——引导用户先排查/停止归一
                        raise executor.ExecError(
                            f"当前状态不允许重启；{_state_guidance(display, st, inst)}")
                    run_id = inst.run_id
                    # ① 停止阶段（完整管线：组杀 + stop.sh + 日志）
                    self.instances.set_state(service.name, node_name, "stopping")
                    try:
                        out = await executor.stop_service(self.pool, node, service, run_id=run_id)
                    except executor.ExecError as e:
                        msg = str(e)
                        if "stop.sh 失败" in msg:
                            m = re.search(r"stop\.sh 失败\(exit=(\d+)\)", msg)
                            code = m.group(1) if m else "?"
                            self.instances.set_stop_result(
                                service.name, node_name, f"failed:{code}")
                        else:
                            self.instances.set_stop_result(service.name, node_name, "killfail")
                        st2 = await executor.service_status(self.pool, node, service, run_id)
                        self.instances.set_state(
                            service.name, node_name,
                            "running" if st2.state == "running" else "exited")
                        raise  # 中止重启，等待用户排查后重新操作
                    self.instances.set_stop_result(service.name, node_name, "ok")
                    sub.detail = out
                    # ② 启动阶段（同 run_id 续写）
                    self.instances.set_state(service.name, node_name, "starting")
                    try:
                        await self._launch(task, service, node, node_name, sub, run_id)
                    except Exception:
                        # 停止已成功完成，实例停留已停止（可手动启动）
                        self.instances.set_state(service.name, node_name, "stopped")
                        raise
                    sub.run_id = run_id
                    sub.log_path = inst.log_path

            elif task.action == "delete":
                # 状态机：created/stopped/completed/notdeployed 直接删除；
                # running = 链接「停止→删除」，停止必须正常完成否则中止删除；abnormal 拒绝（先停止归一）
                async with self._start_lock(service.name, node_name):
                    inst = self.instances.get(service.name, node_name)
                    if inst is None:
                        sub.detail = "实例不存在（幂等成功）"
                    else:
                        sub.run_id = inst.run_id
                        sub.log_path = inst.log_path
                        st = await executor.service_status(self.pool, node, service, inst.run_id)
                        from .instances import CAN_DELETE, reconcile
                        display = reconcile(inst.state, st.state, st.exit_code)
                        if display not in CAN_DELETE:
                            raise executor.ExecError(
                                f"当前状态不允许删除；{_state_guidance(display, st, inst)}")
                        if display == "running":
                            # 链接停止：完整停止管线（组杀 + stop.sh + 日志）
                            self.instances.set_state(service.name, node_name, "stopping")
                            try:
                                out = await executor.stop_service(
                                    self.pool, node, service, run_id=inst.run_id)
                            except executor.ExecError as e:
                                msg = str(e)
                                if "stop.sh 失败" in msg:
                                    m = re.search(r"stop\.sh 失败\(exit=(\d+)\)", msg)
                                    code = m.group(1) if m else "?"
                                    self.instances.set_stop_result(
                                        service.name, node_name, f"failed:{code}")
                                else:
                                    self.instances.set_stop_result(
                                        service.name, node_name, "killfail")
                                st2 = await executor.service_status(
                                    self.pool, node, service, inst.run_id)
                                self.instances.set_state(
                                    service.name, node_name,
                                    "running" if st2.state == "running" else "exited")
                                raise  # 停止未正常结束：中止删除，实例保留可重试
                            self.instances.set_stop_result(service.name, node_name, "ok")
                            self.instances.set_state(service.name, node_name, "deleting")
                            sub.detail = (out or "") + "；停止完成，实例已删除"
                            self.instances.unregister(service.name, node_name)
                        else:
                            self.instances.set_state(service.name, node_name, "deleting")
                            # 可删除态均无需停止进程/清理（已停止或从未运行）
                            sub.detail = f"实例已删除（状态 {display}；节点文件保留，可用「清理」移除）"
                            self.instances.unregister(service.name, node_name)

            elif task.action == "clean":
                # 服务级清理：仅当该节点不存在实例时允许（运行/停止/已退出均算存在）
                existing = self.instances.get(service.name, node_name)
                if existing is not None:
                    raise executor.ExecError(
                        f"节点 {node_name} 存在服务 {service.name} 的实例"
                        f"（run_id {existing.run_id}），请先「删除」实例后再清理")
                dirs = list(dict.fromkeys(
                    self.history.dirs_for(service.name, [node_name]).get(node_name, [])
                    + [service.workspace] + task.paths))
                out = await executor.clean_dirs(self.pool, node, service, dirs)
                sub.detail = out
                for d in dirs:
                    self.history.remove(service.name, node_name, d)
                # 防御性注销（正常情况下无可注销对象）
                self.instances.unregister(service.name, node_name)

            sub.status = "success"
        except Exception as e:  # noqa: BLE001
            sub.status = "failed"
            sub.error = str(e)
            log.warning("任务 %s 子任务失败(%s): %s", task.id, node_name, e)
        finally:
            sub.finished_at = time.time()
            self._persist()

    # ------------------------------------------------------ 生命周期辅助 ----
    def _record_ws(self, service: ServiceConfig, node_name: str) -> None:
        """登记部署历史：记录该 (服务, 节点) 使用过的 workspace（换目录后旧目录仍可被清理）。"""
        self.history.record(service.name, node_name, service.workspace)

    async def _launch(self, task: Task, service: ServiceConfig, node: Node,
                      node_name: str, sub: SubTask, run_id: str) -> None:
        """部署 + 分隔符 + 续写启动，并更新实例记录。"""
        info = await executor.start_service(self.pool, node, service, run_id, task.variables)
        self._record_ws(service, node_name)
        sub.pid = info["pid"]
        sub.run_id = run_id
        sub.log_path = info["log_path"]
        sub.uploaded = info["uploaded"]
        sub.detail = f"pid={info['pid']}，日志 {info['log_path']}"
        self.instances.update_start(service.name, node_name, info["pid"], info["log_path"])
        if task.run_id is None:
            task.run_id = run_id

    def _ensure_instance(self, task: Task, service: ServiceConfig, node_name: str) -> str:
        """返回实例 run_id；实例不存在时自动创建（API 兼容：直接 start）。"""
        inst = self.instances.get(service.name, node_name)
        if inst is not None:
            return inst.run_id
        run_id = task.run_id or self.new_run_id()
        self.instances.create(service.name, node_name, run_id, service.log_path(run_id))
        return run_id
