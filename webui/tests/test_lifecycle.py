"""实例生命周期（create/start/stop/restart/delete）模型测试。"""
from __future__ import annotations

from pathlib import Path

import pytest

from webui.backend.config import ACTIONS, ConfigStore
from webui.backend.instances import InstanceRegistry
from webui.backend.tasks import Task, TaskManager


def make_manager(tmp_path: Path) -> TaskManager:
    cluster = tmp_path / "cluster.json"
    cluster.write_text('{"nodes": [{"name": "n1", "ip": "1.1.1.1"}]}', encoding="utf-8")
    svc_dir = tmp_path / "services"
    svc_dir.mkdir()
    d = svc_dir / "svc"
    d.mkdir()
    (d / "service.json").write_text(
        '{"name": "svc", "workspace": "/data/svc", "variables": {"A": "1"},'
        ' "start": {"script": "start.sh", "args": ["--base"], "log": "svc.log"}}', encoding="utf-8")
    (d / "start.sh").write_text("#!/bin/bash\ntrue\n", encoding="utf-8")
    store = ConfigStore(cluster_path=cluster, services_dir=svc_dir)
    registry = InstanceRegistry(tmp_path)
    from webui.backend.deploy_history import DeployHistory
    history = DeployHistory(tmp_path)
    return TaskManager(pool=None, store=store, instances=registry,
                       data_dir=tmp_path, history=history)


def test_actions_set():
    for action in ("deploy", "create", "start", "stop", "restart", "delete", "clean"):
        assert action in ACTIONS


def test_task_defaults():
    t = Task(id="x", service="s", action="create", nodes=["n1"])
    assert t.auto_start is True


def test_validate_rejects_unknown_action(tmp_path):
    tm = make_manager(tmp_path)
    with pytest.raises(Exception, match="action"):
        tm.validate("svc", "explode", ["n1"], {})
    tm.validate("svc", "create", ["n1"], {})   # 新动作合法
    tm.validate("svc", "delete", ["n1"], {})


def test_registry_lifecycle(tmp_path):
    reg = InstanceRegistry(tmp_path)
    inst = reg.create("svc", "n1", "run-1", "/data/svc/logs/run-1/svc.log")
    assert inst.pid is None and inst.run_id == "run-1"
    assert inst.state == "created" and inst.stop_result == "none"
    first_created = reg.get("svc", "n1").created_at

    reg.update_start("svc", "n1", 123, "/data/svc/logs/run-1/svc.log")
    got = reg.get("svc", "n1")
    assert got.pid == 123
    assert got.run_id == "run-1"           # run_id 不变（续写同一日志）
    assert got.created_at == first_created  # 创建时间不变
    assert got.started_at                  # 最近启动时间存在
    assert got.state == "running" and got.stop_result == "none"

    # 停止状态机：stopping → stopped + 结果
    reg.set_state("svc", "n1", "stopping")
    assert reg.get("svc", "n1").state == "stopping"
    reg.set_state("svc", "n1", "stopped")
    reg.set_stop_result("svc", "n1", "ok")
    got = reg.get("svc", "n1")
    assert got.state == "stopped" and got.stop_result == "ok"
    # 跨进程持久化
    reg2 = InstanceRegistry(tmp_path)
    assert reg2.get("svc", "n1").state == "stopped"
    assert reg2.get("svc", "n1").stop_result == "ok"
    # 再启动：running 且历史停止结果作废
    reg.update_start("svc", "n1", 456, "/data/svc/logs/run-1/svc.log")
    assert reg.get("svc", "n1").state == "running"
    assert reg.get("svc", "n1").stop_result == "none"

    reg.unregister("svc", "n1")
    assert reg.get("svc", "n1") is None
    assert InstanceRegistry(tmp_path).get("svc", "n1") is None


def test_registry_migration_from_stopped_flag(tmp_path):
    """旧格式（stopped 布尔标记、无 state）迁移加载。"""
    import json
    f = tmp_path / "instances.json"
    f.write_text(json.dumps({"instances": [
        {"service": "a", "node": "n1", "pid": 111, "run_id": "r1", "log_path": "/l", "stopped": True},
        {"service": "a", "node": "n2", "pid": 222, "run_id": "r2", "log_path": "/l"},
        {"service": "b", "node": "n1", "pid": None, "run_id": "r3", "log_path": "/l"},
    ]}, ensure_ascii=False), encoding="utf-8")
    reg = InstanceRegistry(tmp_path)
    assert reg.get("a", "n1").state == "stopped"
    assert reg.get("a", "n2").state == "running"
    assert reg.get("b", "n1").state == "created"


