#!/bin/sh
# Run on a stock OpenWrt guest after package installation. This verifies the
# public UCI boolean and dnsmasq's generated detailed logging mode.
set -eu

base=/tmp/adblock-fast-monitor-logqueries-regression
state="$base/state"
runtime="$base/runtime"
saved="$(uci -q get dhcp.@dnsmasq[0].logqueries || true)"
restore() {
	if [ -n "$saved" ]; then
		uci -q set "dhcp.@dnsmasq[0].logqueries=$saved"
	else
		uci -q delete dhcp.@dnsmasq[0].logqueries
	fi
	uci -q commit dhcp
	/etc/init.d/dnsmasq reload >/dev/null 2>&1 || true
	rm -rf "$base"
}
trap restore EXIT INT TERM

uci -q set dhcp.@dnsmasq[0].logqueries=0
uci -q commit dhcp
. /usr/lib/adblock-fast-monitor/common.sh
ADBLOCK_FAST_MONITOR_STATE="$state"
ADBLOCK_FAST_MONITOR_RUNTIME="$runtime"
MONITOR_STATE="$state"
MONITOR_RUNTIME="$runtime"
MONITOR_DNS_OWNER="$runtime/dnsmasq-logqueries.owner"
MONITOR_ACTIVITY="$state/activity.tsv"
MONITOR_STATUS="$state/status"
MONITOR_COUNT="$state/activity.count"
MONITOR_GENERATION="$state/generation"
MONITOR_LOCK="$state/monitor.lock"

monitor_state_init
monitor_dnsmasq_acquire
test "$(uci -q get dhcp.@dnsmasq[0].logqueries)" = 1
/etc/init.d/dnsmasq reload
grep -Rqx 'log-queries=extra' /var/etc/dnsmasq.conf*
monitor_dnsmasq_release
test "$(uci -q get dhcp.@dnsmasq[0].logqueries)" = 0

# A live user edit must not be overwritten by a stale monitor-owned record.
monitor_dnsmasq_acquire
uci -q set dhcp.@dnsmasq[0].logqueries=0
uci -q commit dhcp
monitor_dnsmasq_release
test "$(uci -q get dhcp.@dnsmasq[0].logqueries)" = 0
