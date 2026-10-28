"""executor 新增功能测试：端口监控解析。"""
from __future__ import annotations

from backend.executor import build_ports_command, parse_ports


SS_OUTPUT = """\
tcp   LISTEN   0      128          0.0.0.0:22           0.0.0.0:*     users:(("sshd",pid=980,fd=3))
tcp   LISTEN   0      128             [::]:22              [::]:*     users:(("sshd",pid=980,fd=4))
tcp   LISTEN   0      128    192.168.1.11:2379       0.0.0.0:*     users:(("etcd",pid=1234,fd=6),("etcd",pid=1235,fd=9))
udp   UNCONN   0      0              0.0.0.0:68             0.0.0.0:*     users:(("dhclient",pid=777,fd=5))
tcp   LISTEN   0      511          0.0.0.0:https         0.0.0.0:*
"""

PS_SECTION = """\
===PS===
   980 root
  1234 etcd
  1235 etcd
   777 root
"""


def test_ports_command():
    assert build_ports_command() == "( ss -tulnpH; echo ===PS===; ps -eo pid=,user= )"
    assert build_ports_command(True) == "( sudo -n ss -tulnpH; echo ===PS===; ps -eo pid=,user= )"


def test_parse_ports_basic():
    ports = parse_ports(SS_OUTPUT + PS_SECTION)
    # 最后一行端口列 "0.0.0.0:https" 无法解析 → 丢弃
    assert len(ports) == 4
    by = {(p["proto"], p["port"], p["local_addr"]): p for p in ports}
    ssh4 = by[("tcp", 22, "0.0.0.0")]
    assert ssh4["state"] == "LISTEN"
    assert ssh4["processes"] == [{"process": "sshd", "pid": 980, "user": "root"}]
    ssh6 = by[("tcp", 22, "::")]
    assert ssh6["local_addr"] == "::"
    etcd = by[("tcp", 2379, "192.168.1.11")]
    assert etcd["processes"] == [
        {"process": "etcd", "pid": 1234, "user": "etcd"},
        {"process": "etcd", "pid": 1235, "user": "etcd"},
    ]
    dhcp = by[("udp", 68, "0.0.0.0")]
    assert dhcp["state"] == "UNCONN"
    assert dhcp["processes"] == [{"process": "dhclient", "pid": 777, "user": "root"}]


def test_parse_ports_without_ps_section():
    """兼容无 PS 段输入：user 为 None。"""
    ports = parse_ports(SS_OUTPUT)
    ssh = [p for p in ports if p["port"] == 22][0]
    assert ssh["processes"] == [{"process": "sshd", "pid": 980, "user": None}]


def test_parse_ports_ps_pid_missing():
    """ss 与 ps 间隙进程退出：user 为 None，不影响解析。"""
    out = SS_OUTPUT.replace("pid=980", "pid=424242") + PS_SECTION
    ports = parse_ports(out)
    ssh = [p for p in ports if p["port"] == 22][0]
    assert ssh["processes"][0]["user"] is None


def test_parse_ports_sorted_by_port():
    ports = parse_ports(SS_OUTPUT + PS_SECTION)
    assert [p["port"] for p in ports] == sorted(p["port"] for p in ports)


def test_parse_ports_no_process_info():
    out = "tcp   LISTEN   0      128    0.0.0.0:9000    0.0.0.0:*    \n"
    p = parse_ports(out)[0]
    assert p["port"] == 9000 and p["processes"] == []


def test_parse_ports_empty():
    assert parse_ports("") == []
    assert parse_ports("===PS===\n 980 root\n") == []
