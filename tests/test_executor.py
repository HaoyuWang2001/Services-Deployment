"""executor 命令构建与解析测试（纯函数，不依赖 SSH）。"""
from __future__ import annotations


from backend.config import ServiceConfig
from backend.executor import (
    build_kill_stop_command,
    build_log_read_command,
    build_start_command,
    build_status_command,
    build_stop_script_command,
    parse_archives,
    parse_pid,
    parse_status,
    shell_ws,
)


def make_svc(**over) -> ServiceConfig:
    data = {
        "name": "mooncake-master",
        "workspace": "/data/mooncake/master",
        "start": {"script": "start.sh", "args": ["--port", "237 9"], "log": "master.log"},
        "stop": {"timeout": 5},
        "variables": {"MASTER_PORT": "2379"},
    }
    data.update(over)
    return ServiceConfig(**data)


# ------------------------------------------------------------ start 命令 ----
def test_start_command_structure():
    svc = make_svc()
    cmd = build_start_command(svc, "20261025-120000", {"MASTER_PORT": "2379"})
    assert "cd /data/mooncake/master" in cmd
    assert "mkdir -p logs/20261025-120000 run" in cmd
    assert "> logs/20261025-120000/master.log 2>&1 < /dev/null &" in cmd
    assert "echo $pid > run/mooncake-master.pid" in cmd
    assert "env MASTER_PORT=2379" in cmd
    # 带空格的参数被正确引用
    assert "'237 9'" in cmd
    assert "< /dev/null & pid=$!" in cmd


def test_start_command_tilde_workspace_unquoted():
    svc = make_svc(workspace="~/mc")
    cmd = build_start_command(svc, "r1", {})
    assert "cd ~/mc" in cmd
    assert "cd '~/mc'" not in cmd


def test_start_command_no_env():
    svc = make_svc()
    cmd = build_start_command(svc, "r1", {})
    assert "nohup bash start.sh" in cmd


def test_start_command_special_chars_in_var():
    svc = make_svc()
    cmd = build_start_command(svc, "r1", {"TOKEN": "a b'c"})
    assert "env TOKEN='a b'\"'\"'c'" in cmd


# ------------------------------------------------------------- stop 命令 ----
def test_stop_command_default():
    svc = make_svc()
    cmd = build_kill_stop_command(svc)
    assert "run/mooncake-master.pid" in cmd
    assert "kill -9 $pid" in cmd
    assert "-lt 5" in cmd  # timeout=5 → 循环 5 次


def test_stop_script_command():
    svc = make_svc(stop={"script": "stop.sh", "timeout": 3})
    cmd = build_stop_script_command(svc)
    assert cmd == "cd /data/mooncake/master && bash stop.sh"


def test_status_command():
    cmd = build_status_command(make_svc())
    assert "echo RUNNING $pid" in cmd
    assert "echo NOPIDFILE" in cmd


# -------------------------------------------------------------- 日志命令 ----
def test_log_read_commands():
    svc = make_svc()
    assert build_log_read_command(svc, "r1", "master.log", None) == \
        "cd /data/mooncake/master && cat -- logs/r1/master.log"
    assert build_log_read_command(svc, "r1", "master.log", 200) == \
        "cd /data/mooncake/master && tail -n 200 -- logs/r1/master.log"
    assert build_log_read_command(svc, "r1", "master.log", 50, follow=True) == \
        "cd /data/mooncake/master && tail -F -n 50 -- logs/r1/master.log"


# ---------------------------------------------------------------- 解析 ----
def test_parse_pid():
    assert parse_pid("PID=12345\n") == 12345
    assert parse_pid("some noise\nPID=999") == 999
    assert parse_pid("no pid here") is None


def test_parse_status():
    assert parse_status("RUNNING 123").state == "running"
    assert parse_status("RUNNING 123").pid == 123
    assert parse_status("DEAD 123").state == "dead"
    assert parse_status("NOPIDFILE").state == "nopidfile"
    assert parse_status("NOWS").state == "nows"
    assert parse_status("").state == "unknown"


def test_parse_archives():
    out = "20261025-120000-1/master.log\t2048\n20261025-110000/store.log\t512\nbadline\n"
    archives = parse_archives(out)
    assert list(archives.keys()) == ["20261025-120000-1", "20261025-110000"]
    assert archives["20261025-120000-1"] == [{"file": "master.log", "size": 2048}]


def test_shell_ws():
    assert shell_ws("/data/x") == "/data/x"  # 安全字符集，quote 后不变
    assert shell_ws("/data/my dir") == "'/data/my dir'"  # 防御性引用
    assert shell_ws("~/x") == "~/x"
