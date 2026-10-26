"""集群管理 API。"""
from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException

from .. import executor
from ..config import ConfigStore
from ..deps import get_pool, get_store
from ..ssh import SSHPool, SSHError

router = APIRouter(prefix="/api/cluster", tags=["cluster"])


@router.get("/nodes")
async def list_nodes(store: ConfigStore = Depends(get_store)):
    return {
        "nodes": [n.model_dump() for n in store.cluster.resolved],
        "error": store.cluster_error,
    }


@router.post("/nodes/{name}/test")
async def test_node(name: str, store: ConfigStore = Depends(get_store),
                    pool: SSHPool = Depends(get_pool)):
    try:
        node = store.node(name)
    except KeyError as e:
        raise HTTPException(status_code=404, detail=str(e)) from e
    try:
        res = await pool.run(node, "echo SDOK; uname -s -m; pwd", timeout=15)
    except SSHError as e:
        return {"ok": False, "detail": str(e)}
    if not res.ok:
        return {"ok": False, "detail": f"命令执行失败(exit={res.exit_code}): {res.stderr.strip()[:300]}"}
    lines = [l.strip() for l in res.stdout.splitlines() if l.strip()]
    info = [l for l in lines if l != "SDOK"]
    return {
        "ok": True,
        "detail": "连接正常",
        "kernel": info[0] if len(info) > 0 else "",
        "arch": info[0].split()[-1] if len(info) > 0 else "",
        "home": info[1] if len(info) > 1 else "",
    }


@router.get("/nodes/{name}/ports")
async def node_ports(name: str, store: ConfigStore = Depends(get_store),
                     pool: SSHPool = Depends(get_pool)):
    """查询节点监听端口及占用进程（ss -tulnpH）。"""
    try:
        node = store.node(name)
    except KeyError as e:
        raise HTTPException(status_code=404, detail=str(e)) from e
    try:
        ports = await executor.list_ports(pool, node)
    except (SSHError, executor.ExecError) as e:
        return {"ok": False, "detail": str(e), "ports": [], "warning": None}
    warning = None
    if ports and not any(p["processes"] for p in ports):
        warning = ("未获取到进程信息：SSH 用户非 root 且未启用 sudo"
                   "（可在 cluster.json 中为该节点配置 sudo: true）")
    return {"ok": True, "ports": ports, "warning": warning, "detail": None}


@router.post("/reload")
async def reload_config(store: ConfigStore = Depends(get_store)):
    store.reload()
    return {
        "nodes": len(store.cluster.nodes),
        "services": sorted(store.services.keys()),
        "cluster_error": store.cluster_error,
        "service_errors": store.service_errors,
    }