def test_registry_variables_snapshot(tmp_path):
    """变量快照随实例持久化，set_variables 更新跨进程生效。"""
    reg = InstanceRegistry(tmp_path)
    inst = reg.create("svc", "n1", "run-1", "/data/svc/logs/run-1/svc.log",
                      variables={"A": "1", "B": "9"})
    assert inst.variables == {"A": "1", "B": "9"}
    # 跨进程持久化
    assert InstanceRegistry(tmp_path).get("svc", "n1").variables == {"A": "1", "B": "9"}
    # 更新快照
    reg.set_variables("svc", "n1", {"A": "2", "C": "3"})
    got = InstanceRegistry(tmp_path).get("svc", "n1")
    assert got.variables == {"A": "2", "C": "3"}
    # 启动参数快照：None（旧）/ []（显式空）/ 值 可区分
    reg.create("svc", "n2", "run-2", "/l", args=[])
    assert InstanceRegistry(tmp_path).get("svc", "n2").args == []
    reg.create("svc", "n3", "run-3", "/l", args=["--base", "--x"])
    assert InstanceRegistry(tmp_path).get("svc", "n3").args == ["--base", "--x"]
    reg.set_args("svc", "n3", ["--new"])
    assert InstanceRegistry(tmp_path).get("svc", "n3").args == ["--new"]
    # 旧格式实例（无 variables 字段）加载为空 dict（= 无快照的旧实例）
    import json
    f2 = tmp_path / "data2"
    f2.mkdir()
    (f2 / "instances.json").write_text(json.dumps({"instances": [
        {"service": "old", "node": "n1", "run_id": "r1", "log_path": "/l", "state": "stopped"},
    ]}, ensure_ascii=False), encoding="utf-8")
    assert InstanceRegistry(f2).get("old", "n1").variables == {}


def _start_task(variables=None):
    return Task(id="t1", service="svc", action="start", nodes=["n1"],
                variables=variables or {})


def test_resolve_launch_vars_uses_instance_snapshot(tmp_path):
    """有快照的实例：启动 / 重启原样沿用快照，解析层不改记录。"""
    tm = make_manager(tmp_path)
    tm.instances.create("svc", "n1", "run-1", "/l", variables={"A": "1", "B": "9"})
    svc = tm.store.service("svc")
    variables, snapshot = tm._resolve_launch_vars(_start_task(), svc, "n1")
    assert variables == {"A": "1", "B": "9"}  # 快照原样沿用
    assert snapshot is None                   # 无需更新记录
    # 任务显式携带变量：合并为新快照（由 _launch 在启动成功后落库）
    variables, snapshot = tm._resolve_launch_vars(_start_task({"C": "2"}), svc, "n1")
    assert variables == {"A": "1", "B": "9", "C": "2"}
    assert snapshot == variables


def test_resolve_launch_vars_legacy_and_missing(tmp_path):
    """无快照的旧实例 / 无实例记录：以当前 service 默认变量为基础。"""
    tm = make_manager(tmp_path)
    svc = tm.store.service("svc")
    # 无实例记录（防御路径）
    variables, snapshot = tm._resolve_launch_vars(_start_task(), svc, "n1")
    assert variables == {"A": "1"} and snapshot is None
    # 旧实例（无快照）+ 任务无变量：沿用默认值，不落库
    tm.instances.create("svc", "n1", "run-1", "/l")
    variables, snapshot = tm._resolve_launch_vars(_start_task(), svc, "n1")
    assert variables == {"A": "1"} and snapshot is None
    assert tm.instances.get("svc", "n1").variables == {}
    # 旧实例 + 任务显式携带变量：默认值+新变量，冻结落库后不再受默认值变更影响
    variables, snapshot = tm._resolve_launch_vars(_start_task({"B": "9"}), svc, "n1")
    assert variables == {"A": "1", "B": "9"}
    tm.instances.set_variables("svc", "n1", snapshot)  # 模拟 _launch 启动成功后落库
    svc.variables["A"] = "changed"
    variables, _ = tm._resolve_launch_vars(_start_task(), svc, "n1")
    assert variables == {"A": "1", "B": "9"}


