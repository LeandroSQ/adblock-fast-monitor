#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Proves test:shell runs OpenWrt 25.12.6's BusyBox with only its default
# applets: stat and timeout are absent on a stock router (review B4).
# shellcheck source=test/lib/sh/testlib.sh
. "$ABFM_TESTLIB/sh/testlib.sh"

has() { command -v "$1" >/dev/null 2>&1; }

# shellcheck disable=SC2012 # the banner of the ls applet, not a listing
t_match "BusyBox is the 25.12.6 version" '^BusyBox v1\.37\.0' "$(ls --help 2>&1 | head -n 1)"
t_not "stat applet is absent" has stat
t_not "timeout applet is absent" has timeout
t_not "realpath applet is absent" has realpath
t_not "sleep rejects fractional seconds (no FLOAT_DURATION)" sleep 0.1
t_ok "flock applet is present" has flock
t_ok "OpenWrt lock applet is present" has lock
t_ok "uci, ubus, jsonfilter, jshn and ucode are present" sh -c 'command -v uci && command -v ubus && command -v jsonfilter && command -v jshn && command -v ucode'

dir=$(abfm_tmpdir)
: >"$dir/file"
chmod 0640 "$dir/file"
t_eq "abfm_stat replaces stat -c" "0:640:file" "$(abfm_stat '%u:%a:%F' "$dir/file")"
t_not "abfm_stat fails for a missing path" abfm_stat '%u' "$dir/missing"

start=$(date +%s)
abfm_timeout 30 true
t_eq "abfm_timeout returns the command status" 0 "$?"
t_ok "abfm_timeout returns as soon as the command exits" test "$(( $(date +%s) - start ))" -lt 3
abfm_timeout 1 sleep 20
t_eq "abfm_timeout returns 124 on expiry" 124 "$?"

t_done
