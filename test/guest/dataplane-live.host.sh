#!/usr/bin/env bash
# T09, T05 (guest half), T10 and live T02 (docs/CONTRACT.md §4.3-4.6) on the
# real guest: real dnsmasq 2.93 and real adblock-fast in dnsmasq.servers and
# dnsmasq.addnhosts modes, serving the local fixture list. Queries come from
# the host side of QEMU user networking (10.0.2.2, a non-router source); the
# results are read back through `ubus call adblock-fast-monitor ...`.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/dataplane-lib"
n=0 failed=0

ok() { n=$((n + 1)); echo "ok $n - $1"; }
nok() { n=$((n + 1)); failed=$((failed + 1)); echo "not ok $n - $1"; [[ -z "${2:-}" ]] || sed 's/^/#   /' <<<"$2"; }
eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else nok "$1" "expected: <$2>"$'\n'"actual:   <$3>"; fi; }
G() { guest_exec ". /tmp/abfm-dp/guest.sh; $*"; }
q() { python3 "$lib/dnsq.py" 127.0.0.1 "$GUEST_DNS_PORT" "$@" >/dev/null; }
call() { guest_exec "ubus call adblock-fast-monitor $1 '${2:-{\}}'"; }
# py JSON EXPR: evaluates EXPR with the parsed JSON bound to d.
py() { python3 -c 'import json, sys; d = json.loads(sys.argv[1]); v = eval(sys.argv[2]); print(json.dumps(v) if not isinstance(v, str) else v)' "$1" "$2"; }
# Waits until the daemon has seen the router's own marker query (the log
# pipeline drained up to that point). Router queries are excluded from the
# statistics, so the marker leaves no trace.
settle() { sleep 2; }

guest_copy_dir "$lib" /tmp/abfm-dp
G 'reload_config; sleep 2; dp_upstream_start' || nok "fake upstream starts"
G 'dp_mon_set enabled=1 record_clients=1 exclude_router=1 pending_ttl=2; /etc/init.d/adblock-fast-monitor start;
	dp_wait 20 ubus list adblock-fast-monitor' || nok "monitor starts"

