#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# shellcheck disable=SC2009 # BusyBox pgrep cannot print full command lines
# T26 / P1 (docs/CONTRACT.md §11) in the regular guest suite:
# the installed package runs no process of its own in any state, with query
# logging off and on (only job.uc during an Apply may run, not exercised
# here). Switches go through uci commit + reload_config, as LuCI's Save &
# Apply does. The full measurement is scripts/integration/measure-performance.mjs.
# shellcheck source=test/lib/sh/testlib.sh
. "$ABFM_TESTLIB/sh/testlib.sh"

CFG=adblock-fast-monitor.config.query_logging
t_ok "the query_logging switch exists (contract api 2)" uci -q get "$CFG"
orig=$(uci -q get "$CFG")

# Resident = not a (transient) init-script invocation: the procd trigger may
# run `/etc/init.d/adblock-fast-monitor reload` 3 s after dnsmasq restarts.
INIT_RE='/etc/init.d/adblock-fast-monitor|/usr/libexec/adblock-fast-monitor/logging.uc'
pkg_procs() { ps w | grep '[a]dblock-fast-monitor' | grep -v 'perf-p1' | grep -Ev "$INIT_RE"; }
init_pids() { ps w | grep '[a]dblock-fast-monitor' | grep -E "$INIT_RE" | awk '{print $1}' | sort | tr '\n' ' '; }
init_busy() { ps w | grep -q '[/]etc/init.d/adblock-fast-monitor'; }
dropins() {
	for d in /tmp/dnsmasq*.d; do
		[ -e "$d/adblock-fast-monitor.conf" ] && printf '%s ' "$d/adblock-fast-monitor.conf"
	done
}
# settled 0|1: the init script finished, dnsmasq runs, drop-ins match the switch
settled() {
	init_busy && return 1
	pidof dnsmasq >/dev/null || return 1
	if [ "$1" = 1 ]; then [ -n "$(dropins)" ]; else [ -z "$(dropins)" ]; fi
}
set_logging() {
	uci set "$CFG=$1" && uci commit adblock-fast-monitor && reload_config
	abfm_wait_until 60 settled "$1"
}

for v in 0 1; do
	t_ok "query_logging=$v applies (drop-ins match, dnsmasq up)" set_logging $v
	# Five samples over ~10 s, so a procd respawn loop is caught too.
	pkg='' first_init=$(init_pids) last_init=''
	i=0
	while [ $i -lt 5 ]; do
		pkg="$pkg$(pkg_procs)"
		i=$((i + 1))
		[ $i -lt 5 ] && sleep 2
	done
	last_init=$(init_pids)
	stuck=''
	for p in $first_init; do case " $last_init " in *" $p "*) stuck="$stuck $p" ;; esac; done
	t_eq "no resident package process runs with query_logging=$v" "" "$pkg"
	t_eq "no init-script invocation lives through the 8 s sample with query_logging=$v" "" "$stuck"
done

if [ -n "$orig" ]; then
	t_ok "query_logging restored to '$orig'" set_logging "$orig"
else
	uci -q delete "$CFG"; uci commit adblock-fast-monitor; reload_config
	t_ok "query_logging restored to its default" abfm_wait_until 60 sh -c '! ps w | grep -q "[/]etc/init.d/adblock-fast-monitor"'
fi
t_done
