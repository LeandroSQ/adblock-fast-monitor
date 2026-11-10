#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Regenerates the `log read` reply fixtures in this directory from a real
# OpenWrt 25.12.6 guest: real logd, real dnsmasq 2.93 with
# `log-queries=extra` (enabled here by a drop-in, as logging.uc does) and
# real adblock-fast serving test/fixtures/lists/primary.txt. Run through the
# guest harness (the package itself is not needed):
#
#   npm run verify:guest -- --no-install --no-tests \
#     --host-cmd test/fixtures/logread/capture.sh PACKAGE.apk
#
# Each fixture is the exact reply of
#   ubus call log read '{"lines":900,"stream":false,"oneshot":true}'
# trimmed to the entries from this script's `abfm-capture: begin-*` marker
# on (which is what a smaller `lines` would have returned).
#
#   servers.json         adblock-fast dns=dnsmasq.servers, then a later query so
#                        the unanswered err.example.test is > 10 s old
#   addnhosts.json       the same with dns=dnsmasq.addnhosts
#   restart.json         a query in flight, `dnsmasq restart`, queries again
#   logd-before.json     `log restart` (logd's ids start again at 0) between
#   logd-after.json      the two replies
#
# Queries come from the host side of QEMU user networking (10.0.2.2) and from
# the router itself (127.0.0.1, ::1). Names are RFC 2606/6761 test names and
# RFC 5737/3849 addresses only. cn.example.test is served by a second local
# dnsmasq with a two-step CNAME chain and a multi-record (2 A, 1 AAAA) target.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
lib="$root/test/guest/dataplane-lib"
q() { python3 "$lib/dnsq.py" 127.0.0.1 "$GUEST_DNS_PORT" "$@" >/dev/null; }

guest_copy_dir "$lib" /tmp/abfm-dp
guest_exec ". /tmp/abfm-dp/guest.sh
	mkdir -p \"\$DP_CONFDIR\"
	printf 'log-queries=extra\\nlog-async=25\\n' >\"\$DP_CONFDIR/adblock-fast-monitor.conf\"
	printf '%s\\n' '192.0.2.30 target.cn.example.test' '192.0.2.31 target.cn.example.test' \
		'2001:db8::30 target.cn.example.test' >/tmp/abfm-ql-cn.hosts
	dnsmasq --conf-file=/dev/null --keep-in-foreground --port=5301 --listen-address=127.0.0.1 \
		--bind-interfaces --no-resolv --no-hosts --addn-hosts=/tmp/abfm-ql-cn.hosts --local-ttl=1 \
		--user=root --pid-file= --cname=alias.cn.example.test,target.cn.example.test \
		--cname=alias2.cn.example.test,alias.cn.example.test >/dev/null 2>&1 &
	echo \$! >/tmp/abfm-ql-cn.pid
	printf 'server=/cn.example.test/127.0.0.1#5301\\n' >\"\$DP_CONFDIR/abfm-ql-cn.conf\"
	dp_upstream_start"

# fetch NAME MARKER: the log read reply, trimmed to the entries from MARKER on.
fetch() {
	guest_exec "ubus call log read '{\"lines\":900,\"stream\":false,\"oneshot\":true}'" >"$here/$1.raw"
	node -e '
		const fs = require("fs");
		const [file, marker] = process.argv.slice(1);
		const reply = JSON.parse(fs.readFileSync(file + ".raw", "utf8"));
		const at = reply.log.findIndex((e) => e.msg === "abfm-capture: " + marker);
		if (at < 0) throw new Error("marker " + marker + " not in reply");
		const log = reply.log.slice(at);
		fs.writeFileSync(file, "{\"log\":[\n" + log.map((e) => JSON.stringify(e)).join(",\n") + "\n]}\n");
		console.log("captured " + log.length + " entries into " + file);
	' "$here/$1" "$2"
	rm -f "$here/$1.raw"
}

queries() {
	q A ads.example.test sub.ads.example.test telemetry.example.test metrics.example.test
	q AAAA ads.example.test
	q HTTPS ads.example.test
	q A www.up.example.test www.up.example.test
	q AAAA www.up.example.test
	q HTTPS www.up.example.test
	q A nx.example.test err.example.test localhost openwrt.lan wpad printer.local
	q A alias2.cn.example.test alias.cn.example.test target.cn.example.test
	q AAAA alias2.cn.example.test
	q PTR 1.0.0.10.in-addr.arpa 1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.d.f.ip6.arpa
	q A 'victim.example.com is 0.0.0.0.example.test' 'bad\x01name.example.test' 'MiXeD.Example.Test'
	guest_exec "nslookup ads.example.test 127.0.0.1 >/dev/null 2>&1; nslookup www.up.example.test ::1 >/dev/null 2>&1; true"
}

capture() { # mode file
	guest_exec ". /tmp/abfm-dp/guest.sh && dp_af_setup dnsmasq.$1 '$GUEST_FIXTURE_URL/lists/primary.txt' && logger -t abfm-capture begin-$1"
	queries
	# err.example.test never gets an answer; a query 11 s later (log time)
	# lets the 10 s pending TTL expire it.
	sleep 11
	q A www.up.example.test
	guest_exec "sleep 1"
	fetch "$1.json" "begin-$1"
}

capture servers
capture addnhosts

guest_exec "logger -t abfm-capture begin-restart"
q A ads.example.test www.up.example.test
python3 "$lib/dnsq.py" 127.0.0.1 "$GUEST_DNS_PORT" A err.example.test >/dev/null 2>&1 &
guest_exec "sleep 1; /etc/init.d/dnsmasq restart; . /tmp/abfm-dp/guest.sh; dp_wait 20 nslookup a.up.example.test 127.0.0.1"
wait || true
q A ads.example.test www.up.example.test alias2.cn.example.test
guest_exec "sleep 1"
fetch restart.json begin-restart

guest_exec "logger -t abfm-capture begin-logd"
q A ads.example.test www.up.example.test
guest_exec "sleep 1"
fetch logd-before.json begin-logd
guest_exec "/etc/init.d/log restart; . /tmp/abfm-dp/guest.sh; dp_wait 20 sh -c 'ubus list log' && sleep 1 && logger -t abfm-capture begin-logd-after"
# Probe whether dnsmasq logs again after a logd restart. Observed on 25.12.6
# (dnsmasq 2.93): it does not (60 queries over 30 s, no dnsmasq line), so
# logd-after.json holds no dnsmasq lines (presumably until dnsmasq
# restarts; not verified here).
for i in $(seq 1 30); do
	q A ads.example.test www.up.example.test
	if guest_exec "ubus call log read '{\"lines\":100,\"stream\":false,\"oneshot\":true}' | grep -q 'query\\[A\\] www.up.example.test from 10.0.2.2'"; then
		echo "dnsmasq logged again after logd restart (attempt $i)"
		break
	fi
	sleep 1
done
guest_exec "sleep 1"
fetch logd-after.json begin-logd-after

guest_exec ". /tmp/abfm-dp/guest.sh; kill \"\$(cat /tmp/abfm-ql-cn.pid)\"; rm -f \"\$DP_CONFDIR/abfm-ql-cn.conf\" /tmp/abfm-ql-cn.hosts
	dp_upstream_stop; rm -f \"\$DP_CONFDIR/adblock-fast-monitor.conf\""
