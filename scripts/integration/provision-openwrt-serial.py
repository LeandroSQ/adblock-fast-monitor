#!/usr/bin/env python3
import socket
import sys
import time
import re

path, pubkey, root_password, readonly_password = sys.argv[1:]
deadline = time.monotonic() + 180
transcript = open(path + ".log", "wb")

s = socket.socket(socket.AF_UNIX)
while True:
    try:
        s.connect(path)
        break
    except OSError:
        if time.monotonic() >= deadline:
            raise SystemExit("serial socket did not become available")
        time.sleep(1)
s.settimeout(1)

def receive_until(marker):
    received = b""
    while marker not in received:
        if time.monotonic() >= deadline:
            raise SystemExit(f"serial console did not emit {marker!r}")
        try:
            chunk = s.recv(4096)
        except socket.timeout:
            continue
        if not chunk:
            raise SystemExit("serial console closed unexpectedly")
        transcript.write(chunk)
        transcript.flush()
        received += chunk
    return received

def run(command):
    marker = f"__ABFM_RC_{time.monotonic_ns()}__".encode()
    success = marker + b"OK\r\n"
    failure = marker + b"FAIL"
    s.sendall((
        command +
        f"; rc=$?; [ \"$rc\" -eq 0 ] && printf '{marker.decode()}OK\\n' || printf '{marker.decode()}FAIL%s\\n' \"$rc\"\n"
    ).encode())
    received = b""
    while success not in received and not re.search(re.escape(failure) + rb"\d+\r\n", received):
        if time.monotonic() >= deadline:
            raise SystemExit(f"serial command did not report completion: {command}")
        try:
            chunk = s.recv(4096)
        except socket.timeout:
            continue
        if not chunk:
            raise SystemExit("serial console closed unexpectedly")
        transcript.write(chunk)
        transcript.flush()
        received += chunk
    if re.search(re.escape(failure) + rb"\d+\r\n", received):
        raise SystemExit(f"serial command failed: {command}")
    return received

def set_password(username, password):
    s.sendall(f"passwd {username}\n".encode())
    receive_until(b"New password:")
    s.sendall(password.encode() + b"\n")
    receive_until(b"Retype password:")
    s.sendall(password.encode() + b"\n")
    receive_until(b"# ")

receive_until(b"procd: - init -")
receive_until(b"Please press Enter")
s.sendall(b"\n")
receive_until(b"# ")

key = open(pubkey, "r", encoding="ascii").read().strip()
commands = [
    "mkdir -p /etc/dropbear; chmod 700 /etc/dropbear",
    f"printf '%s\\n' '{key}' > /etc/dropbear/authorized_keys; chmod 600 /etc/dropbear/authorized_keys",
    "grep -q '^monitor-readonly:' /etc/passwd || echo 'monitor-readonly:x:1001:65534:QEMU:/var/empty:/bin/false' >> /etc/passwd",
    "printf '%s\\n' \"config login 'monitor_readonly_qemu'\" \"\\toption username 'monitor-readonly'\" \"\\toption password '\\$p\\$monitor-readonly'\" \"\\tlist read 'luci-app-adblock-fast-monitor'\" >> /etc/config/rpcd",
    "uci set network.lan.proto=dhcp; uci commit network; /etc/init.d/network restart",
    "/etc/init.d/dropbear restart; /etc/init.d/rpcd restart",
]
set_password("root", root_password)
for command in commands:
    run(command)
    if command.startswith("grep -q"):
        set_password("monitor-readonly", readonly_password)

transcript.close()