def _start_task_args(args):
    return Task(id="t2", service="svc", action="start", nodes=["n1"], args=args)


def test_resolve_launch_args_snapshot_semantics(tmp_path):
    """有快照：原样沿用；显式传 args 替换快照。"""
    tm = make_manager(tmp_path)
    svc = tm.store.service("svc")
    tm.instances.create("svc", "n1", "run-1", "/l", args=["--base", "--frozen"])
    args, snap = tm._resolve_launch_args(_start_task_args([]), svc, "n1")
    assert args == ["--base", "--frozen"] and snap is None
    args, snap = tm._resolve_launch_args(_start_task_args(["--new"]), svc, "n1")
    assert args == ["--new"] and snap == ["--new"]
    assert tm.instances.get("svc", "n1").args == ["--base", "--frozen"]  # 落库在 _launch


def test_resolve_launch_args_legacy_fallback(tmp_path):
    """旧实例（args=None）：回退静态 args；显式传后冻结，static 变更不再影响。"""
    tm = make_manager(tmp_path)
    svc = tm.store.service("svc")
    tm.instances.create("svc", "n1", "run-1", "/l")   # args=None
    assert tm.instances.get("svc", "n1").args is None
    args, snap = tm._resolve_launch_args(_start_task_args([]), svc, "n1")
    assert args == ["--base"] and snap is None
    args, snap = tm._resolve_launch_args(_start_task_args(["--x"]), svc, "n1")
    assert args == ["--base", "--x"] and snap == args
    tm.instances.set_args("svc", "n1", snap)          # 模拟 _launch 成功落库
    svc.start.args.append("--changed")
    args, _ = tm._resolve_launch_args(_start_task_args([]), svc, "n1")
    assert args == ["--base", "--x"]                   # 冻结后不受静态变更影响


def test_launch_uses_and_persists_snapshot(tmp_path, monkeypatch):
    """_launch：沿用实例快照注入启动命令；显式携带变量时启动成功后落库新快照。"""
    import asyncio

    from webui.backend.config import Node
    from webui.backend.tasks import SubTask

    tm = make_manager(tmp_path)
    node = Node(name="n1", ip="1.1.1.1", username="root", port=22,
                private_key="~/.ssh/id_rsa", connect_timeout=10)
    svc = tm.store.service("svc")
    captured = {}

    async def fake_start(pool, node_, service, run_id, variables, args=None):
        captured["vars"] = variables
        captured["args"] = args
        return {"pid": 42, "log_path": "/l", "uploaded": 0}

    monkeypatch.setattr("webui.backend.tasks.executor.start_service", fake_start)

    tm.instances.create("svc", "n1", "run-1", "/l",
                        variables={"A": "1", "B": "9"}, args=["--base", "--frozen"])
    sub = SubTask(node="n1")
    # 无变量/参数启动：原样沿用快照，记录不变
    asyncio.run(tm._launch(_start_task(), svc, node, "n1", sub, "run-1"))
    assert captured["vars"] == {"A": "1", "B": "9"}
    assert captured["args"] == ["--base", "--frozen"]
    assert tm.instances.get("svc", "n1").variables == {"A": "1", "B": "9"}
    assert tm.instances.get("svc", "n1").args == ["--base", "--frozen"]
    assert sub.pid == 42 and sub.run_id == "run-1"
    # 显式携带变量/参数启动：合并变量、替换参数并落库新快照
    task2 = Task(id="t3", service="svc", action="start", nodes=["n1"],
                 variables={"C": "2"}, args=["--new"])
    asyncio.run(tm._launch(task2, svc, node, "n1", sub, "run-1"))
    assert captured["vars"] == {"A": "1", "B": "9", "C": "2"}
    assert captured["args"] == ["--new"]
    assert tm.instances.get("svc", "n1").variables == {"A": "1", "B": "9", "C": "2"}
    assert tm.instances.get("svc", "n1").args == ["--new"]


