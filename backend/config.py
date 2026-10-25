"""Configuration loading & validation: cluster.json + services/*/service.json."""
from __future__ import annotations

import json
import logging
import os
import re
from pathlib import Path
from typing import Optional

from pydantic import BaseModel, Field, field_validator, model_validator

log = logging.getLogger("sd.config")

REPO_ROOT = Path(__file__).resolve().parent.parent

CLUSTER_JSON = Path(os.environ.get("CLUSTER_JSON") or REPO_ROOT / "cluster.json")
SERVICES_DIR = Path(os.environ.get("SERVICES_DIR") or REPO_ROOT / "services")
DATA_DIR = Path(os.environ.get("DATA_DIR") or REPO_ROOT / "data")

# 路径安全片段：目录名 / run_id / 日志文件名
TOKEN_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
# 服务内相对路径（脚本等）
REL_PATH_RE = re.compile(r"^[A-Za-z0-9._][A-Za-z0-9._/-]*$")
# workspace：绝对路径或 ~ / ~/xxx，仅允许字母数字 ._-
WORKSPACE_RE = re.compile(r"^(?:~(?:/[A-Za-z0-9._-]+)*/?|/[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)*/?)$")
ENV_NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")

ACTIONS = ("deploy", "start", "stop", "restart")


# ---------------------------------------------------------------- cluster ----
class ClusterDefaults(BaseModel):
    username: str = "root"
    port: int = Field(default=22, ge=1, le=65535)
    private_key: str = "~/.ssh/id_rsa"
    connect_timeout: float = Field(default=10.0, gt=0, le=120)


class NodeSpec(BaseModel):
    """cluster.json 中原始节点定义，未设置的字段继承 defaults。"""
    name: str
    ip: str = Field(min_length=1)
    username: Optional[str] = None
    port: Optional[int] = Field(default=None, ge=1, le=65535)
    private_key: Optional[str] = None
    connect_timeout: Optional[float] = Field(default=None, gt=0, le=120)

    @field_validator("name")
    @classmethod
    def _check_name(cls, v: str) -> str:
        if not TOKEN_RE.match(v):
            raise ValueError(f"节点名称非法: {v!r}（仅允许字母数字._-，且以字母数字开头）")
        return v


class Node(BaseModel):
    """合并 defaults 后的完整节点。"""
    name: str
    ip: str
    username: str
    port: int
    private_key: str
    connect_timeout: float


class ClusterConfig(BaseModel):
    defaults: ClusterDefaults = Field(default_factory=ClusterDefaults)
    nodes: list[NodeSpec] = Field(default_factory=list)

    @property
    def resolved(self) -> list[Node]:
        d = self.defaults
        return [
            Node(
                name=n.name,
                ip=n.ip,
                username=n.username or d.username,
                port=n.port if n.port is not None else d.port,
                private_key=n.private_key or d.private_key,
                connect_timeout=n.connect_timeout or d.connect_timeout,
            )
            for n in self.nodes
        ]

    def node(self, name: str) -> Optional[Node]:
        for n in self.resolved:
            if n.name == name:
                return n
        return None


def load_cluster(path: Path) -> ClusterConfig:
    if not path.is_file():
        if path.parent != path and (path.parent / "cluster.example.json").is_file():
            hint = "（请先复制 cluster.example.json 为 cluster.json 并按实际环境修改）"
        else:
            hint = ""
        raise FileNotFoundError(f"cluster.json 不存在: {path}{hint}")
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        raise ValueError(f"cluster.json 不是合法 JSON: {e}") from e
    if not isinstance(data, dict):
        raise ValueError("cluster.json 顶层必须是 JSON 对象")
    cfg = ClusterConfig(defaults=ClusterDefaults(**(data.get("defaults") or {})))
    raw_nodes = data.get("nodes", [])
    if not isinstance(raw_nodes, list):
        raise ValueError('"nodes" 必须是数组')
    from pydantic import ValidationError
    try:
        cfg.nodes = [NodeSpec(**n) for n in raw_nodes if isinstance(n, dict)]
    except ValidationError as e:
        raise ValueError(f"节点配置无效: {e}") from e
    names = [n.name for n in cfg.nodes]
    dups = sorted({x for x in names if names.count(x) > 1})
    if dups:
        raise ValueError(f"节点名称重复: {dups}")
    return cfg


# --------------------------------------------------------------- services ----
class StartSpec(BaseModel):
    script: str = "start.sh"
    args: list[str] = Field(default_factory=list)
    log: str = "service.log"

    @field_validator("script")
    @classmethod
    def _check_script(cls, v: str) -> str:
        if v.startswith("/") or ".." in v or not REL_PATH_RE.match(v):
            raise ValueError(f"start.script 非法: {v!r}（须为服务目录内的相对路径）")
        return v

    @field_validator("log")
    @classmethod
    def _check_log(cls, v: str) -> str:
        if not TOKEN_RE.match(v):
            raise ValueError(f"start.log 非法: {v!r}（须为文件名，不能包含路径分隔符）")
        return v


