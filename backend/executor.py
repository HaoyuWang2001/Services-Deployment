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

import asyncssh

from .config import Node, ServiceConfig
from .deployer import deploy_service, perm_hint
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
# /proc/<pid>/stat 第 22 字段(starttime)是进程唯一指纹：
# 剥离 "pid (comm) " 前缀后为第 20 列，用于防 PID 复用误杀。
_TICK_CMD = "sed 's/.*) //' /proc/$pid/stat 2>/dev/null | awk '{print $20}'"


def build_start_command(service: ServiceConfig, run_id: str, variables: dict[str, str]) -> str:
    """启动命令：续写模式——同一实例多次启动共用日志文件，追加前写入分隔符行。

    - 重定向使用 >>（续写），启动前写 "===== [时间] 实例启动 =====" 分隔符
    - 退出码双写：exit_code（最近一次）+ exit_codes.log（历史，时间+码）
    - 组杀（停止）时 wrapper 一并被杀、不写码 → 无退出码 = 未正常结束
    """
    ws = shell_ws(service.workspace)
    script = shlex.quote(service.start.script)
    args = " ".join(shlex.quote(a) for a in service.start.args)
    env = ""
    if variables:
        env = "env " + " ".join(f"{k}={shlex.quote(str(v))}" for k, v in variables.items()) + " "
    logdir = f"logs/{run_id}"
    logfile = f"{logdir}/{service.start.log}"
    pidfile = f"run/{service.name}.pid"
    inner = (f"bash {script}"
             + (f" {args}" if args else "")
             + f"; rc=$?; echo $rc > {shlex.quote(f'{logdir}/exit_code')}; "
             + f"echo \"[$(date '+%F %T')] $rc\" >> {shlex.quote(f'{logdir}/exit_codes.log')}; exit $rc")
    separator = (f"echo \"===== [$(date '+%F %T')] 实例启动 =====\" "
                 f">> {shlex.quote(logfile)}; ")
    return (
        f"cd {ws} && mkdir -p {shlex.quote(logdir)} run && "
        f"{separator}"
        # setsid：服务进程树独立进程组（$! 即组长），停止时可整组清除。
        f"{{ setsid nohup {env}bash -c {shlex.quote(inner)} "
        f">> {shlex.quote(logfile)} 2>&1 < /dev/null & pid=$!; "
        f"tick=$({_TICK_CMD}); "
        f"echo \"$pid $tick\" > {pidfile}; echo PID=$pid; }}"
    )


def build_create_dirs_command(service: ServiceConfig, run_id: str) -> str:
    """创建实例（不启动）时建立日志目录与 run 目录（workspace 一并创建）。

    同时清理上一实例生命周期残留的 pid 文件（pid 文件按服务名命名、
    不随实例删除而删除），确保新实例探活呈「未运行」而非「已退出」。
    """
    ws = shell_ws(service.workspace)
    logdir = shlex.quote(f"logs/{run_id}")
    pidfile = shlex.quote(f"run/{service.name}.pid")
    return f"mkdir -p {ws}/{logdir} {ws}/run && rm -f {ws}/{pidfile}"


