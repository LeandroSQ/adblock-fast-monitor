#!/usr/bin/env bash
# T08 at boot / P10 (docs/CONTRACT.md §4.1, §5): with the monitor enabled,
# a reboot brings up the daemon and the query-logging drop-in before dnsmasq
# (START=18 < 19), so dnsmasq starts once, already logging, and the monitor
# never restarts it. Also T06 after boot: one daemon, one logread, object.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
# shellcheck source=scripts/guest/lib.sh
source "$root/scripts/guest/lib.sh"
n=0 failed=0
ok() { n=$((n + 1)); echo "ok $n - $1"; }
nok() { n=$((n + 1)); failed=$((failed + 1)); echo "not ok $n - $1"; [[ -z "${2:-}" ]] || sed 's/^/#   /' <<<"$2"; }
eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else nok "$1" "expected: <$2>"$'\n'"actual:   <$3>"; fi; }

guest_exec 'uci set adblock-fast-monitor.config.enabled=1; uci commit adblock-fast-monitor
	/etc/init.d/adblock-fast-monitor enable; reload_config; sleep 2'
eq "init script starts before dnsmasq" "S18adblock-fast-monitor S19dnsmasq" \
	"$(guest_exec 'cd /etc/rc.d && ls S18adblock-fast-monitor S19dnsmasq | tr "\n" " " | sed "s/ $//"')"

guest_reboot || { nok "guest reboots"; echo "1..$n"; exit 1; }
ok "guest reboots"
# The harness keeps its files in /tmp (tmpfs); put them back for later tests.
guest_exec 'mkdir -p /tmp/abfm-test/tests'
guest_copy_dir "$root/test/lib" /tmp/abfm-test/lib
guest_copy_dir "$root/test/fixtures" /tmp/abfm-test/fixtures
[[ -n "${PACKAGE_APK:-}" ]] && guest_copy "$PACKAGE_APK" /tmp/abfm-test/package.apk

guest_exec 'i=0; until ubus list adblock-fast-monitor >/dev/null 2>&1 && pidof dnsmasq >/dev/null; do i=$((i+1)); [ $i -lt 60 ] || exit 1; sleep 1; done' ||
	nok "monitor object and dnsmasq are up after boot"

section=$(guest_exec "uci -q -X show dhcp | sed -n 's/^dhcp\\.\\([^.=]*\\)=dnsmasq\$/\\1/p' | head -n1")
eq "drop-in present after boot" "log-queries=extra" "$(guest_exec "cat /tmp/dnsmasq.$section.d/adblock-fast-monitor.conf")"
eq "one daemon and one logread after boot" "1 1" \
	"$(guest_exec "echo \$(pgrep -f '^/usr/bin/ucode /usr/libexec/adblock-fast-monitor/monitord.uc' | wc -l) \$(pgrep -f '^/sbin/logread -f -e' | wc -l)")"
eq "dnsmasq started exactly once since boot" 1 "$(guest_exec "logread | grep -c 'dnsmasq\\[[0-9]*\\]: started, version'")"
eq "the monitor did not restart dnsmasq at boot" 0 "$(guest_exec "logread | grep -c 'restarting dnsmasq'")"
eq "the daemon started before dnsmasq (lower pid)" true "$(guest_exec "m=\$(ubus call service list '{\"name\":\"adblock-fast-monitor\"}' | jsonfilter -e '@[*].instances.instance1.pid'); \
	d=\$(ubus call service list '{\"name\":\"dnsmasq\"}' | jsonfilter -e '@.dnsmasq.instances[*].pid' | head -n1); \
	[ \"\$m\" -lt \"\$d\" ] && echo true || echo false")"

# dnsmasq logs queries from its first start: a LAN query is counted.
python3 "$here/dataplane-lib/dnsq.py" 127.0.0.1 "$GUEST_DNS_PORT" A localhost >/dev/null
sleep 2
eq "a LAN query after boot is counted" 1 "$(guest_exec "ubus call adblock-fast-monitor status | jsonfilter -e '@.counters.queries'")"

guest_exec 'uci set adblock-fast-monitor.config.enabled=0; uci commit adblock-fast-monitor; reload_config; sleep 2
	i=0; while pgrep -f "^/usr/bin/ucode /usr/libexec/adblock-fast-monitor/monitord.uc" >/dev/null; do i=$((i+1)); [ $i -lt 20 ] || break; sleep 1; done' ||
	nok "monitor disabled again"
echo "1..$n"
((failed == 0)) || { echo "# $failed of $n failed"; exit 1; }
