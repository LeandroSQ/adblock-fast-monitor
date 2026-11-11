#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Live data path (docs/CONTRACT.md §5, §8.1) on the real guest: with
# query_logging=1 the drop-in makes the real dnsmasq 2.93 log every query, in
# `log-queries=extra` form, into logd, and core `log read` (what the page
# polls) returns those lines with consecutive ids. Real adblock-fast serves
# the local fixture list in dnsmasq.servers and dnsmasq.addnhosts modes;
# queries come from the host side of QEMU user networking (10.0.2.2).
# Parsing and classification are the browser's job (querylog.js, unit tests).
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/dataplane-lib"
n=0 failed=0

ok() { n=$((n + 1)); echo "ok $n - $1"; }
nok() { n=$((n + 1)); failed=$((failed + 1)); echo "not ok $n - $1"; [[ -z "${2:-}" ]] || sed 's/^/#   /' <<<"$2"; }
eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else nok "$1" "expected: <$2>"$'\n'"actual:   <$3>"; fi; }
G() { guest_exec ". /tmp/abfm-dp/guest.sh; $*"; }
q() { python3 "$lib/dnsq.py" 127.0.0.1 "$GUEST_DNS_PORT" "$@" >/dev/null; }
# logjson: the newest 200 entries, as the page fetches them
logjson() { guest_exec "ubus call log read '{\"lines\":200,\"stream\":false,\"oneshot\":true}'"; }
# has JSON REGEX: 1 when some entry's msg matches the Python regex
has() { python3 -c 'import json,re,sys; d=json.loads(sys.argv[1]); print(int(any(re.search(sys.argv[2], e["msg"]) for e in d["log"])))' "$1" "$2"; }

guest_copy_dir "$lib" /tmp/abfm-dp
guest_exec 'cp /etc/config/adblock-fast-monitor /tmp/abfm-live-monitor.bak; cp /etc/config/adblock-fast /tmp/abfm-live-af.bak; cp /etc/config/dhcp /tmp/abfm-live-dhcp.bak'
# adblock-fast's addnhosts mode edits dhcp (addnhosts) and leaves uncommitted
# UCI changes; restore all of it.
# Applied here, synchronously (dnsmasq restart, bookkeeping without events),
# so nothing restarts after this file ends.
trap "guest_exec '. /tmp/abfm-test/lib/sh/testlib.sh; . /tmp/abfm-test/fixtures/actions/guest-lib.sh
	cp /tmp/abfm-live-monitor.bak /etc/config/adblock-fast-monitor; cp /tmp/abfm-live-af.bak /etc/config/adblock-fast
	cp /tmp/abfm-live-dhcp.bak /etc/config/dhcp; rm -f /tmp/abfm-live-*.bak /tmp/.uci/dhcp /tmp/.uci/adblock-fast
	/etc/init.d/dnsmasq restart; config_ack; abfm_wait_until 30 nslookup localhost 127.0.0.1'" EXIT
G 'reload_config; dp_upstream_start' || nok "fake upstream starts"

q A before-logging.example.test
eq "T09: query_logging=0: dnsmasq logs no queries" 0 "$(has "$(logjson)" 'query\[A\] before-logging\.example\.test')"
G 'dp_mon_set query_logging=1; reload_config; dp_wait 30 sh -c "ls /tmp/dnsmasq*.d/adblock-fast-monitor.conf"; dp_wait 30 nslookup a.up.example.test 127.0.0.1' ||
	nok "T09: query logging switches on"

run_mode() { # mode blocked-line-regex
	local mode=$1 block=$2 j
	echo "# --- $mode"
	if ! G "dp_af_setup $mode '$GUEST_FIXTURE_URL/lists/primary.txt'"; then
		nok "T09: $mode: adblock-fast serves the fixture list"
		return
	fi
	ok "T09: $mode: adblock-fast serves the fixture list"
	q A ads.example.test www.up.example.test
	q A www.up.example.test
	# dnsmasq hands lines to logd asynchronously (log-async): wait until the
	# last one (the cached answer) is in the ring, then read once.
	for _ in $(seq 20); do
		j=$(logjson)
		[[ "$(has "$j" 'cached www\.up\.example\.test is ')" == 1 ]] && break
		guest_exec 'sleep 1'
	done
	eq "T09: $mode: the client's query line is logged with serial and client/port" 1 \
		"$(has "$j" '^dnsmasq\[[0-9]+\]: [0-9]+ 10\.0\.2\.2/[0-9]+ query\[A\] ads\.example\.test from 10\.0\.2\.2$')"
	eq "T09: $mode: the blocked answer is logged" 1 "$(has "$j" "$block")"
	eq "T09: $mode: the forwarded reply is logged" 1 \
		"$(has "$j" '^dnsmasq\[[0-9]+\]: [0-9]+ 10\.0\.2\.2/[0-9]+ reply www\.up\.example\.test is 192\.0\.2\.10$')"
	eq "T09: $mode: the second lookup is answered from cache" 1 \
		"$(has "$j" '^dnsmasq\[[0-9]+\]: [0-9]+ 10\.0\.2\.2/[0-9]+ cached www\.up\.example\.test is 192\.0\.2\.10$')"
	eq "T09: $mode: log ids are consecutive (the page's cursor and gap detector)" true \
		"$(python3 -c 'import json,sys; ids=[e["id"] for e in json.loads(sys.argv[1])["log"]]; print(str(ids == list(range(ids[0], ids[0] + len(ids)))).lower())' "$j")"
	eq "T09: $mode: entries carry time and source fields" true \
		"$(python3 -c 'import json,sys; e=json.loads(sys.argv[1])["log"][-1]; print(str(all(k in e for k in ("msg","id","time","priority","source"))).lower())' "$j")"
}

run_mode dnsmasq.servers '^dnsmasq\[[0-9]+\]: [0-9]+ 10\.0\.2\.2/[0-9]+ config ads\.example\.test is NXDOMAIN$'
run_mode dnsmasq.addnhosts '^dnsmasq\[[0-9]+\]: [0-9]+ 10\.0\.2\.2/[0-9]+ /var/run/adblock-fast/dnsmasq\.addnhosts ads\.example\.test is (0\.0\.0\.0|127\.0\.0\.1)$'

G 'dp_mon_set query_logging=0; reload_config; dp_wait 30 sh -c "! ls /tmp/dnsmasq*.d/adblock-fast-monitor.conf"; dp_upstream_stop;
	uci set adblock-fast.config.enabled=0; uci commit adblock-fast; /etc/init.d/adblock-fast stop >/dev/null 2>&1; :'
q A after-logging.example.test
eq "T09: query_logging=0 again: no more query lines" 0 "$(has "$(logjson)" 'query\[A\] after-logging\.example\.test')"
echo "1..$n"
((failed == 0)) || { echo "# $failed of $n failed"; exit 1; }
