"""任务 API：创建 deploy/start/stop/restart 任务并查询进度。"""
from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from ..deps import get_tasks
from ..tasks import TaskError, TaskManager

router = APIRouter(prefix="/api/tasks", tags=["tasks"])


class TaskCreateRequest(BaseModel):
    service: str
    action: str  # deploy | start | stop | restart
    nodes: list[str] = Field(min_length=1)
    variables: dict[str, str] = Field(default_factory=dict)


@router.post("", status_code=202)
async def create_task(req: TaskCreateRequest, tm: TaskManager = Depends(get_tasks)):
    try:
        task = await tm.create(req.service, req.action, req.nodes, req.variables)
    except TaskError as e:
        raise HTTPException(status_code=400, detail=str(e)) from e
    return task.model_dump()


@router.get("")
async def list_tasks(limit: int = 50, tm: TaskManager = Depends(get_tasks)):
    limit = max(1, min(limit, 300))
    return {"tasks": [t.summary() for t in tm.list(limit)]}


@router.get("/{task_id}")
async def get_task(task_id: str, tm: TaskManager = Depends(get_tasks)):
    task = tm.get(task_id)
    if task is None:
        raise HTTPException(status_code=404, detail=f"任务不存在: {task_id}")
    return task.model_dump()