class StopSpec(BaseModel):
    script: Optional[str] = None
    timeout: float = Field(default=10.0, gt=0, le=300)

    @field_validator("script")
    @classmethod
    def _check_script(cls, v: Optional[str]) -> Optional[str]:
        if v is None:
            return v
        if v.startswith("/") or ".." in v or not REL_PATH_RE.match(v):
            raise ValueError(f"stop.script 非法: {v!r}（须为服务目录内的相对路径）")
        return v


class DeploySpec(BaseModel):
    files: Optional[list[str]] = None


class ServiceConfig(BaseModel):
    name: str
    description: str = ""
    workspace: str
    start: StartSpec = Field(default_factory=StartSpec)
    stop: StopSpec = Field(default_factory=StopSpec)
    deploy: DeploySpec = Field(default_factory=DeploySpec)
    variables: dict[str, str] = Field(default_factory=dict)
    service_dir: Optional[Path] = Field(default=None, exclude=True)

    @field_validator("name")
    @classmethod
    def _check_name(cls, v: str) -> str:
        if not TOKEN_RE.match(v):
            raise ValueError(f"服务名称非法: {v!r}")
        return v

    @field_validator("workspace")
    @classmethod
    def _check_workspace(cls, v: str) -> str:
        v = v.strip()
        if not v or not WORKSPACE_RE.match(v):
            raise ValueError(
                f"workspace 非法: {v!r}（须为绝对路径或 ~/ 开头，仅允许字母数字与 ._- ）"
            )
        return v

    @model_validator(mode="after")
    def _check_variables(self) -> "ServiceConfig":
        for k in self.variables:
            if not ENV_NAME_RE.match(k):
                raise ValueError(f"variables 键名非法: {k!r}（须为合法环境变量名）")
        return self

    def log_path(self, run_id: str) -> str:
        return f"{self.workspace}/logs/{run_id}/{self.start.log}"


def load_services(services_dir: Path) -> tuple[dict[str, ServiceConfig], list[dict]]:
    """扫描 services/ 下所有子目录，返回 (服务表, 错误列表)。"""
    services: dict[str, ServiceConfig] = {}
    errors: list[dict] = []
    if not services_dir.is_dir():
        return services, errors
    for sub in sorted(services_dir.iterdir()):
        if not sub.is_dir() or sub.name.startswith("."):
            continue
        sj = sub / "service.json"
        if not sj.is_file():
            errors.append({"service": sub.name, "error": "缺少 service.json"})
            continue
        try:
            cfg = ServiceConfig(**json.loads(sj.read_text(encoding="utf-8")))
        except Exception as e:  # noqa: BLE001
            errors.append({"service": sub.name, "error": f"service.json 解析失败: {e}"})
            continue
        if cfg.name != sub.name:
            errors.append({"service": sub.name, "error": f"name={cfg.name!r} 与目录名 {sub.name!r} 不一致"})
            continue
        if not (sub / cfg.start.script).is_file():
            errors.append({"service": sub.name, "error": f"启动脚本不存在: {cfg.start.script}"})
            continue
        if cfg.stop.script and not (sub / cfg.stop.script).is_file():
            errors.append({"service": sub.name, "error": f"停止脚本不存在: {cfg.stop.script}"})
            continue
        cfg.service_dir = sub
        services[cfg.name] = cfg
    return services, errors


# ------------------------------------------------------------------ store ----
class ConfigStore:
    """持有集群与服务配置，支持热重载。"""

    def __init__(self, cluster_path: Path = CLUSTER_JSON, services_dir: Path = SERVICES_DIR) -> None:
        self.cluster_path = cluster_path
        self.services_dir = services_dir
        self.cluster = ClusterConfig()
        self.cluster_error: Optional[str] = None
        self.services: dict[str, ServiceConfig] = {}
        self.service_errors: list[dict] = []
        self.reload()

    def reload(self) -> None:
        try:
            self.cluster = load_cluster(self.cluster_path)
            self.cluster_error = None
        except Exception as e:  # noqa: BLE001
            self.cluster = ClusterConfig()
            self.cluster_error = str(e)
            log.warning("cluster.json 加载失败: %s", e)
        self.services, self.service_errors = load_services(self.services_dir)
        log.info("配置已加载: %d 节点, %d 服务, %d 服务错误",
                 len(self.cluster.nodes), len(self.services), len(self.service_errors))

    def node(self, name: str) -> Node:
        node = self.cluster.node(name)
        if node is None:
            raise KeyError(f"未知节点: {name}")
        return node

    def service(self, name: str) -> ServiceConfig:
        svc = self.services.get(name)
        if svc is None:
            raise KeyError(f"未知服务: {name}")
        return svc