def build_kill_stop_command(service: ServiceConfig) -> str:
    """停止命令：指纹校验防误杀 → 整组终止 → 严格验证结果。

    输出与退出码：
      STOPPED=<pid>   成功（exit 0）；进程本就已死也走此路径
      LEGACY=<pid>    旧格式 pid 文件（无指纹，升级前启动），需手动处理（exit 1）
      PIDREUSED=<pid> 指纹不匹配，PID 已被复用，拒绝误杀（exit 1）
      STOPFAIL=<pid>  组杀+强杀后仍存活，如实报失败（exit 1）
      NOPIDFILE/NOWS  无 pid 文件 / 未部署（exit 0，视为无需停止）
    """
    ws = shell_ws(service.workspace)
    pidfile = f"run/{service.name}.pid"
    waits = max(1, int(round(service.stop.timeout)))
    alive = "{ kill -0 -- -$pid 2>/dev/null || kill -0 $pid 2>/dev/null; }"
    return (
        f"cd {ws} 2>/dev/null || {{ echo NOWS; exit 0; }}; "
        f"if [ ! -f {pidfile} ]; then echo NOPIDFILE; exit 0; fi; "
        f"read pid tick < {pidfile}; "
        f"if ! kill -0 $pid 2>/dev/null; then echo STOPPED=$pid; exit 0; fi; "
        f"if [ -z \"$tick\" ]; then "
        f"echo LEGACY=$pid; echo \"旧格式实例(升级前启动): 请在节点上手动执行 kill -9 $pid 并删除 {pidfile}\"; exit 1; fi; "
        f"ctick=$({_TICK_CMD}); "
        f"if [ \"$ctick\" != \"$tick\" ]; then echo PIDREUSED=$pid; echo 'PID 已被其他进程复用，为避免误杀已终止停止操作'; exit 1; fi; "
        f"kill -- -$pid 2>/dev/null; kill $pid 2>/dev/null; "
        f"i=0; while [ $i -lt {waits} ] && {alive}; do sleep 1; i=$((i+1)); done; "
        f"if {alive}; then kill -9 -- -$pid 2>/dev/null; kill -9 $pid 2>/dev/null; "
        f"j=0; while [ $j -lt 3 ] && {alive}; do sleep 1; j=$((j+1)); done; fi; "
        f"if {alive}; then echo STOPFAIL=$pid; exit 1; else echo STOPPED=$pid; fi"
    )


def build_stop_script_command(service: ServiceConfig) -> str:
    ws = shell_ws(service.workspace)
    return f"cd {ws} && bash {shlex.quote(service.stop.script)}"


def build_status_command(service: ServiceConfig, run_id: Optional[str] = None) -> str:
    """探活命令；run_id 提供时，已退出实例附带 exit_code 文件中的退出码（无文件为 -）。"""
    ws = shell_ws(service.workspace)
    pidfile = f"run/{service.name}.pid"
    if run_id:
        exit_file = shlex.quote(f"logs/{run_id}/exit_code")
        dead = f"rc=$(cat {exit_file} 2>/dev/null || echo -n -); echo DEAD $pid rc=$rc; exit 0; "
    else:
        dead = "echo DEAD $pid rc=-; exit 0; "
    return (
        f"cd {ws} 2>/dev/null || {{ echo NOWS; exit 0; }}; "
        f"if [ ! -f {pidfile} ]; then echo NOPIDFILE; exit 0; fi; "
        f"read pid tick < {pidfile}; "
        f"if ! kill -0 $pid 2>/dev/null; then {dead}fi; "
        f"if [ -z \"$tick\" ]; then echo LEGACY $pid; exit 0; fi; "
        f"ctick=$({_TICK_CMD}); "
        f"if [ \"$ctick\" != \"$tick\" ]; then echo REUSED $pid; else echo RUNNING $pid; fi"
    )


