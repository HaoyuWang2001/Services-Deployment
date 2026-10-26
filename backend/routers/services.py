"""服务定义 API：查看、新建（克隆模板）、编辑（写回 service.json）、重载。"""
from __future__ import annotations

import json
import logging
import shutil
from pathlib import Path
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from ..config import (TOKEN_RE, ConfigStore, ServiceConfig,
                      save_service_json, validate_service_dir)
from ..deps import get_store

log = logging.getLogger("sd.services")

router = APIRouter(prefix="/api/services", tags=["services"])

TEMPLATE_NAME = "example"


@router.get("")
async def list_services(store: ConfigStore = Depends(get_store)):
    return {
        "services": [svc.model_dump(exclude={"service_dir"}) for svc in
                     sorted(store.services.values(), key=lambda s: s.name)
                     if not svc.hidden],
        "errors": [e for e in store.service_errors if e["service"] != TEMPLATE_NAME],
    }


@router.post("/reload")
async def reload_services(store: ConfigStore = Depends(get_store)):
    """全量重扫 services/ 目录（新增/删除/外部修改 service.json 后调用）。"""
    store.reload()
    return await list_services(store)


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


# ------------------------------------------------------------------ 新建 ----
class ServiceCreateRequest(BaseModel):
    name: str


@router.post("", status_code=201)
async def create_service(req: ServiceCreateRequest, store: ConfigStore = Depends(get_store)):
    name = req.name.strip()
    if not TOKEN_RE.match(name):
        raise HTTPException(status_code=400,
                            detail=f"服务名非法: {name!r}（仅允许字母数字._-，且以字母数字开头）")
    if name in store.services or name == TEMPLATE_NAME:
        raise HTTPException(status_code=400, detail=f"服务已存在: {name}")
    target: Path = store.services_dir / name
    if target.exists():
        raise HTTPException(status_code=400, detail=f"目录已存在: {target}")

    template: Path = store.services_dir / TEMPLATE_NAME
    if template.is_dir():
        shutil.copytree(template, target)
        raw = json.loads((target / "service.json").read_text(encoding="utf-8"))
    else:
        target.mkdir(parents=True)
        raw = {"name": name, "workspace": f"/data/services/{name}",
               "start": {"script": "start.sh", "args": [], "log": "service.log"}}
        script = target / raw["start"]["script"]
        if not script.exists():
            script.write_text("#!/usr/bin/env bash\nexec tail -f /dev/null\n", encoding="utf-8")

    raw["name"] = name
    raw.pop("hidden", None)
    raw["workspace"] = f"/data/services/{name}"
    raw["description"] = ""
    try:
        cfg = save_service_json(target, raw)
    except Exception as e:  # noqa: BLE001
        shutil.rmtree(target, ignore_errors=True)
        raise HTTPException(status_code=500, detail=f"克隆模板失败: {e}") from e
    _write_store(store, cfg)
    log.info("已从模板创建服务 %s → %s", name, target)
    return cfg.model_dump(exclude={"service_dir"})


# ------------------------------------------------------------------ 编辑 ----
class ServiceUpdateRequest(BaseModel):
    """可编辑字段；子对象为部分更新（未提供的键保持原值）。"""
    description: Optional[str] = None
    workspace: Optional[str] = None
    nodes: Optional[list[str]] = None   # 提供即整体替换；[] = 清空白名单(全部节点)
    start: Optional[dict] = None        # {script?, args?, log?}
    stop: Optional[dict] = None         # {script?, timeout?}；script 显式传 null 表示清除
    variables: Optional[dict] = None


@router.put("/{name}")
async def update_service(name: str, req: ServiceUpdateRequest,
                         store: ConfigStore = Depends(get_store)):
    try:
        svc = store.service(name)
    except KeyError as e:
        raise HTTPException(status_code=404, detail=str(e)) from e
    if svc.hidden:
        raise HTTPException(status_code=400, detail=f"{name} 是模板服务，不可编辑；请先克隆为新服务")
    try:
        raw = _load_raw(svc)
    except Exception as e:  # noqa: BLE001
        raise HTTPException(status_code=500, detail=f"读取 service.json 失败: {e}") from e

    if req.description is not None:
        raw["description"] = req.description
    if req.workspace is not None:
        raw["workspace"] = req.workspace
    if req.nodes is not None:
        raw["nodes"] = req.nodes
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
    log.info("服务 %s 配置已更新: workspace=%s nodes=%s", name, cfg.workspace, cfg.nodes or "全部")
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
