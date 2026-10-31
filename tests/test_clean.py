"""服务级清理（clean）相关测试。"""
from __future__ import annotations

import asyncio

import pytest

from backend.deploy_history import DeployHistory
from backend.executor import build_clean_command
from backend.tasks import TaskError
from tests.test_lifecycle import make_manager


def test_deploy_history_roundtrip(tmp_path):
    h = DeployHistory(tmp_path)
    h.record("svc", "n1", "/data/a")
    h.record("svc", "n1", "/data/a")           # 去重
    h.record("svc", "n1", "/data/b")
    h.record("svc", "n2", "/data/a")
    assert h.dirs_for("svc") == {"n1": ["/data/a", "/data/b"], "n2": ["/data/a"]}
    assert h.dirs_for("svc", ["n1"]) == {"n1": ["/data/a", "/data/b"]}
    assert h.dirs_for("other") == {}

    # 持久化
    h2 = DeployHistory(tmp_path)
    assert h2.dirs_for("svc")["n1"] == ["/data/a", "/data/b"]

    # 移除（清理成功后）
    h.remove("svc", "n1", "/data/a")
    assert h.dirs_for("svc") == {"n1": ["/data/b"], "n2": ["/data/a"]}
    h.remove("svc", "n2", "/data/a")
    assert h.dirs_for("svc") == {"n1": ["/data/b"]}
    assert DeployHistory(tmp_path).dirs_for("svc") == {"n1": ["/data/b"]}


def test_build_clean_command_guards():
    cmd = build_clean_command(
        pytest.importorskip("backend.config").ServiceConfig(name="svc", workspace="/data/svc"),
        ["/data/svc", "/data/old"])
    # 命令回显
    assert 'echo "\\$ rm -rf -- /data/svc"' in cmd
    # 三重防护
    assert 'echo "MISSING /data/svc"' in cmd
    assert "缺少 logs/run 标记" in cmd
    assert "REFUSE /data/svc" in cmd
    assert "仍有存活进程 PID" in cmd
    # pid 文件按服务名检查
    assert "/run/svc.pid" in cmd
    # ~/ 形式不加引号（保持展开）
    cmd2 = build_clean_command(
        pytest.importorskip("backend.config").ServiceConfig(name="svc", workspace="~/s"),
        ["~/s"])
    assert "[ ! -d ~/s ]" in cmd2


def _run(coro):
    return asyncio.run(coro)


def test_clean_rejected_when_instance_exists(tmp_path):
    tm = make_manager(tmp_path)
    tm.instances.create("svc", "n1", "run-1", "/data/svc/logs/run-1/svc.log")

    async def scenario():
        task = await tm.create("svc", "clean", ["n1"])
        await asyncio.sleep(0.2)   # 等子任务失败
        return task.id

    tid = _run(scenario())
    task = tm.get(tid)
    assert task.status == "failed"
    assert "请先「删除」实例" in task.subtasks[0].error


def test_clean_paths_validation(tmp_path):
    tm = make_manager(tmp_path)

    async def bad():
        await tm.create("svc", "clean", ["n1"], paths=["relative/bad"])

    with pytest.raises(TaskError, match="补录路径非法"):
        _run(bad())

    async def good():
        return await tm.create("svc", "clean", ["n1"], paths=["/data/old", "~/old"])

    task = _run(good())
    assert task.paths == ["/data/old", "~/old"]
