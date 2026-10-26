"""executor 新增功能测试：端口监控解析。"""
from __future__ import annotations

from backend.executor import build_ports_command, parse_ports


SS_OUTPUT = """\
tcp   LISTEN   0      128          0.0.0.0:22           0.0.0.0:*     users:(("sshd",pid=980,fd=3))
tcp   LISTEN   0      128             [::]:22              [::]:*     users:(("sshd",pid=980,fd=4))
tcp   LISTEN   0      128    192.168.1.11:2379       0.0.0.0:*     users:(("etcd",pid=1234,fd=6),("etcd",pid=1234,fd=9))
udp   UNCONN   0      0              0.0.0.0:68             0.0.0.0:*     users:(("dhclient",pid=777,fd=5))
tcp   LISTEN   0      511          0.0.0.0:https         0.0.0.0:*
"""


def test_ports_command():
    assert build_ports_command() == "ss -tulnpH"
    assert build_ports_command(False) == "ss -tulnpH"
    assert build_ports_command(True) == "sudo -n ss -tulnpH"


def test_parse_ports_basic():
    ports = parse_ports(SS_OUTPUT)
    # 最后一行端口列 "0.0.0.:*" 无法解析 → 丢弃
    assert len(ports) == 4
    by = {(p["proto"], p["port"], p["local_addr"]): p for p in ports}
    ssh4 = by[("tcp", 22, "0.0.0.0")]
    assert ssh4["state"] == "LISTEN"
    assert ssh4["processes"] == [{"process": "sshd", "pid": 980}]
    ssh6 = by[("tcp", 22, "::")]
    assert ssh6["local_addr"] == "::"
    etcd = by[("tcp", 2379, "192.168.1.11")]
    assert etcd["processes"] == [{"process": "etcd", "pid": 1234},
                                 {"process": "etcd", "pid": 1234}]
    dhcp = by[("udp", 68, "0.0.0.0")]
    assert dhcp["state"] == "UNCONN"


def test_parse_ports_sorted_by_port():
    ports = parse_ports(SS_OUTPUT)
    assert [p["port"] for p in ports] == sorted(p["port"] for p in ports)


def test_parse_ports_no_process_info():
    out = "tcp   LISTEN   0      128    0.0.0.0:9000    0.0.0.0:*    \n"
    p = parse_ports(out)[0]
    assert p["port"] == 9000 and p["processes"] == []


def test_parse_ports_empty():
    assert parse_ports("") == []
