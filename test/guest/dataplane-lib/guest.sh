# shellcheck shell=sh
# Guest-side helpers for the data-plane tests (BusyBox ash on OpenWrt).
# Source after copying to the guest:  . /tmp/abfm-dp/guest.sh
#
#   dp_af_setup MODE LIST_URL   adblock-fast with one local fixture list, DNS
#                               mode MODE (dnsmasq.servers | dnsmasq.addnhosts),
#                               started and verified (statusSuccess + output file)
#   dp_upstream_start           fake upstream dnsmasq on 127.0.0.1:5300 for
#                               *.up.example.test (A 192.0.2.10, AAAA
#                               2001:db8::10, TTL 300; HTTPS -> REFUSED) and
#                               nx.example.test (NXDOMAIN); err.example.test is
#                               forwarded to a dead port (no answer)
#   dp_upstream_stop
#   dp_mon_set KEY=VALUE...     set adblock-fast-monitor.config options + commit
#   dp_wait SECS CMD...         poll CMD every second until it succeeds
#   dp_dnsmasq_pid              pid of the main dnsmasq instance (procd)
#   dp_mon_pid                  pid of the monitor daemon (procd), empty if none

DP_CONFDIR=${DP_CONFDIR:-/tmp/dnsmasq.$(uci -q -X show dhcp | sed -n 's/^dhcp\.\([^.=]*\)=dnsmasq$/\1/p' | head -n1).d}
DP_UPSTREAM_CONF=$DP_CONFDIR/abfm-test-upstream.conf

dp_wait() {
	local deadline=$(($(date +%s) + $1))
	shift
	until "$@" >/dev/null 2>&1; do
		[ "$(date +%s)" -lt "$deadline" ] || return 1
		sleep 1
	done
}

dp_af_status() {
	ubus call service list '{"name":"adblock-fast"}' 2>/dev/null |
		jsonfilter -e '@["adblock-fast"].data.status' 2>/dev/null
}

dp_af_setup() {
	local mode=$1 url=$2 out
	case "$mode" in
		dnsmasq.servers) out=/var/run/adblock-fast/dnsmasq.servers ;;
		dnsmasq.addnhosts) out=/var/run/adblock-fast/dnsmasq.addnhosts ;;
		*) echo "dp_af_setup: unsupported mode $mode" >&2; return 1 ;;
	esac
	while uci -q delete adblock-fast.@file_url[0]; do :; done
	uci add adblock-fast file_url >/dev/null
	uci set adblock-fast.@file_url[-1].name=abfm-fixture
	uci set adblock-fast.@file_url[-1].url="$url"
	uci set adblock-fast.@file_url[-1].action=block
	uci set adblock-fast.@file_url[-1].enabled=1
	uci set adblock-fast.config.enabled=1
	uci set adblock-fast.config.dns="$mode"
	uci set adblock-fast.config.config_update_enabled=0
	uci commit adblock-fast
	/etc/init.d/adblock-fast restart >/tmp/abfm-dp-af.log 2>&1
	dp_wait 60 sh -c '[ "$(ubus call service list "{\"name\":\"adblock-fast\"}" | jsonfilter -e "@[\"adblock-fast\"].data.status")" = statusSuccess ]' ||
		{ cat /tmp/abfm-dp-af.log >&2; return 1; }
	[ -s "$out" ] || { echo "dp_af_setup: $out missing" >&2; return 1; }
}

dp_upstream_start() {
	dp_upstream_stop
	dnsmasq --conf-file=/dev/null --keep-in-foreground --port=5300 --listen-address=127.0.0.1 \
		--bind-interfaces --no-resolv --no-hosts --local-ttl=300 --user=root --pid-file= \
		--address=/up.example.test/192.0.2.10 --address=/up.example.test/2001:db8::10 \
		--address=/nx.example.test/ >/dev/null 2>&1 &
	echo $! >/tmp/abfm-dp-upstream.pid
	mkdir -p "$DP_CONFDIR"
	printf '%s\n' 'server=/up.example.test/127.0.0.1#5300' 'server=/nx.example.test/127.0.0.1#5300' \
		'server=/err.example.test/127.0.0.1#5309' 'rebind-domain-ok=/example.test/' >"$DP_UPSTREAM_CONF"
	/etc/init.d/dnsmasq restart
	dp_wait 20 nslookup a.up.example.test 127.0.0.1
}

dp_upstream_stop() {
	[ -s /tmp/abfm-dp-upstream.pid ] && kill "$(cat /tmp/abfm-dp-upstream.pid)" 2>/dev/null
	rm -f /tmp/abfm-dp-upstream.pid
	if [ -e "$DP_UPSTREAM_CONF" ]; then
		rm -f "$DP_UPSTREAM_CONF"
		/etc/init.d/dnsmasq restart
	fi
	return 0
}

dp_mon_set() {
	local kv
	for kv in "$@"; do
		uci set "adblock-fast-monitor.config.$kv"
	done
	uci commit adblock-fast-monitor
}

dp_dnsmasq_pid() {
	ubus call service list '{"name":"dnsmasq"}' 2>/dev/null | jsonfilter -e '@.dnsmasq.instances[*].pid' | head -n1
}

dp_mon_pid() {
	ubus call service list '{"name":"adblock-fast-monitor"}' 2>/dev/null |
		jsonfilter -e '@["adblock-fast-monitor"].instances[*].pid' | head -n1
}
