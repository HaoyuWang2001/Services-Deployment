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
        "defaults": {"username": "openeuler", "port": 2222},
        "nodes": [
            {"name": "n1", "ip": "10.0.0.1"},
            {"name": "n2", "ip": "10.0.0.2", "port": 22, "username": "root"},
        ],
    })
    cfg = load_cluster(p)
    resolved = {n.name: n for n in cfg.resolved}
    assert resolved["n1"].username == "openeuler"
    assert resolved["n1"].port == 2222
    assert resolved["n2"].port == 22
    assert resolved["n2"].username == "root"
    assert resolved["n1"].private_key == "~/.ssh/id_rsa"


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