run_mode() { # mode expected-telemetry-source
	local mode=$1 tsrc=$2 st dm
	echo "# --- $mode"
	if ! G "dp_af_setup $mode '$GUEST_FIXTURE_URL/lists/primary.txt'"; then
		nok "$mode: adblock-fast serves the fixture list"
		return
	fi
	ok "$mode: adblock-fast serves the fixture list"
	G 'nslookup localhost 127.0.0.1 >/dev/null; sleep 1'
	eq "$mode: purge" true "$(py "$(call purge)" 'd["ok"]')"

	q A www.up.example.test www.up.example.test
	settle
	dm=$(call domains '{"q":"www.up"}')
	eq "$mode: second identical query is answered from cache (T09)" \
		'["allowed", "cache", 2, 2]' "$(py "$dm" '[d["items"][0][k] for k in ("decision", "source", "count", "allowed")]')"

	q A ads.example.test sub.ads.example.test telemetry.example.test metrics.example.test
	q AAAA ads.example.test www.up.example.test
	q HTTPS ads.example.test www.up.example.test
	q A nx.example.test err.example.test localhost openwrt.lan wpad printer.local mixed.Example.TEST
	q PTR 1.0.0.10.in-addr.arpa 1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.d.f.ip6.arpa
	q A 'victim.example.com is 0.0.0.0.example.test' 'bad\x01name.example.test'
	G 'nslookup ads.example.test 127.0.0.1 >/dev/null 2>&1; nslookup www.up.example.test ::1 >/dev/null 2>&1; :'
	sleep 3   # > pending_ttl: err.example.test (no answer) expires
	st=$(call status)
	eq "$mode: counters (T09)" \
		'{"queries": 19, "blocked": 7, "allowed": 4, "other": 7, "expired": 1, "pending": 0, "rejected_lines": 4, "orphan_lines": 0}' \
		"$(py "$st" '{k: d["counters"][k] for k in ("queries", "blocked", "allowed", "other", "expired", "pending", "rejected_lines", "orphan_lines")}')"
	eq "$mode: no dropped lines at normal rates (log-async)" '{"input_overflow": 0, "pending_evicted": 0, "dnsmasq_reported": 0}' "$(py "$st" 'd["counters"]["dropped"]')"
	eq "$mode: invariant" true "$(py "$st" 'd["counters"]["queries"] == sum(d["counters"][k] for k in ("blocked", "allowed", "other", "expired", "pending")) + d["counters"]["dropped"]["pending_evicted"]')"
	eq "$mode: block_pct" 63.6 "$(py "$st" 'd["block_pct"]')"
	eq "$mode: state running, dns mode reported" '["running", [], "'"$mode"'"]' "$(py "$st" '[d["state"], d["reasons"], d["adblock_fast"]["dns"]]')"

	dm=$(call domains '{"limit":100}')
	local rows='{r["domain"]: [r["decision"], r["source"], r["count"], r["blocked"], r["allowed"], r["qtypes"]] for r in d["items"]}'
	eq "$mode: ads row deduplicated across A/AAAA/HTTPS (T09)" \
		'["blocked", "config", 3, 3, 0, ["A", "AAAA", "HTTPS"]]' "$(py "$dm" "($rows)[\"ads.example.test\"]")"
	eq "$mode: telemetry source" '["blocked", "'"$tsrc"'"]' "$(py "$dm" "($rows)[\"telemetry.example.test\"][:2]")"
	eq "$mode: www.up: reply, cache, reply, then REFUSED (last outcome)" \
		'["other", "error", 4, 0, 3, ["A", "AAAA", "HTTPS"]]' "$(py "$dm" "($rows)[\"www.up.example.test\"]")"
	eq "$mode: upstream NXDOMAIN is allowed/upstream" '["allowed", "upstream"]' "$(py "$dm" "($rows)[\"nx.example.test\"][:2]")"
	eq "$mode: hosts file" '["other", "hosts"]' "$(py "$dm" "($rows)[\"localhost\"][:2]")"
	eq "$mode: local names" '["local", "local", "local", "local", "local"]' \
		"$(py "$dm" "[($rows)[n][1] for n in ('openwrt.lan', 'wpad', 'printer.local', '1.0.0.10.in-addr.arpa', '1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.d.f.ip6.arpa')]")"
	eq "$mode: dnsmasq lower-cases names" '["blocked", "config"]' "$(py "$dm" "($rows)[\"mixed.example.test\"][:2]")"
	eq "$mode: spoofed and unprintable names leave no row (T02 live)" '[]' \
		"$(py "$dm" '[r["domain"] for r in d["items"] if " " in r["domain"] or "<" in r["domain"] or "victim" in r["domain"]]')"
	eq "$mode: unanswered query has no row" false "$(py "$dm" '"err.example.test" in [r["domain"] for r in d["items"]]')"
	eq "$mode: client recorded (record_clients=1)" 10.0.2.2 "$(py "$dm" '[r for r in d["items"] if r["domain"] == "ads.example.test"][0]["client"]')"
	eq "$mode: sorted by last_seen desc, then domain" true \
		"$(py "$dm" 'all((a["last_seen"], b["domain"]) >= (b["last_seen"], a["domain"]) for a, b in zip(d["items"], d["items"][1:]))')"

	dm=$(call domains '{"view":"top_blocked"}')
	eq "$mode: top_blocked" '[["ads.example.test", 3, 0], 5]' "$(py "$dm" '[[d["items"][0][k] for k in ("domain", "count", "error")], d["total"]]')"
	dm=$(call domains '{"view":"top_allowed"}')
	eq "$mode: top_allowed" '[["www.up.example.test", 3], ["nx.example.test", 1]]' "$(py "$dm" '[[i["domain"], i["count"]] for i in d["items"]]')"
	dm=$(call domains '{"decision":"blocked","q":"ADS"}')
	eq "$mode: decision + q filter" '["ads.example.test", "sub.ads.example.test"]' "$(py "$dm" 'sorted(r["domain"] for r in d["items"])')"
	dm=$(call domains '{"offset":1,"limit":2}')
	eq "$mode: paging" '[1, 2, 13]' "$(py "$dm" '[d["offset"], len(d["items"]), d["total"]]')"
}

run_mode dnsmasq.servers config
run_mode dnsmasq.addnhosts addnhosts

