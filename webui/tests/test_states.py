"""实例状态机：reconcile 调和矩阵 + cleanup_display + 操作门禁集合。"""
from __future__ import annotations

from webui.backend.instances import (
    CAN_DELETE,
    CAN_START,
    CAN_STOP,
    TRANSIENT_STATES,
    cleanup_display,
    reconcile,
)


def test_reconcile_transients_win():
    for t in TRANSIENT_STATES:
        assert reconcile(t, "running", None) == t
        assert reconcile(t, "dead", 0) == t
        assert reconcile(t, "nopidfile", None) == t


def test_reconcile_nows_and_edges():
    assert reconcile("running", "nows", None) == "notdeployed"
    assert reconcile("stopped", "nows", None) == "notdeployed"
    assert reconcile("running", "legacy", None) == "legacy"
    assert reconcile("running", "reused", None) == "reused"


def test_reconcile_running_probe():
    # 探活运行（组存活）：任何基础状态显示运行中（含外部重启检测）
    for base in ("created", "stopped", "exited", "running"):
        assert reconcile(base, "running", None) == "running"


def test_reconcile_dead_probe():
    # dead + exit_code 0 → completed；≠0 或无码 → abnormal；stopped 保持
    assert reconcile("running", "dead", 0) == "completed"
    assert reconcile("exited", "dead", 0) == "completed"
    assert reconcile("running", "dead", 7) == "abnormal"
    assert reconcile("exited", "dead", None) == "abnormal"   # 无码 = 被终止
    assert reconcile("stopped", "dead", 7) == "stopped"
    assert reconcile("stopped", "dead", None) == "stopped"


def test_reconcile_nopidfile_probe():
    assert reconcile("created", "nopidfile", None) == "created"
    assert reconcile("stopped", "nopidfile", None) == "stopped"
    assert reconcile("exited", "nopidfile", 0) == "completed"
    assert reconcile("exited", "nopidfile", 3) == "abnormal"
    assert reconcile("running", "nopidfile", None) == "abnormal"  # pid 文件被删


def test_gating_sets():
    from webui.backend.instances import CAN_RESTART
    # deploying/degraded 为心跳派生态，进程存活 → 与 running 同门禁（不可启动）
    assert set(CAN_STOP) == {"running", "abnormal", "completed", "degraded", "deploying"}
    assert set(CAN_START) == {"created", "stopped", "completed", "notdeployed"}
    # 重启 = 链接 停止→启动（running 及心跳派生态）
    assert set(CAN_RESTART) == {"running", "degraded", "deploying"}
    # running / abnormal / degraded / deploying 允许删除（都会链接 停止→删除）
    assert set(CAN_DELETE) == {"created", "stopped", "completed", "notdeployed",
                               "running", "abnormal", "degraded", "deploying"}
    for t in TRANSIENT_STATES:
        assert t not in CAN_STOP and t not in CAN_START and t not in CAN_DELETE
        assert t not in CAN_RESTART


def test_reconcile_deploy_heartbeat():
    # 进程运行中 + 心跳状态 → deploying / degraded；其余一律 running
    for base in ("created", "stopped", "exited", "running"):
        assert reconcile(base, "running", None, "STARTING") == "deploying"
        assert reconcile(base, "running", None, "DEGRADED") == "degraded"
        assert reconcile(base, "running", None, "READY") == "running"
        assert reconcile(base, "running", None, "-") == "running"
        assert reconcile(base, "running", None, None) == "running"
    # 心跳只影响 running 探活；死亡路径仍按退出码判定
    assert reconcile("running", "dead", 0, "DEGRADED") == "completed"
    assert reconcile("running", "dead", 7, "STARTING") == "abnormal"
    assert reconcile("running", "legacy", None, "STARTING") == "legacy"


def test_cleanup_display():
    # 未执行 / 执行中（心跳两态同 running）
    assert cleanup_display("running", "none", None) == "none"
    assert cleanup_display("deploying", "none", None) == "none"
    assert cleanup_display("degraded", "none", None) == "none"
    assert cleanup_display("created", "none", 0) == "none"
    assert cleanup_display("stopping", "none", None) == "running"
    # exited：依节点 cleanup_code
    assert cleanup_display("completed", "none", 0) == "ok"
    assert cleanup_display("abnormal", "none", 3) == "failed:3"
    assert cleanup_display("abnormal", "none", None) == "unclean"  # 被杀未清理
    # stopped：手动结果优先，无记录回落节点文件
    assert cleanup_display("stopped", "ok", 5) == "ok"
    assert cleanup_display("stopped", "failed:3", 0) == "failed:3"
    assert cleanup_display("stopped", "killfail", None) == "killfail"
    assert cleanup_display("stopped", "none", 0) == "ok"
    assert cleanup_display("stopped", "none", None) == "unclean"
