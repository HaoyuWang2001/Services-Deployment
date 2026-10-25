"""远程命令构建与执行：启动 / 停止 / 状态 / 日志。

设计原则：
- 启动不做成功性判定，只要 nohup 派发成功、拿到 PID 即成功；
- 每次启动的日志写入独立目录 logs/<run_id>/，结构上杜绝覆盖与续写。
"""
from __future__ import annotations

import re
import shlex
from dataclasses import dataclass
from typing import Optional

from .config import Node, ServiceConfig
from .ssh import SSHPool, SSHError


class ExecError(RuntimeError):
    pass


def shell_ws(workspace: str) -> str:
    """workspace 字符集在配置加载时已严格校验（字母数字 ._-/ 与可选前导 ~），
    ~/ 形式不能加引号（需要 shell 展开），其余加引号。"""
    if workspace.startswith("~"):
        return workspace
    return shlex.quote(workspace)


# ------------------------------------------------------------- 命令构建 ----
def build_start_command(service: ServiceConfig, run_id: str, variables: dict[str, str]) -> str:
    ws = shell_ws(service.workspace)
    script = shlex.quote(service.start.script)
    args = " ".join(shlex.quote(a) for a in service.start.args)
    env = ""
    if variables:
        env = "env " + " ".join(f"{k}={shlex.quote(str(v))}" for k, v in variables.items()) + " "
    logdir = f"logs/{run_id}"
    logfile = f"{logdir}/{service.start.log}"
    pidfile = f"run/{service.name}.pid"
    return (
        f"cd {ws} && mkdir -p {shlex.quote(logdir)} run && "
        f"{{ nohup {env}bash {script}"
        + (f" {args}" if args else "")
        + f" > {shlex.quote(logfile)} 2>&1 < /dev/null & pid=$!; "
        f"echo $pid > {pidfile}; echo PID=$pid; }}"
    )


def build_kill_stop_command(service: ServiceConfig) -> str:
    ws = shell_ws(service.workspace)
    pidfile = f"run/{service.name}.pid"
    waits = max(1, int(round(service.stop.timeout)))
    return (
        f"cd {ws} 2>/dev/null || {{ echo NOWS; exit 0; }}; "
        f"if [ ! -f {pidfile} ]; then echo NOPIDFILE; exit 0; fi; "
        f"pid=$(cat {pidfile}); "
        f"kill $pid 2>/dev/null; "
        f"i=0; while [ $i -lt {waits} ] && kill -0 $pid 2>/dev/null; do sleep 1; i=$((i+1)); done; "
        f"if kill -0 $pid 2>/dev/null; then kill -9 $pid 2>/dev/null; echo KILLED9=$pid; "
        f"else echo STOPPED=$pid; fi"
    )


def build_stop_script_command(service: ServiceConfig) -> str:
    ws = shell_ws(service.workspace)
    return f"cd {ws} && bash {shlex.quote(service.stop.script)}"


def build_status_command(service: ServiceConfig) -> str:
    ws = shell_ws(service.workspace)
    pidfile = f"run/{service.name}.pid"
    return (
        f"cd {ws} 2>/dev/null || {{ echo NOWS; exit 0; }}; "
        f"if [ ! -f {pidfile} ]; then echo NOPIDFILE; exit 0; fi; "
        f"pid=$(cat {pidfile}); "
        f"if kill -0 $pid 2>/dev/null; then echo RUNNING $pid; else echo DEAD $pid; fi"
    )


def build_list_archives_command(service: ServiceConfig) -> str:
    ws = shell_ws(service.workspace)
    return (
        f"cd {ws}/logs 2>/dev/null && find . -mindepth 2 -maxdepth 2 -type f "
        f"-printf '%P\\t%s\\n' | sort -r; true"
    )


def build_latest_run_command(service: ServiceConfig) -> str:
    ws = shell_ws(service.workspace)
    return f"cd {ws}/logs 2>/dev/null && ls -1d */ 2>/dev/null | sort -r | head -1; true"


def build_log_read_command(service: ServiceConfig, run_id: str, log_file: str,
                           tail: int | None, follow: bool = False) -> str:
    ws = shell_ws(service.workspace)
    target = f"logs/{run_id}/{log_file}"
    if follow:
        n = tail if tail is not None else 100
        return f"cd {ws} && tail -F -n {int(n)} -- {shlex.quote(target)}"
    if tail is None:
        return f"cd {ws} && cat -- {shlex.quote(target)}"
    return f"cd {ws} && tail -n {int(tail)} -- {shlex.quote(target)}"


# ------------------------------------------------------------- 结果解析 ----
def parse_pid(stdout: str) -> Optional[int]:
    m = re.search(r"^PID=(\d+)$", stdout, re.MULTILINE)
    return int(m.group(1)) if m else None


