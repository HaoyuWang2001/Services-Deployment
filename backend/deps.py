"""FastAPI 依赖注入：从全局上下文获取组件（HTTP 与 WebSocket 通用）。"""
from __future__ import annotations

from .config import ConfigStore
from .context import ctx
from .instances import InstanceRegistry
from .monitors import MonitorStore
from .ssh import SSHPool
from .tasks import TaskManager


def get_store() -> ConfigStore:
    assert ctx.store is not None
    return ctx.store


def get_pool() -> SSHPool:
    assert ctx.pool is not None
    return ctx.pool


def get_instances() -> InstanceRegistry:
    assert ctx.instances is not None
    return ctx.instances


def get_tasks() -> TaskManager:
    assert ctx.task_manager is not None
    return ctx.task_manager


def get_monitors() -> MonitorStore:
    assert ctx.monitors is not None
    return ctx.monitors
