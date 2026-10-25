"""服务定义 API。"""
from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException

from ..config import ConfigStore
from ..deps import get_store

router = APIRouter(prefix="/api/services", tags=["services"])


@router.get("")
async def list_services(store: ConfigStore = Depends(get_store)):
    return {
        "services": [svc.model_dump(exclude={"service_dir"}) for svc in
                     sorted(store.services.values(), key=lambda s: s.name)],
        "errors": store.service_errors,
    }


@router.get("/{name}")
async def get_service(name: str, store: ConfigStore = Depends(get_store)):
    try:
        svc = store.service(name)
    except KeyError as e:
        raise HTTPException(status_code=404, detail=str(e)) from e
    return svc.model_dump(exclude={"service_dir"})