@dataclass
class ServiceStatus:
    state: str  # running | dead | nopidfile | nows | unknown
    pid: Optional[int] = None


def parse_status(stdout: str) -> ServiceStatus:
    text = stdout.strip()
    if text.startswith("RUNNING"):
        return ServiceStatus("running", _pid_of(text))
    if text.startswith("DEAD"):
        return ServiceStatus("dead", _pid_of(text))
    if text.startswith("NOPIDFILE"):
        return ServiceStatus("nopidfile")
    if text.startswith("NOWS"):
        return ServiceStatus("nows")
    return ServiceStatus("unknown")


def _pid_of(text: str) -> Optional[int]:
    parts = text.split()
    if len(parts) >= 2 and parts[1].isdigit():
        return int(parts[1])
    return None


def parse_archives(stdout: str) -> dict[str, list[dict]]:
    """解析 find -printf 输出 → {run_id: [{file, size}, ...]}（按 run_id 倒序）。"""
    archives: dict[str, list[dict]] = {}
    for line in stdout.splitlines():
        line = line.strip()
        if not line or "\t" not in line:
            continue
        rel, _, size = line.partition("\t")
        run_id, _, fname = rel.partition("/")
        if not run_id or not fname or not size.isdigit():
            continue
        archives.setdefault(run_id, []).append({"file": fname, "size": int(size)})
    return dict(sorted(archives.items(), reverse=True))


# --------------------------------------------------------------- 执行器 ----
async def start_service(pool: SSHPool, node: Node, service: ServiceConfig,
                        run_id: str, variables: dict[str, str]) -> dict:
    """启动服务：部署文件 + nohup 后台运行。返回 {pid, log_path, uploaded}。"""
    from .deployer import deploy_service  # 延迟导入避免循环

    uploaded = await deploy_service(pool, node, service)
    cmd = build_start_command(service, run_id, variables)
    res = await pool.run(node, cmd, timeout=60)
    if not res.ok:
        raise ExecError(f"启动命令失败(exit={res.exit_code}): {(res.stderr or res.stdout).strip()[:500]}")
    pid = parse_pid(res.stdout)
    if pid is None:
        raise ExecError(f"未能获取 PID，输出异常: {res.stdout.strip()[:300]}")
    return {"pid": pid, "log_path": service.log_path(run_id), "uploaded": uploaded}


async def stop_service(pool: SSHPool, node: Node, service: ServiceConfig) -> str:
    """停止服务：优先 stop.sh，之后执行 pid kill 兜底。返回输出摘要。"""
    outputs: list[str] = []
    if service.stop.script:
        res = await pool.run(node, build_stop_script_command(service), timeout=120)
        if not res.ok:
            raise ExecError(f"stop.sh 失败(exit={res.exit_code}): {(res.stderr or res.stdout).strip()[:500]}")
        outputs.append(res.stdout.strip())
    res = await pool.run(node, build_kill_stop_command(service), timeout=service.stop.timeout + 60)
    if not res.ok:
        raise ExecError(f"停止命令失败(exit={res.exit_code}): {(res.stderr or res.stdout).strip()[:500]}")
    outputs.append(res.stdout.strip())
    return " | ".join(o for o in outputs if o) or "done"


async def service_status(pool: SSHPool, node: Node, service: ServiceConfig) -> ServiceStatus:
    try:
        res = await pool.run(node, build_status_command(service), timeout=10)
    except SSHError:
        return ServiceStatus("unknown", None)
    return parse_status(res.stdout)


async def list_archives(pool: SSHPool, node: Node, service: ServiceConfig) -> dict[str, list[dict]]:
    res = await pool.run(node, build_list_archives_command(service), timeout=15)
    if not res.ok:
        raise ExecError(f"列出日志归档失败: {(res.stderr or '').strip()[:300]}")
    return parse_archives(res.stdout)


async def latest_run_id(pool: SSHPool, node: Node, service: ServiceConfig) -> Optional[str]:
    res = await pool.run(node, build_latest_run_command(service), timeout=15)
    out = res.stdout.strip()
    return out[:-1] if out.endswith("/") else (out or None)


async def read_log(pool: SSHPool, node: Node, service: ServiceConfig,
                   run_id: str, log_file: str, tail: int | None = None) -> str:
    res = await pool.run(node, build_log_read_command(service, run_id, log_file, tail), timeout=30)
    if not res.ok and not res.stdout:
        raise ExecError(f"读取日志失败(exit={res.exit_code}): {(res.stderr or '').strip()[:300]}")
    return res.stdout


async def open_log_stream(pool: SSHPool, node: Node, service: ServiceConfig,
                          run_id: str, log_file: str, tail: int = 100):
    """打开 tail -F 流式进程，返回 SSHClientProcess（stdout 可异步迭代）。"""
    cmd = build_log_read_command(service, run_id, log_file, tail, follow=True)
    return await pool.open_process(node, cmd)
