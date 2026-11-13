"""文件下发：服务目录 → 节点 workspace（SFTP 递归上传）。"""
from __future__ import annotations

import logging
import posixpath
import shlex
from pathlib import Path

import asyncssh

from .config import Node, ServiceConfig
from .ssh import SSHPool

log = logging.getLogger("sd.deploy")


class DeployError(RuntimeError):
    pass


_PERM_MARKS = ("denied", "permission", "read-only", "failure")


def perm_hint(err_text: str) -> str:
    """错误文本含权限特征时返回修复提示。"""
    low = (err_text or "").lower()
    if any(m in low for m in _PERM_MARKS):
        return ("；常见原因：workspace 目录属主与 SSH 登录用户不一致，"
                "可在节点执行 chown -R <ssh用户> <workspace> 修复")
    return ""


def _is_hidden(rel: Path) -> bool:
    return any(part.startswith(".") for part in rel.parts)


def resolve_deploy_files(service: ServiceConfig) -> list[Path]:
    """返回需要下发的本地文件列表（相对服务目录），隐藏文件与 service.json 除外。"""
    service_dir = service.service_dir
    assert service_dir is not None
    if service.deploy.files:
        picked: set[Path] = set()
        for pattern in service.deploy.files:
            matches = sorted(service_dir.glob(pattern))
            if not matches:
                raise DeployError(f"deploy.files 模式无匹配: {pattern!r}")
            root = service_dir.resolve()
            for m in matches:
                real = m.resolve()
                if real != root and root not in real.parents:
                    raise DeployError(f"deploy.files 模式越界: {pattern!r}")
                if m.is_dir():
                    picked.update(p for p in m.rglob("*") if p.is_file())
                elif m.is_file():
                    picked.add(m)
        files = sorted(picked)
    else:
        files = sorted(p for p in service_dir.rglob("*") if p.is_file())
    result = []
    for f in files:
        rel = f.relative_to(service_dir)
        if rel.as_posix() == "service.json" or _is_hidden(rel):
            continue
        result.append(f)
    return result


async def _sftp_mkdirs(sftp: asyncssh.SFTPClient, remote_dir: str) -> None:
    cur = ""
    for part in remote_dir.strip("/").split("/"):
        cur += "/" + part
        try:
            await sftp.stat(cur)
        except asyncssh.SFTPError:
            try:
                await sftp.mkdir(cur)
            except asyncssh.SFTPError as e:
                raise DeployError(f"创建远程目录失败 {cur}: {e}") from e


_ws_cache: dict[tuple[str, str], str] = {}


async def resolve_workspace(pool: SSHPool, node: Node, workspace: str) -> str:
    """把 ~/xxx 形式的 workspace 解析为节点上的绝对路径（带缓存）。"""
    if not workspace.startswith("~"):
        return workspace
    key = (node.name, workspace)
    if key in _ws_cache:
        return _ws_cache[key]
    res = await pool.run(node, f"printf %s {shlex.quote(workspace)}", timeout=15)
    if not res.ok or not res.stdout.startswith("/"):
        raise DeployError(f"无法在 {node.name} 上解析 workspace 路径 {workspace}")
    _ws_cache[key] = res.stdout
    return res.stdout


async def deploy_service(pool: SSHPool, node: Node, service: ServiceConfig) -> int:
    """上传服务文件到节点 workspace 根目录，返回文件数。"""
    files = resolve_deploy_files(service)
    ws = await resolve_workspace(pool, node, service.workspace)
    sftp = await pool.sftp(node)
    try:
        count = 0
        for local in files:
            rel = local.relative_to(service.service_dir).as_posix()
            remote = posixpath.join(ws, rel)
            await _sftp_mkdirs(sftp, posixpath.dirname(remote))
            try:
                await sftp.put(str(local), remote)
                if (local.stat().st_mode & 0o111) or local.suffix == ".sh":
                    await sftp.chmod(remote, 0o755)
            except (asyncssh.SFTPError, OSError) as e:
                raise DeployError(f"上传 {rel} 失败: {e}{perm_hint(str(e))}") from e
            count += 1
    finally:
        sftp.exit()
    log.info("已向 %s 下发服务 %s：%d 个文件 → %s", node.name, service.name, len(files), ws)
    return len(files)