def test_create_dirs_command_cleans_stale_pidfile():
    from webui.backend.config import ServiceConfig
    from webui.backend.executor import build_create_dirs_command

    svc = ServiceConfig(name="svc", workspace="/data/svc")
    cmd = build_create_dirs_command(svc, "20261028-120000")
    assert "mkdir -p /data/svc/logs/20261028-120000 /data/svc/run" in cmd
    assert "rm -f /data/svc/run/svc.pid" in cmd


# ------------------------------------------------ 服务删除后的实例操作 ----
def test_instance_config_snapshot_roundtrip(tmp_path):
    """创建实例时冻结停止配置快照，跨进程持久化且可重建 ServiceConfig。"""
    tm = make_manager(tmp_path)
    svc = tm.store.service("svc")
    tm.instances.create("svc", "n1", "run-1", "/l", cfg=svc)
    got = InstanceRegistry(tmp_path).get("svc", "n1")
    assert got.workspace == "/data/svc"
    assert got.log_file == "svc.log"
    assert got.stop_timeout == svc.stop.timeout
    cfg = got.as_service_config()
    assert cfg.name == "svc" and cfg.workspace == "/data/svc"
    assert cfg.start.log == "svc.log"
    assert cfg.stop.script == svc.stop.script


def test_stop_and_delete_allowed_after_service_deleted(tmp_path, monkeypatch):
    """服务删除后：停止/删除用实例快照配置完成；启动被拒绝。"""
    import asyncio
    from webui.backend import executor
    from webui.backend.tasks import SubTask

    tm = make_manager(tmp_path)
    svc = tm.store.service("svc")
    tm.instances.create("svc", "n1", "run-1", "/l", cfg=svc)
    del tm.store.services["svc"]

    service, nodes = tm.validate("svc", "stop", ["n1"], {})
    assert service is None and [n.name for n in nodes] == ["n1"]
    tm.validate("svc", "delete", ["n1"], {})
    with pytest.raises(Exception, match="停止|删除"):
        tm.validate("svc", "start", ["n1"], {})

    captured = {}

    async def fake_status(pool, node, svc_cfg, run_id=None):
        captured["status_cfg"] = svc_cfg
        return executor.ServiceStatus("running", pid=1)

    async def fake_stop(pool, node, svc_cfg, run_id=None, variables=None):
        captured["stop_cfg"] = svc_cfg
        captured["stop_vars"] = variables
        return "stopped"

    monkeypatch.setattr(executor, "service_status", fake_status)
    monkeypatch.setattr(executor, "stop_service", fake_stop)

    # 停止
    sub = SubTask(node="n1")
    asyncio.run(tm._run_subtask(Task(id="t1", service="svc", action="stop", nodes=["n1"]),
                                None, "n1", sub))
    assert sub.status == "success", sub.error
    assert captured["stop_cfg"].workspace == "/data/svc"
    assert captured["stop_cfg"].start.log == "svc.log"
    assert captured["stop_vars"] == {}   # 无变量快照 → 服务已删，无默认值可回退

    # 删除（运行中 → 链接停止 → 注销）
    tm.instances.set_state("svc", "n1", "running")
    sub2 = SubTask(node="n1")
    asyncio.run(tm._run_subtask(Task(id="t2", service="svc", action="delete", nodes=["n1"]),
                                None, "n1", sub2))
    assert sub2.status == "success", sub2.error
    assert tm.instances.get("svc", "n1") is None


def test_stop_legacy_without_snapshot_gives_guidance(tmp_path):
    """无快照旧实例 + 服务已删：拒绝操作并给出手动清理指引。"""
    import asyncio
    from webui.backend.tasks import SubTask

    tm = make_manager(tmp_path)
    tm.instances.create("svc", "n1", "run-1", "/l")   # 无 cfg 快照
    del tm.store.services["svc"]
    sub = SubTask(node="n1")
    asyncio.run(tm._run_subtask(Task(id="t1", service="svc", action="stop", nodes=["n1"]),
                                None, "n1", sub))
    assert sub.status == "failed"
    assert "配置快照" in sub.error


