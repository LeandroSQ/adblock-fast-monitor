#!/usr/bin/env bash
set -euo pipefail

: "${OPENWRT_HOST:?}"
: "${OPENWRT_SSH_PORT:?}"
: "${OPENWRT_SSH_KEY:?}"
: "${FIXTURE_LIST_URL:?}"

ssh_opts=(-i "$OPENWRT_SSH_KEY" -p "$OPENWRT_SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new)
remote() { ssh "${ssh_opts[@]}" "root@$OPENWRT_HOST" "$@"; }

remote "
	set -eu
	wget -qO /root/adblock-fast-monitor-test/lists/primary.txt '$FIXTURE_LIST_URL/primary.txt'
	grep -qx '0.0.0.0 ads.example.test' /root/adblock-fast-monitor-test/lists/primary.txt
	uci -q add_list dhcp.@dnsmasq[0].addnhosts=/root/adblock-fast-monitor-test/lists/primary.txt
	uci set dhcp.@dnsmasq[0].logqueries=0
	uci commit dhcp
	/etc/init.d/dnsmasq restart
	uci set adblock-fast-monitor.config.own_logqueries=1
	uci commit adblock-fast-monitor
	/etc/init.d/adblock-fast-monitor start
	test -f /var/run/adblock-fast-monitor/dnsmasq-logqueries.owner
	test \"\$(stat -c '%u:%a' /var/run/adblock-fast-monitor/dnsmasq-logqueries.owner)\" = '0:600'
	test \"\$(uci -q get dhcp.@dnsmasq[0].logqueries)\" = 1
	uci set adblock-fast-monitor.config.own_logqueries=0
	uci commit adblock-fast-monitor
	/etc/init.d/adblock-fast-monitor restart
	test ! -e /var/run/adblock-fast-monitor/dnsmasq-logqueries.owner
	test \"\$(uci -q get dhcp.@dnsmasq[0].logqueries)\" = 0
	ubus call adblock-fast-monitor status >/dev/null
	ubus call adblock-fast-monitor activity '{\"limit\":1}' >/dev/null
	action=\$(ubus call adblock-fast-monitor-actions action '{\"action\":\"allow\",\"domain\":\"allowed.example.test\",\"confirm_rebuild\":false}')
	printf '%s' \"\$action\" | jsonfilter -e '@.accepted' | grep -Eq 'true|1'
	ubus call adblock-fast-monitor-actions job '{}' >/dev/null
"

for _ in $(seq 1 30); do
	if dig +short @127.0.0.1 -p 5353 ads.example.test | grep -qx '0.0.0.0'; then
		scripts/integration/runtime-domain-actions.sh
		exit 0
	fi
	sleep 1
done
echo 'dnsmasq did not apply the deterministic local fixture list' >&2
exit 1
