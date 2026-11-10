#!/usr/bin/env bash
# T21 (§9 ACL): a read-only LuCI principal, through uhttpd's JSON-RPC /ubus
# exactly as the browser calls it.
#
# Principal: the harness's monitor-readonly rpcd login, read-only on
# luci-base (what every LuCI user needs: ubus uci.get, menus) and
# luci-app-adblock-fast-monitor, no write grants (scripts/guest/lib.sh).
# The daemon object (WU1) and the rpcd plugin (WU2) must exist.
set -u
. test/lib/sh/testlib.sh
user="$GUEST_READONLY_USER" pass="$GUEST_READONLY_PASSWORD"

# rpc SID OBJECT METHOD [ARGS_JSON] -> one line: "allowed <ubus status> <ok>",
# "denied", "missing" or "error <json>"
rpc() {
	local args="${4:-}"
	[[ -n "$args" ]] || args="{}"
	curl --silent --max-time 30 "$GUEST_HTTP_URL/ubus" -H 'Content-Type: application/json' \
		--data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"call\",\"params\":[\"$1\",\"$2\",\"$3\",$args]}" |
		python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    r = json.loads(raw)
except ValueError:
    print("error", raw[:200]); sys.exit()
e = r.get("error")
if e:
    print({-32002: "denied", -32000: "missing"}.get(e.get("code"), "error " + json.dumps(e)))
else:
    res = r.get("result") or []
    ok = res[1].get("ok") if len(res) > 1 and isinstance(res[1], dict) else None
    print("allowed", res[0] if res else "?", "true" if ok is True else ("false" if ok is False else "-"))
'
}

t_match 'the principal reads luci-base and luci-app-adblock-fast-monitor' \
	'luci-base.*luci-app-adblock-fast-monitor|luci-app-adblock-fast-monitor.*luci-base' \
	"$(guest_exec 'uci -q get rpcd.monitor_readonly.read' || true)"
t_eq 'the principal has no write grants' '' "$(guest_exec 'uci -q get rpcd.monitor_readonly.write' || true)"

sid="$(curl --silent --max-time 30 "$GUEST_HTTP_URL/ubus" -H 'Content-Type: application/json' --data \
	"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"call\",\"params\":[\"00000000000000000000000000000000\",\"session\",\"login\",{\"username\":\"$user\",\"password\":\"$pass\"}]}" |
	python3 -c 'import json,sys; print(json.load(sys.stdin)["result"][1]["ubus_rpc_session"])' 2>/dev/null)"
t_match 'read-only principal logs in through /ubus' '^[0-9a-f]{32}$' "$sid"

t_eq 'uci get adblock-fast-monitor is allowed' 'allowed 0 -' "$(rpc "$sid" uci get '{"config":"adblock-fast-monitor"}')"
t_eq 'uci get adblock-fast is allowed' 'allowed 0 -' "$(rpc "$sid" uci get '{"config":"adblock-fast"}')"
# rpcd's own uci read check (UBUS_STATUS_PERMISSION_DENIED = 6) for a config outside the grant
t_eq 'uci get dhcp (not granted) is refused by rpcd' 'allowed 6 -' "$(rpc "$sid" uci get '{"config":"dhcp"}')"
before="$(guest_exec 'uci -q show adblock-fast-monitor; uci -q show adblock-fast' | sha256sum)"
t_eq 'uci set adblock-fast-monitor is denied' denied \
	"$(rpc "$sid" uci set '{"config":"adblock-fast-monitor","section":"config","values":{"enabled":"1"}}')"
t_eq 'uci set adblock-fast is denied' denied \
	"$(rpc "$sid" uci set '{"config":"adblock-fast","section":"config","values":{"enabled":"0"}}')"
t_eq 'uci delete adblock-fast-monitor is denied' denied \
	"$(rpc "$sid" uci delete '{"config":"adblock-fast-monitor","section":"config"}')"
t_eq 'no configuration changed' "$before" "$(guest_exec 'uci -q show adblock-fast-monitor; uci -q show adblock-fast' | sha256sum)"
t_eq 'an unknown object gives -32000 before the ACL check' missing "$(rpc "$sid" adblock-fast-monitor-nonexistent status)"

# rpcd plugin (WU2)
t_ok 'luci.adblock-fast-monitor is registered' guest_exec 'ubus list luci.adblock-fast-monitor'
t_eq 'luci.adblock-fast-monitor info is allowed' 'allowed 0 true' "$(rpc "$sid" luci.adblock-fast-monitor info)"
t_eq 'luci.adblock-fast-monitor rules is allowed' 'allowed 0 true' \
	"$(rpc "$sid" luci.adblock-fast-monitor rules '{"domains":["example.com"]}')"
t_match 'luci.adblock-fast-monitor job is allowed' '^allowed 0 ' "$(rpc "$sid" luci.adblock-fast-monitor job)"
t_eq 'luci.adblock-fast-monitor apply is denied' denied \
	"$(rpc "$sid" luci.adblock-fast-monitor apply '{"ops":[{"op":"block","domain":"example.com"}],"dry_run":true}')"

# Daemon object (WU1): absent while disabled, then present once enabled.
was="$(guest_exec 'uci -q get adblock-fast-monitor.config.enabled' || echo 0)"
setmon() { guest_exec "uci set adblock-fast-monitor.config.enabled=$1; uci commit adblock-fast-monitor; /etc/init.d/adblock-fast-monitor restart" >/dev/null 2>&1; }
setmon 0
t_eq 'status while monitoring is disabled gives -32000 (object absent)' missing "$(rpc "$sid" adblock-fast-monitor status)"
setmon 1
t_ok 'the daemon object appears after enabling' guest_exec '. /tmp/abfm-test/lib/sh/testlib.sh; abfm_wait_until 20 ubus list adblock-fast-monitor'
t_eq 'adblock-fast-monitor status is allowed' 'allowed 0 true' "$(rpc "$sid" adblock-fast-monitor status)"
t_eq 'adblock-fast-monitor domains is allowed' 'allowed 0 true' "$(rpc "$sid" adblock-fast-monitor domains '{"view":"recent"}')"
t_eq 'adblock-fast-monitor purge is denied' denied "$(rpc "$sid" adblock-fast-monitor purge)"
setmon "$was"
t_done
