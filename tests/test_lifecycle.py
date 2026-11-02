"""实例生命周期（create/start/stop/restart/delete）模型测试。"""
from __future__ import annotations

from pathlib import Path

import pytest

from backend.config import ACTIONS, ConfigStore
from backend.instances import InstanceRegistry
from backend.tasks import Task, TaskManager


def make_manager(tmp_path: Path) -> TaskManager:
    cluster = tmp_path / "cluster.json"
    cluster.write_text('{"nodes": [{"name": "n1", "ip": "1.1.1.1"}]}', encoding="utf-8")
    svc_dir = tmp_path / "services"
    svc_dir.mkdir()
    d = svc_dir / "svc"
    d.mkdir()
    (d / "service.json").write_text(
        '{"name": "svc", "workspace": "/data/svc"}', encoding="utf-8")
    (d / "start.sh").write_text("#!/bin/bash\ntrue\n", encoding="utf-8")
    store = ConfigStore(cluster_path=cluster, services_dir=svc_dir)
    registry = InstanceRegistry(tmp_path)
    from backend.deploy_history import DeployHistory
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


def test_create_dirs_command_cleans_stale_pidfile():
    from backend.config import ServiceConfig
    from backend.executor import build_create_dirs_command

    svc = ServiceConfig(name="svc", workspace="/data/svc")
    cmd = build_create_dirs_command(svc, "20261028-120000")
    assert "mkdir -p /data/svc/logs/20261028-120000 /data/svc/run" in cmd
    assert "rm -f /data/svc/run/svc.pid" in cmd
