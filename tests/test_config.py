"""config 加载与校验测试。"""
from __future__ import annotations

import json
from pathlib import Path

import pytest

from backend.config import ClusterConfig, ServiceConfig, load_cluster, load_services


def _write(tmp_path: Path, name: str, data) -> Path:
    p = tmp_path / name
    p.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
    return p


# ------------------------------------------------------------------ cluster
def test_cluster_defaults_merge(tmp_path):
    p = _write(tmp_path, "cluster.json", {
        "defaults": {"username": "openeuler", "port": 2222, "sudo": True},
        "nodes": [
            {"name": "n1", "ip": "10.0.0.1"},
            {"name": "n2", "ip": "10.0.0.2", "port": 22, "username": "root", "sudo": False},
        ],
    })
    cfg = load_cluster(p)
    resolved = {n.name: n for n in cfg.resolved}
    assert resolved["n1"].username == "openeuler"
    assert resolved["n1"].port == 2222
    assert resolved["n1"].sudo is True       # 继承 defaults
    assert resolved["n2"].port == 22
    assert resolved["n2"].username == "root"
    assert resolved["n2"].sudo is False      # 节点覆盖


def test_cluster_default_config(tmp_path):
    p = _write(tmp_path, "cluster.json", {"nodes": [{"name": "a", "ip": "1.2.3.4"}]})
    n = load_cluster(p).resolved[0]
    assert (n.username, n.port) == ("root", 22)


def test_cluster_duplicate_names(tmp_path):
    p = _write(tmp_path, "cluster.json",
               {"nodes": [{"name": "a", "ip": "1"}, {"name": "a", "ip": "2"}]})
    with pytest.raises(ValueError, match="重复"):
        load_cluster(p)


def test_cluster_bad_json(tmp_path):
    p = tmp_path / "cluster.json"
    p.write_text("{broken", encoding="utf-8")
    with pytest.raises(ValueError, match="JSON"):
        load_cluster(p)


def test_cluster_missing_file(tmp_path):
    with pytest.raises(FileNotFoundError):
        load_cluster(tmp_path / "nope.json")


# ----------------------------------------------------------------- services
def _svc_dir(tmp_path: Path, name: str, data: dict, with_script: bool = True) -> Path:
    d = tmp_path / name
    d.mkdir()
    (d / "service.json").write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
    if with_script:
        (d / "start.sh").write_text("#!/bin/bash\ntrue\n", encoding="utf-8")
    return d


def test_service_minimal(tmp_path):
    _svc_dir(tmp_path, "mooncake-master", {"name": "mooncake-master", "workspace": "/data/mc"})
    services, errors = load_services(tmp_path)
    assert errors == []
    svc = services["mooncake-master"]
    assert svc.start.script == "start.sh"
    assert svc.start.log == "service.log"
    assert svc.stop.script is None
    assert svc.log_path("20260101-000000") == "/data/mc/logs/20260101-000000/service.log"


def test_service_workspace_validation(tmp_path):
    _svc_dir(tmp_path, "s1", {"name": "s1", "workspace": "relative/path"})
    services, errors = load_services(tmp_path)
    assert "s1" not in services
    assert any("workspace" in e["error"] for e in errors)


def test_service_name_mismatch(tmp_path):
    _svc_dir(tmp_path, "dir-a", {"name": "name-b", "workspace": "/data/x"})
    services, errors = load_services(tmp_path)
    assert services == {}
    assert any("不一致" in e["error"] for e in errors)


def test_service_missing_script(tmp_path):
    _svc_dir(tmp_path, "s2", {"name": "s2", "workspace": "/data/x"}, with_script=False)
    services, errors = load_services(tmp_path)
    assert "s2" not in services
    assert any("启动脚本不存在" in e["error"] for e in errors)


def test_service_variables_and_tilde_workspace(tmp_path):
    _svc_dir(tmp_path, "s3", {
        "name": "s3", "workspace": "~/svc3",
        "variables": {"MASTER_PORT": "2379", "bad-name!": "x"},
    })
    services, errors = load_services(tmp_path)
    assert "s3" not in services
    assert any("变量" in e["error"] or "variables" in e["error"] for e in errors)


def test_service_log_filename_validation():
    from pydantic import ValidationError
    with pytest.raises(ValidationError):
        ServiceConfig(name="x", workspace="/data/x",
                      start={"script": "start.sh", "log": "a/b.log"})


