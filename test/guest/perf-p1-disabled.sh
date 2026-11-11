#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# T26 / P1 (docs/CONTRACT.md §11, design B-min) in the regular guest suite:
# the installed package runs no process of its own in any state, with query
# logging off and on (only job.uc during an Apply may run, not exercised
# here). Switches go through uci commit + reload_config, as LuCI's Save &
# Apply does. The full measurement is scripts/integration/measure-performance.mjs.
. "$ABFM_TESTLIB/sh/testlib.sh"

CFG=adblock-fast-monitor.config.query_logging
t_ok "the query_logging switch exists (contract api 2)" uci -q get "$CFG"
orig=$(uci -q get "$CFG")

pkg_procs() { ps w | grep '[a]dblock-fast-monitor' | grep -v 'perf-p1'; }
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
	pkg='' readers=''
	i=0
	while [ $i -lt 5 ]; do
		pkg="$pkg$(pkg_procs)"
		readers="$readers$(ps w | grep '[l]ogread -f')"
		i=$((i + 1))
		[ $i -lt 5 ] && sleep 2
	done
	t_eq "no package process runs with query_logging=$v" "" "$pkg"
	t_eq "no logread follower runs with query_logging=$v" "" "$readers"
	t_not "no resident adblock-fast-monitor ubus object with query_logging=$v" ubus list adblock-fast-monitor
done

if [ -n "$orig" ]; then
	t_ok "query_logging restored to '$orig'" set_logging "$orig"
else
	uci -q delete "$CFG"; uci commit adblock-fast-monitor; reload_config
	t_ok "query_logging restored to its default" abfm_wait_until 60 sh -c '! ps w | grep -q "[/]etc/init.d/adblock-fast-monitor"'
fi
t_done
