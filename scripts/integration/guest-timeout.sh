#!/bin/sh
# BusyBox-safe replacement for `timeout SECONDS COMMAND...` (the timeout
# applet is disabled on stock OpenWrt 25.12). Returns the command's status,
# or 124 if it was terminated after SECONDS. The watchdog polls once a second
# (OpenWrt's BusyBox sleep rejects fractions), so this returns at most 1 s
# after the command exits and leaves no stray processes behind.
set -u

seconds="$1"
shift
"$@" &
pid=$!
(
	ticks=$seconds
	while [ "$ticks" -gt 0 ]; do
		sleep 1
		kill -0 "$pid" 2>/dev/null || exit 0
		ticks=$((ticks - 1))
	done
	kill -TERM "$pid" 2>/dev/null
	exit 124
) &
watchdog=$!
wait "$pid"
rc=$?
wait "$watchdog"
[ $? -eq 124 ] && exit 124
exit "$rc"