def test_refresh_uses_snapshot_and_backfills(tmp_path, monkeypatch):
    """服务删除后刷新用快照探活；旧实例在服务存在时自动补齐快照。"""
    import asyncio
    from webui.backend import executor

    tm = make_manager(tmp_path)

    async def fake_status(pool, node, svc_cfg, run_id=None):
        return executor.ServiceStatus("running", pid=1)

    monkeypatch.setattr(executor, "service_status", fake_status)

    # 旧实例（无快照）+ 服务存在 → 刷新自动补齐
    tm.instances.create("svc", "n1", "run-1", "/l")
    asyncio.run(tm.instances.refresh(pool=None, store=tm.store))
    assert InstanceRegistry(tmp_path).get("svc", "n1").workspace == "/data/svc"

    # 服务删除 → 用快照探活，状态正常且带提示
    del tm.store.services["svc"]
    out = asyncio.run(tm.instances.refresh(pool=None, store=tm.store))
    row = out[0]
    assert row["status"] == "running"
    assert "已删除" in row["note"]


def test_stop_injects_instance_variable_snapshot(tmp_path, monkeypatch):
    """手动停止注入实例变量快照（与启动/自动清理一致）。"""
    import asyncio
    from webui.backend import executor
    from webui.backend.tasks import SubTask

    tm = make_manager(tmp_path)
    svc = tm.store.service("svc")
    tm.instances.create("svc", "n1", "run-1", "/l",
                        variables={"A": "1", "B": "9"}, cfg=svc)
    captured = {}

    async def fake_status(pool, node, svc_cfg, run_id=None):
        return executor.ServiceStatus("running", pid=1)

    async def fake_stop(pool, node, svc_cfg, run_id=None, variables=None):
        captured["vars"] = variables
        return "stopped"

    monkeypatch.setattr(executor, "service_status", fake_status)
    monkeypatch.setattr(executor, "stop_service", fake_stop)
    sub = SubTask(node="n1")
    asyncio.run(tm._run_subtask(Task(id="t1", service="svc", action="stop", nodes=["n1"]),
                                svc, "n1", sub))
    assert sub.status == "success", sub.error
    assert captured["vars"] == {"A": "1", "B": "9"}


def test_stop_legacy_instance_falls_back_to_service_variables(tmp_path, monkeypatch):
    """旧实例（无变量快照）手动停止回退 service.json 默认变量。"""
    import asyncio
    from webui.backend import executor
    from webui.backend.tasks import SubTask

    tm = make_manager(tmp_path)
    svc = tm.store.service("svc")
    tm.instances.create("svc", "n1", "run-1", "/l", cfg=svc)   # variables={}
    captured = {}

    async def fake_status(pool, node, svc_cfg, run_id=None):
        return executor.ServiceStatus("running", pid=1)

    async def fake_stop(pool, node, svc_cfg, run_id=None, variables=None):
        captured["vars"] = variables
        return "stopped"

    monkeypatch.setattr(executor, "service_status", fake_status)
    monkeypatch.setattr(executor, "stop_service", fake_stop)
    sub = SubTask(node="n1")
    asyncio.run(tm._run_subtask(Task(id="t1", service="svc", action="stop", nodes=["n1"]),
                                svc, "n1", sub))
    assert sub.status == "success", sub.error
    assert captured["vars"] == {"A": "1"}   # service.json 默认变量


def test_refresh_surfaces_deploy_heartbeat(tmp_path, monkeypatch):
    """运行中 + 心跳 DEGRADED/STARTING → 展示 degraded/deploying。"""
    import asyncio
    from webui.backend import executor

    tm = make_manager(tmp_path)
    svc = tm.store.service("svc")
    tm.instances.create("svc", "n1", "run-1", "/l", cfg=svc)
    tm.instances.set_state("svc", "n1", "running")

    for heartbeat, expected in (("DEGRADED", "degraded"), ("STARTING", "deploying"),
                                ("READY", "running"), ("-", "running")):
        async def fake_status(pool, node, svc_cfg, run_id=None, _hb=heartbeat):
            return executor.ServiceStatus("running", pid=1, deploy_state=_hb)
        monkeypatch.setattr(executor, "service_status", fake_status)
        out = asyncio.run(tm.instances.refresh(pool=None, store=tm.store))
        assert out[0]["status"] == expected
