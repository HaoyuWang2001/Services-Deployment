"""监控项存储与命令构建测试。"""
from __future__ import annotations

import pytest

from backend.monitors import MonitorStore
from backend.routers.monitors import MAX_STDOUT, _trim, build_monitor_command


def test_monitor_store_crud_roundtrip(tmp_path):
    store = MonitorStore(tmp_path)
    m = store.create("磁盘", "df -h", 5)
    assert [x.name for x in store.list()] == ["磁盘"]
    assert m.interval == 5

    # 持久化：新实例可见
    store2 = MonitorStore(tmp_path)
    assert [x.id for x in store2.list()] == [m.id]

    updated = store.update(m.id, cmd="df -h /data", interval=10)
    assert updated.cmd == "df -h /data" and updated.interval == 10
    assert MonitorStore(tmp_path).list()[0].interval == 10  # 重新加载可见更新

    assert store.delete(m.id) is True
    assert store.delete(m.id) is False
    assert MonitorStore(tmp_path).list() == []


def test_monitor_store_duplicate_name(tmp_path):
    store = MonitorStore(tmp_path)
    store.create("dup", "uptime", 2)
    with pytest.raises(ValueError, match="已存在"):
        store.create("dup", "free -m", 2)
    # 更新为其他项的名称同样拒绝
    other = store.create("ok", "uptime", 2)
    with pytest.raises(ValueError, match="已存在"):
        store.update(other.id, name="dup")


def test_monitor_update_missing_id(tmp_path):
    store = MonitorStore(tmp_path)
    with pytest.raises(KeyError):
        store.update("nope", cmd="x")


def test_monitor_field_validation(tmp_path):
    from backend.monitors import Monitor
    store = MonitorStore(tmp_path)
    with pytest.raises(ValueError, match="名称"):
        store.create("", "x", 2)
    with pytest.raises(ValueError, match="命令"):
        store.create("n", "", 2)
    with pytest.raises(ValueError, match="换行"):
        store.create("n", "echo a\necho b", 2)
    with pytest.raises(Exception):
        Monitor(id="x", name="n", cmd="x", interval=0)   # interval 下界
    with pytest.raises(Exception):
        Monitor(id="x", name="n", cmd="x", interval=61)  # interval 上界


def test_build_monitor_command_sudo_rewrite():
    assert build_monitor_command("sudo whoami") == "sudo -n whoami"
    assert build_monitor_command("  sudo dmidecode -t memory") == "  sudo -n dmidecode -t memory"
    assert build_monitor_command("sudo") == "sudo -n"
    # 非 sudo 命令原样保留；嵌入的 sudo 不受影响
    assert build_monitor_command("df -h") == "df -h"
    assert build_monitor_command("echo sudo x") == "echo sudo x"
    assert build_monitor_command("watch sudo x") == "watch sudo x"


def test_trim():
    short = "x" * 100
    assert _trim(short, MAX_STDOUT) == short
    long_text = "y" * (MAX_STDOUT + 500)
    trimmed = _trim(long_text, MAX_STDOUT)
    assert len(trimmed) < len(long_text)
    assert "已截断" in trimmed
