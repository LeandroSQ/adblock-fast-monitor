#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Drive a booting OpenWrt guest over its QEMU serial socket.

Waits for the console to come up (no fixed sleeps: it reacts to procd's
"Please press Enter to activate this console"), then runs provisioning
commands, each acknowledged by an exit-status marker, and finally waits inside
the guest until the network, dnsmasq and dropbear are ready.

usage: serial-console.py SOCKET TIMEOUT_SECONDS  < commands
Each stdin line is one shell command run in the guest; a non-zero status
aborts with exit code 1. Progress goes to stderr.
"""
import re
import socket
import sys
import time

sock_path, timeout = sys.argv[1], float(sys.argv[2])
deadline = time.monotonic() + timeout
commands = [line.rstrip("\n") for line in sys.stdin if line.strip()]


def fail(message):
    sys.stderr.write("serial-console: %s\n" % message)
    sys.exit(1)


conn = socket.socket(socket.AF_UNIX)
while True:
    try:
        conn.connect(sock_path)
        break
    except OSError:
        if time.monotonic() >= deadline:
            fail("serial socket never appeared")
        time.sleep(0.1)
conn.settimeout(0.5)
buffer = b""


def read_until(pattern, what, within=None):
    """Waits for PATTERN; with WITHIN seconds, raises TimeoutError after them."""
    global buffer
    regex = re.compile(pattern)
    give_up = time.monotonic() + within if within else None
    while True:
        found = regex.search(buffer)
        if found:
            buffer = buffer[found.end():]
            return found
        if give_up is not None and time.monotonic() >= give_up and time.monotonic() < deadline:
            raise TimeoutError(what)
        if time.monotonic() >= deadline:
            fail("timed out waiting for %s; last output: %r" % (what, buffer[-400:]))
        try:
            chunk = conn.recv(65536)
        except socket.timeout:
            continue
        if not chunk:
            fail("serial console closed while waiting for %s" % what)
        buffer += chunk


read_until(rb"Please press Enter to activate this console", "console")
conn.sendall(b"\n")
read_until(rb"root@[^\r\n]*# ", "shell prompt")
# Input typed while early boot is still loading modules and bringing up the
# LAN can be lost (seen on armsr-armv8 under hvf, where the prompt appears
# before the hostname is set). Wait for the console to fall silent, then
# repeat a round trip until the guest answers.
def wait_quiet(seconds):
    global buffer
    last = time.monotonic()
    while time.monotonic() - last < seconds:
        if time.monotonic() >= deadline:
            fail("console never fell silent; last output: %r" % buffer[-400:])
        try:
            chunk = conn.recv(65536)
        except socket.timeout:
            continue
        if not chunk:
            fail("serial console closed during boot")
        buffer += chunk
        last = time.monotonic()


wait_quiet(3)
attempt = 0
while True:
    attempt += 1
    tag = "ABFMSYNC%d" % attempt
    conn.sendall(("stty -echo 2>/dev/null; export PS1='# '; printf '%%s_%%s\\n' %s ok\n" % tag).encode())
    try:
        read_until(re.escape(tag).encode() + rb"_ok", "console round trip", 5)
        break
    except TimeoutError:
        sys.stderr.write("serial-console: console input lost (attempt %d), retrying\n" % attempt)
read_until(rb"# ", "quiet prompt")

for index, command in enumerate(commands):
    tag = "ABFM%d_%d" % (index, time.monotonic_ns())
    # The marker is assembled by printf so it never appears in the echoed input.
    conn.sendall(("%s; printf '%%s_%%s\\n' %s \"rc$?\"\n" % (command, tag)).encode())
    found = read_until(re.escape(tag).encode() + rb"_rc(\d+)", "command %d" % index)
    rc = int(found.group(1))
    if rc != 0:
        fail("guest command %d failed with %d: %s" % (index, rc, command[:200]))
    sys.stderr.write("serial-console: step %d/%d ok\n" % (index + 1, len(commands)))
conn.close()
