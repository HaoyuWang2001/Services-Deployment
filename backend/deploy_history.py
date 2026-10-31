"""部署历史：记录每个 (服务, 节点) 曾部署过的全部 workspace 路径。

用于服务级清理操作：更换 workspace 后旧目录仍可被发现并清理，
避免"永远得不到清理"的孤儿目录。
"""
from __future__ import annotations

import json
import logging
from pathlib import Path

log = logging.getLogger("sd.history")


class DeployHistory:
    def __init__(self, data_dir: Path) -> None:
        self._file = data_dir / "deploy_history.json"
        # service -> node -> [workspace, ...]（保持登记顺序，去重）
        self._items: dict[str, dict[str, list[str]]] = {}
        self._load()

    def _load(self) -> None:
        if not self._file.is_file():
            return
        try:
            data = json.loads(self._file.read_text(encoding="utf-8"))
            self._items = {
                svc: {node: list(dirs) for node, dirs in nodes.items()}
                for svc, nodes in data.get("history", {}).items()
            }
        except Exception as e:  # noqa: BLE001
            log.warning("deploy_history.json 加载失败(将重建): %s", e)

    def _save(self) -> None:
        self._file.parent.mkdir(parents=True, exist_ok=True)
        tmp = self._file.with_suffix(".json.tmp")
        tmp.write_text(
            json.dumps({"history": self._items}, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        tmp.replace(self._file)

    def record(self, service: str, node: str, workspace: str) -> None:
        node_map = self._items.setdefault(service, {})
        dirs = node_map.setdefault(node, [])
        if workspace in dirs:
            return
        dirs.append(workspace)
        self._save()

    def dirs_for(self, service: str, nodes: list[str] | None = None) -> dict[str, list[str]]:
        """返回 {node: [目录...]}；nodes 提供时仅返回指定节点。"""
        node_map = self._items.get(service, {})
        if nodes is None:
            return {n: list(d) for n, d in node_map.items()}
        return {n: list(node_map[n]) for n in nodes if n in node_map}

    def remove(self, service: str, node: str, workspace: str) -> None:
        node_map = self._items.get(service)
        if not node_map or node not in node_map:
            return
        node_map[node] = [d for d in node_map[node] if d != workspace]
        if not node_map[node]:
            node_map.pop(node)
        if not node_map:
            self._items.pop(service, None)
        self._save()