def build_list_archives_command(service: ServiceConfig) -> str:
    ws = shell_ws(service.workspace)
    return (
        f"cd {ws}/logs 2>/dev/null && {{ "
        f"find . -mindepth 2 -maxdepth 2 -type f ! -name exit_code -printf '%P\\t%s\\n' | sort -r; "
        f"for f in */exit_code; do [ -f \"$f\" ] && "
        f"printf 'EXIT\\t%s\\t%s\\n' \"${{f%/exit_code}}\" \"$(cat \"$f\")\"; done; "
        f"}}; true"
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
    state: str  # running | dead | legacy | reused | nopidfile | nows | unknown
    pid: Optional[int] = None
    exit_code: Optional[int] = None  # 已退出实例的退出码；None = 无文件（被终止）或非 dead 状态


def parse_status(stdout: str) -> ServiceStatus:
    text = stdout.strip()
    m = re.search(r"rc=(\d+)", text)
    exit_code = int(m.group(1)) if m else None
    for prefix, state in (("RUNNING", "running"), ("DEAD", "dead"),
                          ("LEGACY", "legacy"), ("REUSED", "reused"),
                          ("NOPIDFILE", "nopidfile"), ("NOWS", "nows")):
        if text.startswith(prefix):
            return ServiceStatus(state, _pid_of(text), exit_code)
    return ServiceStatus("unknown")


def _pid_of(text: str) -> Optional[int]:
    parts = text.split()
    if len(parts) >= 2 and parts[1].isdigit():
        return int(parts[1])
    return None


def parse_archives(stdout: str) -> tuple[dict[str, list[dict]], dict[str, int]]:
    """解析输出 → (按 run_id 倒序的日志文件表, 各批次退出码表)。"""
    archives: dict[str, list[dict]] = {}
    exit_codes: dict[str, int] = {}
    for line in stdout.splitlines():
        line = line.strip()
        if not line or "\t" not in line:
            continue
        if line.startswith("EXIT\t"):
            parts = line.split("\t")
            if len(parts) == 3 and parts[2].lstrip("-").isdigit():
                exit_codes[parts[1]] = int(parts[2])
            continue
        rel, _, size = line.partition("\t")
        run_id, _, fname = rel.partition("/")
        if not run_id or not fname or fname == "exit_code" or not size.isdigit():
            continue
        archives.setdefault(run_id, []).append({"file": fname, "size": int(size)})
    return (dict(sorted(archives.items(), reverse=True)),
            dict(sorted(exit_codes.items(), reverse=True)))


# ------------------------------------------------------------- 端口监控 ----
PROC_RE = re.compile(r'\("([^"]+)",pid=(\d+),fd=\d+\)')


def build_ports_command(sudo: bool = False) -> str:
    """列出监听端口及占用进程（-t tcp -u udp -l 监听 -n 数字 -p 进程 -H 无表头）。

    同一条命令附加 `ps -eo pid=,user=` 段（无需特权）建立 pid→用户映射，
    以 ===PS=== 标记分隔，一次 SSH 往返完成。
    sudo=True 时经 `sudo -n` 提权以获取全部进程归属（要求 sudoers 免密放行）；
    用 -n 确保未放行时立即失败而非挂起等待密码。
    """
    prefix = "sudo -n " if sudo else ""
    return f"( {prefix}ss -tulnpH; echo ===PS===; ps -eo pid=,user= )"


_PS_MARK = "===PS==="


def _split_local(local: str) -> tuple[str, int | None]:
    addr, _, port = local.rpartition(":")
    if not port.isdigit():
        return local, None
    addr = addr.strip("[]")
    return addr or "*", int(port)


def parse_ports(stdout: str) -> list[dict]:
    """解析命令输出 → 按端口排序的结构化列表，processes 附带 user（pid→用户映射）。"""
    if _PS_MARK in stdout:
        ss_part, _, ps_part = stdout.partition(_PS_MARK)
    else:
        ss_part, ps_part = stdout, ""
    users: dict[int, str] = {}
    for line in ps_part.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0].isdigit():
            users[int(parts[0])] = parts[1]

    entries: list[dict] = []
    for line in ss_part.splitlines():
        parts = line.split()
        if len(parts) < 5:
            continue
        netid, state, local = parts[0].lower(), parts[1], parts[4]
        proc_part = " ".join(parts[6:])
        addr, port = _split_local(local)
        if port is None:
            continue
        entries.append({
            "proto": netid,
            "state": state,
            "local_addr": addr,
            "port": port,
            "processes": [{"process": n, "pid": int(p), "user": users.get(int(p))}
                          for n, p in PROC_RE.findall(proc_part)],
        })
    return sorted(entries, key=lambda e: (e["port"], e["proto"], e["local_addr"]))


