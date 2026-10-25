"""运行实例 API。"""
from __future__ import annotations

from fastapi import APIRouter, Depends

from ..deps import get_instances, get_pool, get_store
from ..instances import InstanceRegistry
from ..ssh import SSHPool
from ..config import ConfigStore

router = APIRouter(prefix="/api/instances", tags=["instances"])


@router.get("")
async def list_instances(registry: InstanceRegistry = Depends(get_instances),
                         pool: SSHPool = Depends(get_pool),
                         store: ConfigStore = Depends(get_store)):
    return {"instances": await registry.refresh(pool, store)}
