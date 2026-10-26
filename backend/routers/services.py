"""服务定义 API：查看、编辑（写回 service.json）、单服务重载。"""
from __future__ import annotations

import json
import logging
from pathlib import Path
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from ..config import ConfigStore, ServiceConfig, save_service_json, validate_service_dir
from ..deps import get_store

log = logging.getLogger("sd.services")

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


def _load_raw(service: ServiceConfig) -> dict:
    path: Path = service.service_dir / "service.json"
    return json.loads(path.read_text(encoding="utf-8"))


def _write_store(store: ConfigStore, cfg: ServiceConfig) -> None:
    store.services[cfg.name] = cfg


class ServiceUpdateRequest(BaseModel):
    """可编辑字段；子对象为部分更新（未提供的键保持原值）。"""
    description: Optional[str] = None
    workspace: Optional[str] = None
    start: Optional[dict] = None   # {script?, args?, log?}
    stop: Optional[dict] = None    # {script?, timeout?}；script 显式传 null 表示清除
    variables: Optional[dict] = None


@router.put("/{name}")
async def update_service(name: str, req: ServiceUpdateRequest,
                         store: ConfigStore = Depends(get_store)):
    try:
        svc = store.service(name)
    except KeyError as e:
        raise HTTPException(status_code=404, detail=str(e)) from e
    try:
        raw = _load_raw(svc)
    except Exception as e:  # noqa: BLE001
        raise HTTPException(status_code=500, detail=f"读取 service.json 失败: {e}") from e

    if req.description is not None:
        raw["description"] = req.description
    if req.workspace is not None:
        raw["workspace"] = req.workspace
    if req.start:
        target = raw.setdefault("start", {})
        for k, v in req.start.items():
            if v is not None:
                target[k] = v
    if req.stop is not None:
        target = raw.setdefault("stop", {})
        for k, v in req.stop.items():
            if k == "script" and v is None:
                target.pop("script", None)
            elif v is not None:
                target[k] = v
    if req.variables is not None:
        raw["variables"] = req.variables

    try:
        cfg = save_service_json(svc.service_dir, raw)
    except Exception as e:  # noqa: BLE001
        raise HTTPException(status_code=400, detail=f"配置未保存：{e}") from e
    _write_store(store, cfg)
    log.info("服务 %s 配置已更新: workspace=%s", name, cfg.workspace)
    return cfg.model_dump(exclude={"service_dir"})


@router.post("/{name}/reload")
async def reload_service(name: str, store: ConfigStore = Depends(get_store)):
    try:
        svc = store.service(name)
    except KeyError as e:
        raise HTTPException(status_code=404, detail=str(e)) from e
    try:
        raw = _load_raw(svc)
        cfg = ServiceConfig(**raw)
        validate_service_dir(cfg, svc.service_dir)
        cfg.service_dir = svc.service_dir
    except Exception as e:  # noqa: BLE001
        raise HTTPException(status_code=400, detail=f"重载失败（保留旧配置）: {e}") from e
    _write_store(store, cfg)
    log.info("服务 %s 配置已从磁盘重载", name)
    return cfg.model_dump(exclude={"service_dir"})
