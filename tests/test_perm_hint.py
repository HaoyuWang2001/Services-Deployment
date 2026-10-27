"""权限错误提示测试。"""
from __future__ import annotations

from backend.deployer import perm_hint


def test_perm_hint_on_permission_errors():
    for err in ("mkdir: cannot create directory '/x': Permission denied",
                "open /x: failure",
                "Read-only file system",
                "SFTPError: Permission denied"):
        assert "chown -R" in perm_hint(err), err


def test_perm_hint_ignores_other_errors():
    assert perm_hint("command not found") == ""
    assert perm_hint("No such file or directory") == ""
    assert perm_hint("") == ""