async def list_ports(pool: SSHPool, node: Node) -> list[dict]:
    res = await pool.run(node, build_ports_command(node.sudo), timeout=15)
    if not res.ok and not res.stdout:
        err = (res.stderr or "").strip()
        if node.sudo:
            hint = ""
            if any(k in err.lower() for k in ("password", "not allowed", "sorry", "authentication", "not in the sudoers")):
                hint = "（sudoers 未放行免密，需配置如: user ALL=(root) NOPASSWD: /usr/sbin/ss）"
            raise ExecError(f"sudo 提权查询端口失败(exit={res.exit_code}): {err[:200]}{hint}")
        raise ExecError(f"查询端口失败(exit={res.exit_code}): {err[:300]}（节点需支持 ss 命令）")
    return parse_ports(res.stdout)


# --------------------------------------------------------------- 监控 ----
MAX_STDOUT = 200_000
MAX_STDERR = 10_000


def build_monitor_command(cmd: str) -> str:
    """`sudo ` 前缀自动改写为 `sudo -n `，避免节点未配免密时挂死通道。"""
    stripped = cmd.lstrip()
    if stripped.startswith("sudo ") or stripped.rstrip() == "sudo":
        lead = cmd[: len(cmd) - len(stripped)]
        return f"{lead}sudo -n {stripped[5:].rstrip()}" if stripped[5:] else f"{lead}sudo -n"
    return cmd


def trim_output(text: str, limit: int) -> str:
    if len(text) <= limit:
        return text
    return text[:limit] + f"\n...[输出过长，已截断，原始 {len(text)} 字符]"


# --------------------------------------------------------------- 执行器 ----
async def start_service(pool: SSHPool, node: Node, service: ServiceConfig,
                        run_id: str, variables: dict[str, str]) -> dict:
    """启动服务：部署文件 + 分隔符 + nohup 续写运行。返回 {pid, log_path, uploaded}。"""
    uploaded = await deploy_service(pool, node, service)
    cmd = build_start_command(service, run_id, variables)
    res = await pool.run(node, cmd, timeout=60)
    if not res.ok:
        out = (res.stderr or res.stdout).strip()
        raise ExecError(f"启动命令失败(exit={res.exit_code}): {out[:500]}{perm_hint(out)}")
    pid = parse_pid(res.stdout)
    if pid is None:
        raise ExecError(f"未能获取 PID，输出异常: {res.stdout.strip()[:300]}")
    return {"pid": pid, "log_path": service.log_path(run_id), "uploaded": uploaded}


async def create_dirs(pool: SSHPool, node: Node, service: ServiceConfig, run_id: str) -> None:
    """创建实例（不启动）时建立日志目录。"""
    res = await pool.run(node, build_create_dirs_command(service, run_id), timeout=15)
    if not res.ok:
        err = (res.stderr or res.stdout or "").strip()
        raise ExecError(f"创建日志目录失败: {err[:300]}{perm_hint(err)}")


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


async def service_status(pool: SSHPool, node: Node, service: ServiceConfig,
                         run_id: Optional[str] = None) -> ServiceStatus:
    try:
        res = await pool.run(node, build_status_command(service, run_id), timeout=10)
    except SSHError:
        return ServiceStatus("unknown")
    return parse_status(res.stdout)


async def list_archives(pool: SSHPool, node: Node, service: ServiceConfig) -> tuple[dict, dict]:
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
                          run_id: str, log_file: str, tail: int = 100) -> "LogStreamHandle":
    """在专用 SSH 连接上打开 tail -F 流（与连接池隔离，池连接重建不会中断日志流）。"""
    cmd = build_log_read_command(service, run_id, log_file, tail, follow=True)
    conn = await pool.connect_dedicated(node)
    try:
        proc = await conn.create_process(cmd, encoding="utf-8", errors="replace")
    except (asyncssh.Error, OSError) as e:
        conn.close()
        raise SSHError(f"在 {node.name} 上启动日志流失败: {e}") from e
    return LogStreamHandle(conn=conn, proc=proc)


@dataclass
class LogStreamHandle:
    """日志流句柄：持有专用连接与 tail 进程，关闭时一并释放。"""
    conn: asyncssh.SSHClientConnection
    proc: asyncssh.SSHClientProcess

    def close(self) -> None:
        for target in (self.proc, self.conn):
            try:
                target.close()
            except Exception:  # noqa: BLE001
                pass
