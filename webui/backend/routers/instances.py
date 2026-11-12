"""运行实例 API。"""
from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from .. import executor
from ..config import ConfigStore
from ..deps import get_instances, get_pool, get_store
from ..instances import TRANSIENT_STATES, InstanceRegistry, reconcile
from ..ssh import SSHPool

router = APIRouter(prefix="/api/instances", tags=["instances"])


class UnlockRequest(BaseModel):
    service: str
    node: str


@router.get("")
async def list_instances(registry: InstanceRegistry = Depends(get_instances),
                         pool: SSHPool = Depends(get_pool),
                         store: ConfigStore = Depends(get_store)):
    return {"instances": await registry.refresh(pool, store)}


@router.post("/unlock")
async def unlock_instance(req: UnlockRequest,
                          registry: InstanceRegistry = Depends(get_instances),
                          pool: SSHPool = Depends(get_pool),
                          store: ConfigStore = Depends(get_store)):
    """手动解除瞬态卡死（starting/stopping/deleting）：按节点实际状态收敛。"""
    inst = registry.get(req.service, req.node)
    if inst is None:
        raise HTTPException(status_code=404, detail=f"实例不存在: {req.service}@{req.node}")
    if inst.state not in TRANSIENT_STATES:
        raise HTTPException(
            status_code=400, detail=f"实例不处于瞬态（当前 {inst.state}），无需解除")
    try:
        node = store.node(req.node)
    except KeyError as e:
        raise HTTPException(status_code=404, detail=str(e)) from e
    try:
        svc = store.service(req.service)
    except KeyError:
        if not inst.workspace:
            raise HTTPException(
                status_code=400,
                detail="服务配置已删除且实例无配置快照，无法探活解除；请在节点上手动清理") from None
        svc = inst.as_service_config()
    try:
        st = await executor.service_status(pool, node, svc, inst.run_id)
    except Exception as e:  # noqa: BLE001
        raise HTTPException(status_code=502, detail=f"探活失败，暂无法解除: {e}") from e
    note = registry.resolve_transient(inst, st.state)
    left = registry.get(req.service, req.node)
    if left is None:
        return {"service": req.service, "node": req.node,
                "resolved": "deleted", "note": note or "删除中卡死已自动补完删除"}
    return {
        "service": req.service, "node": req.node,
        "resolved": reconcile(left.state, st.state, st.exit_code, st.deploy_state),
        "note": note or "",
    }