def test_clusterconfig_node_lookup():
    cfg = ClusterConfig(nodes=[{"name": "n1", "ip": "1.1.1.1"}])
    assert cfg.node("n1").ip == "1.1.1.1"
    assert cfg.node("nope") is None


# ------------------------------------------------------------ 写回/重载 ----
def test_save_service_json_roundtrip(tmp_path):
    from backend.config import save_service_json
    d = _svc_dir(tmp_path, "svc-w", {"name": "svc-w", "workspace": "/data/a",
                                     "variables": {"K": "1"}})
    raw = json.loads((d / "service.json").read_text(encoding="utf-8"))
    raw["workspace"] = "/data/b"
    raw["start"] = {"script": "start.sh", "args": ["--x"], "log": "svc.log"}
    raw["stop"] = {"script": None, "timeout": 20}
    cfg = save_service_json(d, raw)
    assert cfg.workspace == "/data/b"
    assert cfg.start.args == ["--x"]
    assert cfg.stop.script is None and cfg.stop.timeout == 20
    # 文件真实更新
    data = json.loads((d / "service.json").read_text(encoding="utf-8"))
    assert data["workspace"] == "/data/b"
    assert "script" not in data["stop"]
    # 不残留临时文件
    assert not (d / "service.json.tmp").exists()


def test_save_service_json_invalid_not_written(tmp_path):
    from backend.config import save_service_json
    d = _svc_dir(tmp_path, "svc-bad", {"name": "svc-bad", "workspace": "/data/a"})
    original = (d / "service.json").read_text(encoding="utf-8")
    raw = json.loads(original)
    raw["workspace"] = "not/absolute"
    with pytest.raises(Exception):
        save_service_json(d, raw)
    assert (d / "service.json").read_text(encoding="utf-8") == original


def test_save_service_json_missing_script(tmp_path):
    from backend.config import save_service_json
    d = _svc_dir(tmp_path, "svc-m", {"name": "svc-m", "workspace": "/data/a"})
    raw = json.loads((d / "service.json").read_text(encoding="utf-8"))
    raw["start"] = {"script": "nope.sh"}
    with pytest.raises(ValueError, match="启动脚本不存在"):
        save_service_json(d, raw)


# ------------------------------------------------------------ nodes/hidden ----
def test_service_nodes_and_hidden():
    svc = ServiceConfig(name="s", workspace="/data/x",
                        nodes=["node1", "node4"], hidden=True)
    assert svc.nodes == ["node1", "node4"]
    assert svc.hidden is True
    assert ServiceConfig(name="s", workspace="/data/x").hidden is False
    assert ServiceConfig(name="s", workspace="/data/x").nodes == []


def test_service_allow_duplicate_start_default():
    assert ServiceConfig(name="s", workspace="/data/x").allow_duplicate_start is False
    assert ServiceConfig(name="s", workspace="/data/x",
                         allow_duplicate_start=True).allow_duplicate_start is True


def test_service_nodes_bad_entry():
    with pytest.raises(Exception, match="nodes 条目非法"):
        ServiceConfig(name="s", workspace="/data/x", nodes=["bad node!"])


def test_task_validate_nodes_whitelist_and_hidden(tmp_path):
    from backend.config import ConfigStore
    from backend.tasks import TaskError, TaskManager

    cluster = _write(tmp_path, "cluster.json", {
        "nodes": [{"name": "node1", "ip": "1.1.1.1"},
                  {"name": "node2", "ip": "2.2.2.2"},
                  {"name": "node4", "ip": "4.4.4.4"}],
    })
    svc_dir = tmp_path / "services"
    svc_dir.mkdir()
    for name, extra in [("etcd", {"nodes": ["node4"]}), ("tmpl", {"hidden": True})]:
        _svc_dir(svc_dir, name, {"name": name, "workspace": f"/data/{name}", **extra})
    store = ConfigStore(cluster_path=cluster, services_dir=svc_dir)
    tm = TaskManager(pool=None, store=store, instances=None, data_dir=tmp_path)

    svc, nodes, _ = tm.validate("etcd", "start", ["node4"], {})
    assert [n.name for n in nodes] == ["node4"]

    with pytest.raises(TaskError, match="目标节点"):
        tm.validate("etcd", "start", ["node1"], {})
    with pytest.raises(TaskError, match="模板服务"):
        tm.validate("tmpl", "start", ["node1"], {})
    with pytest.raises(TaskError, match="未知节点"):
        tm.validate("etcd", "start", ["nodeX"], {})