echo "# --- T05 over ubus: argument errors"
eq "bad view gives invalid-argument" '[1, false, "invalid-argument"]' "$(py "$(call domains '{"view":"nope"}')" '[d["api"], d["ok"], d["error"]["code"]]')"
eq "bad q gives invalid-argument" invalid-argument "$(py "$(call domains '{"q":"a b"}')" 'd["error"]["code"]')"
eq "negative offset gives invalid-argument" invalid-argument "$(py "$(call domains '{"offset":-1}')" 'd["error"]["code"]')"
eq "limit above 100 is clamped, not rejected" 13 "$(py "$(call domains '{"limit":1000}')" 'len(d["items"])')"
# The ubus CLI prints the status text and exits 256 - status (254 for 2).
out=$(guest_exec "ubus call adblock-fast-monitor domains '{\"limit\":\"5\"}' 2>&1; echo rc=\$?")
eq "mistyped field is refused by ucode-mod-ubus (status 2)" "(Invalid argument) rc=254" "$(grep -o '(Invalid argument)\|rc=[0-9]*' <<<"$out" | tr '\n' ' ' | sed 's/ $//')"
out=$(guest_exec "ubus call adblock-fast-monitor status '{\"bogus\":1}' 2>&1; echo rc=\$?")
eq "undeclared field is refused by ucode-mod-ubus (status 2)" "(Invalid argument) rc=254" "$(grep -o '(Invalid argument)\|rc=[0-9]*' <<<"$out" | tr '\n' ' ' | sed 's/ $//')"

echo "# --- T10: dns-mode-unsupported"
G 'uci set adblock-fast.config.dns=dnsmasq.nftset; uci commit adblock-fast'
st=$(call status)
eq "nftset mode: degraded with dns-mode-unsupported" '["degraded", ["dns-mode-unsupported"], "dnsmasq.nftset"]' \
	"$(py "$st" '[d["state"], d["reasons"], d["adblock_fast"]["dns"]]')"
G 'uci set adblock-fast.config.dns=dnsmasq.addnhosts; uci commit adblock-fast'
eq "back to addnhosts: running" '["running", []]' "$(py "$(call status)" '[d["state"], d["reasons"]]')"

echo "# --- T10: overflow"
G "logger -t 'dnsmasq[1]' \"\$(head -c 1100 /dev/zero | tr '\\0' x)\"; sleep 1"
st=$(call status)
eq "an over-long dnsmasq line raises input-overflow" '["degraded", ["input-overflow"], 1]' \
	"$(py "$st" '[d["state"], d["reasons"], d["counters"]["dropped"]["input_overflow"]]')"
before=$(py "$st" 'd["counters"]["queries"]')
blast=$(python3 "$lib/dnsq.py" --blast 3000 127.0.0.1 "$GUEST_DNS_PORT" A flood.example.test)
echo "# flood: $blast"
sleep 4
st=$(call status)
echo "# after flood: $(py "$st" '{k: d["counters"][k] for k in ("queries", "blocked", "pending", "expired")} | {"dropped": d["counters"]["dropped"], "reasons": d["reasons"]}')"
eq "daemon survives a 3000-query flood with the invariant intact" true \
	"$(py "$st" 'd["ok"] and d["counters"]["queries"] == sum(d["counters"][k] for k in ("blocked", "allowed", "other", "expired", "pending")) + d["counters"]["dropped"]["pending_evicted"]')"
eq "flood queries are counted or reported as dropped" true \
	"$(py "$st" 'd["counters"]["queries"] - '"$before"' + d["counters"]["dropped"]["dnsmasq_reported"] + d["counters"]["dropped"]["pending_evicted"] > 0')"

echo "# --- purge and record_clients=0"
p=$(call purge)
st=$(call status)
eq "purge resets counters and sets purged_at = stats_since" '[0, true, true]' \
	"$(py "$st" '[d["counters"]["queries"], d["daemon"]["purged_at"] == d["daemon"]["stats_since"], d["daemon"]["stats_since"] == '"$(py "$p" 'd["stats_since"]')"']')"
eq "purge empties the recent table" 0 "$(py "$(call domains)" 'd["total"]')"
G 'dp_mon_set record_clients=0; reload_config; sleep 1; dp_wait 20 ubus list adblock-fast-monitor; sleep 1'
q A ads.example.test
settle
eq "record_clients=0: no client field" '[1, false]' "$(py "$(call domains)" '[d["total"], "client" in d["items"][0]]')"

G 'dp_mon_set enabled=0 record_clients=0 pending_ttl=10; reload_config; sleep 2; dp_upstream_stop;
	uci set adblock-fast.config.enabled=0; uci commit adblock-fast; /etc/init.d/adblock-fast stop >/dev/null 2>&1; reload_config; :'
echo "1..$n"
((failed == 0)) || { echo "# $failed of $n failed"; exit 1; }
