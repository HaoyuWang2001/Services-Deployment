"""全局组件上下文：由 main.lifespan 初始化，供 HTTP 与 WebSocket 依赖共用。"""
from __future__ import annotations

from typing import Optional

from .config import ConfigStore
from .deploy_history import DeployHistory
from .instances import InstanceRegistry
from .monitors import MonitorStore
from .ssh import SSHPool
from .tasks import TaskManager


class AppContext:
    store: Optional[ConfigStore] = None
    pool: Optional[SSHPool] = None
    instances: Optional[InstanceRegistry] = None
    task_manager: Optional[TaskManager] = None
    monitors: Optional[MonitorStore] = None
    history: Optional[DeployHistory] = None


ctx = AppContext()
