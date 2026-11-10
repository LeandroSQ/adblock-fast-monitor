#!/bin/sh
# T26 / P1 (docs/CONTRACT.md §11) in the regular guest suite: with the package
# installed and enabled=0 the monitor costs nothing at runtime. The full
# off/on measurement is scripts/integration/measure-performance.mjs.
. "$ABFM_TESTLIB/sh/testlib.sh"

t_eq "the package ships disabled" 0 "$(uci -q get adblock-fast-monitor.config.enabled)"

# Five samples over ~10 s, so a procd respawn loop is caught too.
pkg='' readers=''
i=0
while [ $i -lt 5 ]; do
	pkg="$pkg$(ps w | grep '[a]dblock-fast-monitor' | grep -v 'perf-p1')"
	readers="$readers$(ps w | grep '[l]ogread -f')"
	i=$((i + 1))
	[ $i -lt 5 ] && sleep 2
done
t_eq "no package process runs while disabled" "" "$pkg"
t_eq "no logread follower runs while disabled" "" "$readers"
t_not "no monitor ubus object while disabled" ubus list adblock-fast-monitor

dropins=''
for d in /tmp/dnsmasq*.d; do
	[ -e "$d/adblock-fast-monitor.conf" ] && dropins="$dropins $d/adblock-fast-monitor.conf"
done
t_eq "no query-logging drop-in while disabled" "" "$dropins"
t_not "no dnsmasq configuration enables log-queries while disabled" \
	sh -c 'cat /var/etc/dnsmasq.conf.* /tmp/dnsmasq*.d/* 2>/dev/null | grep -q "^log-queries"'

t_done
