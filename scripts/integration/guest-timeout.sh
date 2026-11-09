#!/bin/sh
set -eu

seconds="$1"
shift
"$@" &
pid=$!
sleep "$seconds"
if kill -0 "$pid" 2>/dev/null; then
	kill "$pid"
	wait "$pid" 2>/dev/null || :
	exit 124
fi
wait "$pid"
