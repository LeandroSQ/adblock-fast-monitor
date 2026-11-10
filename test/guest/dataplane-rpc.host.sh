#!/usr/bin/env bash
# §4.6 through LuCI's transport: uhttpd's JSON-RPC /ubus adds
# ubus_rpc_session to every call, so the daemon's methods must accept it.
# Real rpcd sessions for the read-only principal and for root (admin).
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
n=0 failed=0
ok() { n=$((n + 1)); echo "ok $n - $1"; }
nok() { n=$((n + 1)); failed=$((failed + 1)); echo "not ok $n - $1"; [[ -z "${2:-}" ]] || sed 's/^/#   /' <<<"$2"; }
eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else nok "$1" "expected: <$2>"$'\n'"actual:   <$3>"; fi; }
# Leave the monitor config byte-identical for later tests (package §3 checks).
guest_exec 'cp /etc/config/adblock-fast-monitor /tmp/abfm-rpc-config.bak'
trap "guest_exec 'cp /tmp/abfm-rpc-config.bak /etc/config/adblock-fast-monitor; rm -f /tmp/abfm-rpc-config.bak'" EXIT

# post SID METHOD ARGS_JSON EXPR -> EXPR evaluated on (status, data, error)
post() {
	curl --silent --max-time 30 "$GUEST_HTTP_URL/ubus" -H 'Content-Type: application/json' \
		--data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"call\",\"params\":[\"$1\",\"adblock-fast-monitor\",\"$2\",$3]}" |
		python3 -c '
import json, sys
r = json.load(sys.stdin)
err = (r.get("error") or {}).get("code")
res = r.get("result") or [None, None]
status, d = res[0], (res[1] if len(res) > 1 else None)
print(eval(sys.argv[1]))' "$4"
}
login() {
	curl --silent --max-time 30 "$GUEST_HTTP_URL/ubus" -H 'Content-Type: application/json' --data \
		"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"call\",\"params\":[\"00000000000000000000000000000000\",\"session\",\"login\",{\"username\":\"$1\",\"password\":\"$2\"}]}" |
		python3 -c 'import json,sys; print(json.load(sys.stdin)["result"][1]["ubus_rpc_session"])' 2>/dev/null
}

guest_exec 'uci set adblock-fast-monitor.config.enabled=1; uci commit adblock-fast-monitor
	/etc/init.d/adblock-fast-monitor start; i=0; until ubus list adblock-fast-monitor >/dev/null 2>&1 && nslookup localhost 127.0.0.1 >/dev/null 2>&1; do i=$((i+1)); [ $i -lt 30 ] || exit 1; sleep 1; done' ||
	nok "monitor starts"
python3 "$here/dataplane-lib/dnsq.py" 127.0.0.1 "$GUEST_DNS_PORT" A localhost >/dev/null
sleep 2

admin=$(login root "$GUEST_ROOT_PASSWORD")
ro=$(login "$GUEST_READONLY_USER" "$GUEST_READONLY_PASSWORD")
[[ "$admin" =~ ^[0-9a-f]{32}$ ]] && ok "admin session" || nok "admin session" "$admin"
[[ "$ro" =~ ^[0-9a-f]{32}$ ]] && ok "read-only session" || nok "read-only session" "$ro"

for who in admin ro; do
	sid=${!who}
	eq "$who: status through /ubus" "[0, True, 'running']" "$(post "$sid" status '{}' '[status, d["ok"], d["state"]]')"
	eq "$who: domains through /ubus" "[0, True, 'recent', 'localhost']" \
		"$(post "$sid" domains '{"view":"recent","limit":10,"offset":0}' '[status, d["ok"], d["view"], d["items"][0]["domain"]]')"
	eq "$who: value errors keep the error shape" "[0, False, 'invalid-argument']" \
		"$(post "$sid" domains '{"view":"nope"}' '[status, d["ok"], d["error"]["code"]]')"
	eq "$who: an undeclared field is still refused (status 2)" "2" "$(post "$sid" status '{"bogus":1}' 'status')"
done
eq "admin: purge through /ubus" "[0, True]" "$(post "$admin" purge '{}' '[status, d["ok"]]')"
eq "admin: purge emptied the table" "0" "$(post "$admin" domains '{}' 'd["total"]')"
eq "read-only: purge is denied by the ACL" "-32002" "$(post "$ro" purge '{}' 'err')"

guest_exec 'uci set adblock-fast-monitor.config.enabled=0; uci commit adblock-fast-monitor; /etc/init.d/adblock-fast-monitor stop
	i=0; while ubus list adblock-fast-monitor >/dev/null 2>&1; do i=$((i+1)); [ $i -lt 20 ] || exit 1; sleep 1; done' ||
	nok "monitor stops"
eq "missing object maps to -32000" "-32000" "$(post "$ro" status '{}' 'err if err else r')"
echo "1..$n"
((failed == 0)) || { echo "# $failed of $n failed"; exit 1; }
