#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# T08 at boot / P1 / P10 (docs/CONTRACT.md §4, §5): with query_logging=1 a
# reboot writes the drop-in before dnsmasq starts (START=18 < 19), so dnsmasq
# starts once, already logging, is never restarted by the package, and no
# package process runs after boot. A LAN query then shows up in `log read`.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
# shellcheck source=scripts/guest/lib.sh
source "$root/scripts/guest/lib.sh"
n=0 failed=0
ok() { n=$((n + 1)); echo "ok $n - $1"; }
nok() { n=$((n + 1)); failed=$((failed + 1)); echo "not ok $n - $1"; [[ -z "${2:-}" ]] || sed 's/^/#   /' <<<"$2"; }
eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else nok "$1" "expected: <$2>"$'\n'"actual:   <$3>"; fi; }
# Leave the monitor config byte-identical for later tests (package §3 checks).
guest_exec 'cp /etc/config/adblock-fast-monitor /root/.abfm-boot-config.bak'
trap "guest_exec 'cp /root/.abfm-boot-config.bak /etc/config/adblock-fast-monitor; rm -f /root/.abfm-boot-config.bak'" EXIT

guest_exec '. /tmp/abfm-test/lib/sh/testlib.sh; uci set adblock-fast-monitor.config.query_logging=1; uci commit adblock-fast-monitor
	/etc/init.d/adblock-fast-monitor enable; reload_config
	abfm_wait_until 30 sh -c "ls /tmp/dnsmasq*.d/adblock-fast-monitor.conf"; flock /var/lock/adblock-fast-monitor.logging.lock true' ||
	nok "query logging switched on before the reboot"
eq "init script starts before dnsmasq" "S18adblock-fast-monitor S19dnsmasq" \
	"$(guest_exec 'cd /etc/rc.d && ls S18adblock-fast-monitor S19dnsmasq | tr "\n" " " | sed "s/ $//"')"

guest_reboot || { nok "guest reboots"; echo "1..$n"; exit 1; }
ok "guest reboots"
# The harness keeps its files in /tmp (tmpfs); put them back for later tests.
guest_exec 'mkdir -p /tmp/abfm-test/tests'
guest_copy_dir "$root/test/lib" /tmp/abfm-test/lib
guest_copy_dir "$root/test/fixtures" /tmp/abfm-test/fixtures
[[ -n "${PACKAGE_APK:-}" ]] && guest_copy "$PACKAGE_APK" /tmp/abfm-test/package.apk

guest_exec 'i=0; until pidof dnsmasq >/dev/null && nslookup localhost 127.0.0.1 >/dev/null 2>&1; do i=$((i+1)); [ $i -lt 60 ] || exit 1; sleep 1; done' ||
	nok "dnsmasq is up after boot"

section=$(guest_exec "uci -q -X show dhcp | sed -n 's/^dhcp\\.\\([^.=]*\\)=dnsmasq\$/\\1/p' | head -n1")
eq "drop-in present after boot" "log-queries=extra log-async=25" "$(guest_exec "cat /tmp/dnsmasq.$section.d/adblock-fast-monitor.conf" | tr '\n' ' ' | sed 's/ $//')"
eq "dnsmasq started exactly once since boot" 1 "$(guest_exec "logread | grep -c 'dnsmasq\\[[0-9]*\\]: started, version'")"
eq "the package did not restart dnsmasq at boot" 0 "$(guest_exec "logread | grep -c 'restarting dnsmasq'")"
# P1: sample /proc for 10 s (every 250 ms) so a short-lived respawn is seen too
# (a measurement window, not a wait). The patterns are split so this shell's
# own command line never matches. A short-lived logging.uc (the
# instance.update trigger reconciling after the boot-time service starts) is
# allowed (§1).
procs=$(guest_exec 'a=/usr/libexec/adblock-fast; b=-monitor/; l=logread; f=" -f"; end=$(($(date +%s) + 10)); while [ $(date +%s) -lt $end ]; do
	for p in /proc/[0-9]*; do c=$(tr "\0" " " <$p/cmdline 2>/dev/null); case "$c" in *"$a$b"logging.uc*) ;; *"$a$b"*|*"$l$f"*) echo "$c";; esac; done
	usleep 250000 2>/dev/null || sleep 1; done | sort -u')
eq "no package process after boot (10 s /proc watch)" "" "$procs"
eq "procd has no instance for the package" "" \
	"$(guest_exec "ubus call service list '{\"name\":\"adblock-fast-monitor\"}' | jsonfilter -e '@[\"adblock-fast-monitor\"].instances'" || true)"

# dnsmasq logs queries from its first start: a LAN query is in logd's ring.
python3 "$here/dataplane-lib/dnsq.py" 127.0.0.1 "$GUEST_DNS_PORT" A boot-probe.example.test >/dev/null
# log-async: the line reaches logd shortly after the answer; poll the ring.
eq "a LAN query after boot is in log read (once)" 1 "$(guest_exec sh <<'SH'
. /tmp/abfm-test/lib/sh/testlib.sh
count() { ubus call log read '{"lines":200,"stream":false,"oneshot":true}' | grep -c 'query\[A\] boot-probe.example.test from 10.0.2.2'; }
seen() { [ "$(count)" -ge 1 ]; }
abfm_wait_until 20 seen
count
SH
)"

guest_exec '. /tmp/abfm-test/lib/sh/testlib.sh; uci set adblock-fast-monitor.config.query_logging=0; uci commit adblock-fast-monitor; reload_config
	abfm_wait_until 30 sh -c "! ls /tmp/dnsmasq*.d/adblock-fast-monitor.conf"; flock /var/lock/adblock-fast-monitor.logging.lock true' ||
	nok "query logging disabled again"
echo "1..$n"
((failed == 0)) || { echo "# $failed of $n failed"; exit 1; }
