#!/usr/bin/env python3
"""Sends raw DNS queries over UDP (stdlib only) and prints the rcode and the
answer count. Labels are given as Python string literals so tests can send
names that dig refuses (spaces, control characters).

    dnsq.py HOST PORT QTYPE NAME [NAME...]
    QTYPE: A AAAA HTTPS PTR or a number; NAME: dotted, or repr-style with \\x escapes
"""
import random
import socket
import struct
import sys

TYPES = {"A": 1, "AAAA": 28, "PTR": 12, "TXT": 16, "HTTPS": 65}


def encode(name):
    out = b""
    for label in name.split("."):
        raw = label.encode("latin-1")
        out += bytes([len(raw)]) + raw
    return out + b"\0"


def query(host, port, qtype, name, timeout=3.0):
    qid = random.randint(0, 0xFFFF)
    pkt = struct.pack(">HHHHHH", qid, 0x0100, 1, 0, 0, 0) + encode(name) + struct.pack(">HH", qtype, 1)
    family = socket.AF_INET6 if ":" in host else socket.AF_INET
    with socket.socket(family, socket.SOCK_DGRAM) as s:
        s.settimeout(timeout)
        s.sendto(pkt, (host, port))
        try:
            data, _ = s.recvfrom(4096)
        except socket.timeout:
            return "TIMEOUT", 0
    flags, _, ancount = struct.unpack(">HHH", data[2:8])
    return ["NOERROR", "FORMERR", "SERVFAIL", "NXDOMAIN", "NOTIMP", "REFUSED"][flags & 15] if (flags & 15) < 6 else str(flags & 15), ancount


def main():
    host, port, qtype = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    qtype = TYPES.get(qtype.upper()) or int(qtype)
    for raw in sys.argv[4:]:
        name = raw.encode("latin-1").decode("unicode_escape")
        rcode, ancount = query(host, port, qtype, name)
        print(f"{rcode} {ancount} {raw}")


if __name__ == "__main__":
    main()
