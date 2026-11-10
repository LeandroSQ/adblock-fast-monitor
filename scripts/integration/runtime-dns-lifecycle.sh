#!/usr/bin/env bash
set -euo pipefail

: "${OPENWRT_HOST:?}"
: "${OPENWRT_SSH_PORT:?}"
: "${OPENWRT_SSH_KEY:?}"
: "${FIXTURE_LIST_URL:?}"

ssh_opts=(-i "$OPENWRT_SSH_KEY" -p "$OPENWRT_SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new)
remote() { ssh "${ssh_opts[@]}" "root@$OPENWRT_HOST" "$@"; }
dns_port="${OPENWRT_DNS_PORT:-5353}"
# Stock BusyBox has no stat applet: ownership checks use the shared ucode helper.
remote 'mkdir -p /root/adblock-fast-monitor-test && cat > /root/adblock-fast-monitor-test/testlib.sh' \
	<"$(dirname "${BASH_SOURCE[0]}")/../../test/lib/sh/testlib.sh"

remote "
	set -eu
	. /root/adblock-fast-monitor-test/testlib.sh
	wget -qO /root/adblock-fast-monitor-test/lists/primary.txt '$FIXTURE_LIST_URL/primary.txt'
	grep -qx '0.0.0.0 ads.example.test' /root/adblock-fast-monitor-test/lists/primary.txt
	uci -q add_list dhcp.@dnsmasq[0].addnhosts=/root/adblock-fast-monitor-test/lists/primary.txt
	uci set dhcp.@dnsmasq[0].logqueries=0
	uci commit dhcp
	/etc/init.d/dnsmasq restart
	ABFM_RESOLVER_ARTIFACTS=/root/adblock-fast-monitor-test/dns-lifecycle-ready
	. /root/adblock-fast-monitor-test/dns-resolver-readiness.sh
	abfm_wait_dns_a_fixture ads.example.test 0.0.0.0
	uci set adblock-fast-monitor.config.own_logqueries=1
	uci commit adblock-fast-monitor
	/etc/init.d/adblock-fast-monitor start
	abfm_wait_dns_a_fixture ads.example.test 0.0.0.0
	test -f /var/run/adblock-fast-monitor/dnsmasq-logqueries.owner
	test \"\$(abfm_stat '%u:%a' /var/run/adblock-fast-monitor/dnsmasq-logqueries.owner)\" = '0:600'
	test \"\$(uci -q get dhcp.@dnsmasq[0].logqueries)\" = 1
	uci set adblock-fast-monitor.config.own_logqueries=0
	uci commit adblock-fast-monitor
	/etc/init.d/adblock-fast-monitor restart
	abfm_wait_dns_a_fixture ads.example.test 0.0.0.0
	test ! -e /var/run/adblock-fast-monitor/dnsmasq-logqueries.owner
	test \"\$(uci -q get dhcp.@dnsmasq[0].logqueries)\" = 0
	ubus call adblock-fast-monitor status >/dev/null
	ubus call adblock-fast-monitor activity '{\"limit\":1}' >/dev/null
	action=\$(ubus call adblock-fast-monitor-actions action '{\"action\":\"allow\",\"domain\":\"allowed.example.test\",\"confirm_rebuild\":false}')
	printf '%s' \"\$action\" | jsonfilter -e '@.accepted' | grep -Eq 'true|1'
	ubus call adblock-fast-monitor-actions job '{}' >/dev/null
"

for _ in $(seq 1 30); do
	if dig +short @127.0.0.1 -p "$dns_port" ads.example.test | grep -qx '0.0.0.0'; then
		scripts/integration/runtime-domain-actions.sh
		exit 0
	fi
	sleep 1
done
echo 'dnsmasq did not apply the deterministic local fixture list' >&2
exit 1
