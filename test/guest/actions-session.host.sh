#!/usr/bin/env bash
# The rpcd ucode plugin through uhttpd's /ubus with real LuCI sessions
# (docs/CONTRACT.md §6, §9): uhttpd injects `ubus_rpc_session` into every
# call's arguments, and rpcd only accepts it because it is special-cased
# next to each method's declared signature. Admin and read-only logins go
# through LuCI's login form, exactly like the browser.
set -u
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

n=0 failed=0
result() {
	n=$((n + 1))
	if [[ "$1" == 0 ]]; then echo "ok $n - $2"; else echo "not ok $n - $2"; [[ -n "${3:-}" ]] && echo "#   $3"; failed=1; fi
}
check_eq() { [[ "$2" == "$3" ]] && result 0 "$1" || result 1 "$1" "expected <$2> actual <$3>"; }
jq_() { python3 -c 'import json,sys; d=json.load(sys.stdin); exec(sys.argv[1])' "$1"; }

# The read-only LuCI login needs luci-base (menu) and unauthenticated (login page).
guest_exec 'changed=0; for g in luci-base unauthenticated luci-app-adblock-fast-monitor; do
	uci -q get rpcd.monitor_readonly.read | tr " " "\n" | grep -qx "$g" || { uci add_list rpcd.monitor_readonly.read="$g"; changed=1; }; done
	[ $changed = 0 ] || { uci commit rpcd; /etc/init.d/rpcd reload; }; ubus -t 15 wait_for session luci.adblock-fast-monitor'

# luci_login USER PASSWORD -> the session id LuCI stores in the sysauth cookie
luci_login() {
	curl --silent --max-time 30 -o /dev/null -D - \
		--data-urlencode "luci_username=$1" --data-urlencode "luci_password=$2" \
		"$GUEST_HTTP_URL/cgi-bin/luci/" | tr -d '\r' | sed -n 's/^[Ss]et-[Cc]ookie: sysauth[_a-z]*=\([0-9a-f]\{32\}\).*/\1/p' | head -1
}

# ubus SID OBJECT METHOD ARGS_JSON -> raw JSON-RPC response
ubus() {
	curl --silent --max-time 60 -H 'Content-Type: application/json' \
		--data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"call\",\"params\":[\"$1\",\"$2\",\"$3\",$4]}" \
		"$GUEST_HTTP_URL/ubus"
}

# status RESPONSE -> "<ubus status> <ok>" or "error <code>"
status() {
	jq_ 'print("error %d" % d["error"]["code"] if "error" in d else "%d %s" % (d["result"][0], str(d["result"][1].get("ok")).lower() if len(d["result"]) > 1 else "-"))' <<<"$1"
}

admin=$(luci_login root "$GUEST_ROOT_PASSWORD")
[[ -n "$admin" ]] && result 0 "admin logs in through LuCI" || result 1 "admin logs in through LuCI"
ro=$(luci_login "$GUEST_READONLY_USER" "$GUEST_READONLY_PASSWORD")
[[ -n "$ro" ]] && result 0 "read-only user logs in through LuCI" || result 1 "read-only user logs in through LuCI"

for who in admin ro; do
	sid=${!who}
	check_eq "$who: info with the injected ubus_rpc_session" "0 true" "$(status "$(ubus "$sid" luci.adblock-fast-monitor info '{}')")"
	r=$(ubus "$sid" luci.adblock-fast-monitor rules '{"domains":["ads.example.com"]}')
	check_eq "$who: rules with the injected ubus_rpc_session" "0 true" "$(status "$r")"
	check_eq "$who: rules answers for the asked name" ads.example.com \
		"$(jq_ 'print(list(d["result"][1]["domains"].keys())[0])' <<<"$r")"
	check_eq "$who: job with the injected ubus_rpc_session" "0 true" "$(status "$(ubus "$sid" luci.adblock-fast-monitor job '{}')")"
	check_eq "$who: an undeclared field is still rejected (ubus INVALID_ARGUMENT)" "2 -" \
		"$(status "$(ubus "$sid" luci.adblock-fast-monitor job '{"bogus":1}')")"
done

r=$(ubus "$admin" luci.adblock-fast-monitor apply '{"ops":[{"op":"allow","domain":"co.uk"}]}')
check_eq "admin: apply reaches the plugin (public-suffix)" "0 false public-suffix" \
	"$(status "$r") $(jq_ 'print(d["result"][1]["error"]["code"])' <<<"$r")"
r=$(ubus "$admin" luci.adblock-fast-monitor apply '{"ops":[{"op":"block","domain":"session.example.com"}],"confirm_rebuild":true,"dry_run":true}')
check_eq "admin: apply dry run succeeds" "0 true" "$(status "$r")"
check_eq "read-only: apply is denied by the ACL" "error -32002" \
	"$(status "$(ubus "$ro" luci.adblock-fast-monitor apply '{"ops":[{"op":"allow","domain":"a.example.com"}],"dry_run":true}')")"
check_eq "no session: info is denied" "error -32002" \
	"$(status "$(ubus 00000000000000000000000000000000 luci.adblock-fast-monitor info '{}')")"

echo "1..$n"
exit "$failed"
