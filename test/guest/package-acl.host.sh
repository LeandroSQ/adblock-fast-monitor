#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# T21 (docs/CONTRACT.md §9 ACL) through uhttpd's JSON-RPC /ubus and its SSE
# endpoint /ubus/subscribe/<object>, exactly as a browser would call them.
#
# Principals:
#   root              LuCI's admin (rpcd grants it every ACL group, "*"); for
#                     the SSE positive control this test adds a throwaway
#                     group granting `log` `:subscribe`, which only root gets
#   monitor-admin     created here: luci-base + this app's read AND write grant
#   monitor-readonly  the harness login (scripts/guest/lib.sh): luci-base +
#                     this app's read grant only
#   monitor-none      created here: luci-base only, no grant of this app
#                     (the negative that matters: the read grant is the
#                     whole system log)
# The app's read grant includes core `log read` (the whole system log, which
# is why the app is for admins only); never `log write` or `:subscribe`.
set -u
. test/lib/sh/testlib.sh
app=luci-app-adblock-fast-monitor
admin_user=monitor-admin
admin_pass="$(openssl rand -hex 16)"
none_user=monitor-none
none_pass="$(openssl rand -hex 16)"

# rpc SID OBJECT METHOD [ARGS_JSON] -> "allowed <ubus status> <ok>", "denied",
# "missing" or "error <json>"
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
raw() { # SID OBJECT METHOD ARGS_JSON -> raw JSON-RPC reply
	curl --silent --max-time 30 "$GUEST_HTTP_URL/ubus" -H 'Content-Type: application/json' \
		--data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"call\",\"params\":[\"$1\",\"$2\",\"$3\",$4]}"
}
login() {
	raw 00000000000000000000000000000000 session login "{\"username\":\"$1\",\"password\":\"$2\"}" |
		python3 -c 'import json,sys; print(json.load(sys.stdin)["result"][1]["ubus_rpc_session"])' 2>/dev/null
}
# sse SID -> "<HTTP status> <content type>" of GET /ubus/subscribe/log. uhttpd
# answers 200 either way: text/event-stream when the session may
# `:subscribe` (streams until --max-time), application/json with a
# permission error otherwise (uhttpd ubus.c L436-439).
sse() {
	curl --silent --output "$GUEST_RUN_DIR/acl-sse.out" --write-out '%{http_code} %{content_type}' --max-time 3 \
		-H "Authorization: Bearer $1" "$GUEST_HTTP_URL/ubus/subscribe/log" || true
}
log_count() { guest_exec "logread | grep -c '$1'" || true; }

# --- the ACL file as installed -------------------------------------------------
t_eq 'the installed ACL grants exactly the §9 sets' \
	'{"read": {"ubus": {"log": ["read"], "luci.adblock-fast-monitor": ["info", "job"]}, "uci": ["adblock-fast-monitor"]}, "write": {"ubus": {"luci.adblock-fast-monitor": ["apply"]}, "uci": ["adblock-fast-monitor"]}}' \
	"$(guest_exec "cat /usr/share/rpcd/acl.d/$app.json" | python3 -c 'import json,sys; d=json.load(sys.stdin)["'$app'"]; d.pop("description"); print(json.dumps(d))')"

# --- principals ---------------------------------------------------------------
hash="$(openssl passwd -6 "$admin_pass")"
none_hash="$(openssl passwd -6 "$none_pass")"
guest_exec 'cat >/usr/share/rpcd/acl.d/abfm-test-sse.json' <<'JSON'
{ "abfm-test-sse": { "description": "test only", "read": { "ubus": { "log": [ ":subscribe" ] } } } }
JSON
guest_exec "set -e
	grep -q '^$admin_user:' /etc/passwd || { echo '$admin_user:x:1002:65534:monitor admin:/var:/bin/false' >>/etc/passwd; echo '$admin_user:x:0:0:99999:7:::' >>/etc/shadow; }
	sed -i 's|^$admin_user:[^:]*:|$admin_user:$hash:|' /etc/shadow
	uci -q delete rpcd.monitor_admin || :
	uci set rpcd.monitor_admin=login
	uci set rpcd.monitor_admin.username='$admin_user'
	uci set rpcd.monitor_admin.password='\$p\$$admin_user'
	for g in luci-base unauthenticated $app; do uci add_list rpcd.monitor_admin.read=\$g; done
	for g in luci-base $app; do uci add_list rpcd.monitor_admin.write=\$g; done
	grep -q '^$none_user:' /etc/passwd || { echo '$none_user:x:1003:65534:monitor none:/var:/bin/false' >>/etc/passwd; echo '$none_user:x:0:0:99999:7:::' >>/etc/shadow; }
	sed -i 's|^$none_user:[^:]*:|$none_user:$none_hash:|' /etc/shadow
	uci -q delete rpcd.monitor_none || :
	uci set rpcd.monitor_none=login
	uci set rpcd.monitor_none.username='$none_user'
	uci set rpcd.monitor_none.password='\$p\$$none_user'
	for g in luci-base unauthenticated; do uci add_list rpcd.monitor_none.read=\$g; done
	uci add_list rpcd.monitor_none.write=luci-base
	uci commit rpcd
	/etc/init.d/rpcd reload
	ubus -t 15 wait_for session luci.adblock-fast-monitor" >/dev/null
cleanup() {
	guest_exec "rm -f /usr/share/rpcd/acl.d/abfm-test-sse.json; uci -q delete rpcd.monitor_admin; uci -q delete rpcd.monitor_none; uci commit rpcd; sed -i '/^$admin_user:/d; /^$none_user:/d' /etc/passwd /etc/shadow; /etc/init.d/rpcd reload; ubus -t 15 wait_for session luci.adblock-fast-monitor" >/dev/null 2>&1
}
trap cleanup EXIT
t_match 'the read-only principal reads luci-base and the app, writes nothing' \
	'luci-app-adblock-fast-monitor' "$(guest_exec 'uci -q get rpcd.monitor_readonly.read' || true)"
t_eq 'the read-only principal has no write grants' '' "$(guest_exec 'uci -q get rpcd.monitor_readonly.write' || true)"

root_sid="$(login root "$GUEST_ROOT_PASSWORD")"
admin_sid=''
for _ in 1 2 3 4 5; do admin_sid="$(login "$admin_user" "$admin_pass")"; [[ -n "$admin_sid" ]] && break; sleep 1; done
ro_sid="$(login "$GUEST_READONLY_USER" "$GUEST_READONLY_PASSWORD")"
t_match 'root logs in through /ubus' '^[0-9a-f]{32}$' "$root_sid"
t_match 'monitor-admin logs in through /ubus' '^[0-9a-f]{32}$' "$admin_sid"
t_match 'monitor-readonly logs in through /ubus' '^[0-9a-f]{32}$' "$ro_sid"

# --- SSE endpoint works at all (positive control: root + the throwaway group) -
t_eq 'root with a :subscribe grant: /ubus/subscribe/log streams (the endpoint exists)' '200 text/event-stream' "$(sse "$root_sid")"

dry='{"ops":[{"op":"block","domain":"acl.example.com"}],"confirm_rebuild":true,"dry_run":true}'
for who in admin ro; do
	case $who in admin) sid=$admin_sid name=monitor-admin ;; ro) sid=$ro_sid name=monitor-readonly ;; esac
	t_eq "$name: log read is allowed" 'allowed 0 -' "$(rpc "$sid" log read '{"lines":16,"stream":false,"oneshot":true}')"
	mark="abfm-acl-$who-$RANDOM$RANDOM"
	t_eq "$name: log write is denied" denied "$(rpc "$sid" log write "{\"event\":\"$mark\"}")"
	t_eq "$name: ... and nothing was written" 0 "$(log_count "$mark")"
	t_eq "$name: /ubus/subscribe/log is refused (no event stream)" '200 application/json' "$(sse "$sid")"
	t_match "$name: ... with a permission error" 'denied|ermission' "$(cat "$GUEST_RUN_DIR/acl-sse.out")"
	t_eq "$name: info is allowed (api 2)" 'allowed 0 true' "$(rpc "$sid" luci.adblock-fast-monitor info)"
	t_match "$name: job is allowed" '^allowed 0 ' "$(rpc "$sid" luci.adblock-fast-monitor job)"
	t_eq "$name: uci get adblock-fast-monitor is allowed" 'allowed 0 -' "$(rpc "$sid" uci get '{"config":"adblock-fast-monitor"}')"
	t_eq "$name: uci get adblock-fast (not granted; info reports its state) is refused by rpcd" 'allowed 6 -' "$(rpc "$sid" uci get '{"config":"adblock-fast"}')"
	t_eq "$name: uci get dhcp (not granted) is refused by rpcd" 'allowed 6 -' "$(rpc "$sid" uci get '{"config":"dhcp"}')"
done

# --- a login without this app's ACL (luci-base only) ---------------------------
none_sid="$(login "$none_user" "$none_pass")"
t_match 'monitor-none logs in through /ubus' '^[0-9a-f]{32}$' "$none_sid"
t_eq 'monitor-none: log read is denied' denied "$(rpc "$none_sid" log read '{"lines":16,"stream":false,"oneshot":true}')"
t_eq 'monitor-none: info is denied' denied "$(rpc "$none_sid" luci.adblock-fast-monitor info)"
t_eq 'monitor-none: job is denied' denied "$(rpc "$none_sid" luci.adblock-fast-monitor job)"
t_eq 'monitor-none: apply is denied' denied "$(rpc "$none_sid" luci.adblock-fast-monitor apply "$dry")"
t_eq 'monitor-none: uci get adblock-fast-monitor is refused by rpcd' 'allowed 6 -' "$(rpc "$none_sid" uci get '{"config":"adblock-fast-monitor"}')"
# LuCI's menu for a session, as the browser loads it (the dispatcher filters
# entries by their `depends.acl`).
menu() { # USER PASSWORD -> the menu JSON LuCI serves to that login
	local cookie
	cookie="$(curl --silent --max-time 30 -o /dev/null -D - --data-urlencode "luci_username=$1" --data-urlencode "luci_password=$2" \
		"$GUEST_HTTP_URL/cgi-bin/luci/" | tr -d '\r' | sed -n 's/^[Ss]et-[Cc]ookie: \(sysauth[_a-z]*=[0-9a-f]\{32\}\).*/\1/p' | head -n1)"
	[[ -n "$cookie" ]] || { echo "no session for $1"; return; }
	curl --silent --max-time 30 -H "Cookie: $cookie" "$GUEST_HTTP_URL/cgi-bin/luci/admin/menu"
}
# app_node MENU_JSON -> "satisfied=<bool>" of admin/services/adblock-fast-monitor,
# or "absent". LuCI's menu JSON carries every node; the dispatcher marks those
# whose depends (here the app's ACL) the session lacks as not satisfied, and
# luci.js renders only satisfied ones.
app_node() { python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    print("no-json"); sys.exit()
n = d
for k in ("admin", "services", "adblock-fast-monitor"):
    n = (n.get("children") or {}).get(k)
    if n is None:
        print("absent"); sys.exit()
print("satisfied=%s" % str(bool(n.get("satisfied"))).lower())'; }
route() { # USER PASSWORD -> HTTP status of the app's overview page for that login
	local cookie
	cookie="$(curl --silent --max-time 30 -o /dev/null -D - --data-urlencode "luci_username=$1" --data-urlencode "luci_password=$2" \
		"$GUEST_HTTP_URL/cgi-bin/luci/" | tr -d '\r' | sed -n 's/^[Ss]et-[Cc]ookie: \(sysauth[_a-z]*=[0-9a-f]\{32\}\).*/\1/p' | head -n1)"
	curl --silent --max-time 30 -o /dev/null -w '%{http_code}' -H "Cookie: $cookie" "$GUEST_HTTP_URL/cgi-bin/luci/admin/services/adblock-fast-monitor/overview"
}
ro_menu="$(menu "$GUEST_READONLY_USER" "$GUEST_READONLY_PASSWORD")"
t_eq 'monitor-readonly: the app is a satisfied menu entry (control)' 'satisfied=true' "$(app_node <<<"$ro_menu")"
none_menu="$(menu "$none_user" "$none_pass")"
t_match 'monitor-none: LuCI serves a menu' '"children"' "$none_menu"
t_match 'monitor-none: the app is not a satisfied menu entry (luci.js shows none)' '^(absent|satisfied=false)$' "$(app_node <<<"$none_menu")"
t_eq "the app's page: served to monitor-readonly, refused (403) to monitor-none" '200 403' \
	"$(route "$GUEST_READONLY_USER" "$GUEST_READONLY_PASSWORD") $(route "$none_user" "$none_pass")"

t_eq 'monitor-admin: apply is allowed' 'allowed 0 true' "$(rpc "$admin_sid" luci.adblock-fast-monitor apply "$dry")"
t_eq 'root: apply is allowed' 'allowed 0 true' "$(rpc "$root_sid" luci.adblock-fast-monitor apply "$dry")"
t_eq 'root: log read is allowed' 'allowed 0 -' "$(rpc "$root_sid" log read '{"lines":16,"stream":false,"oneshot":true}')"
t_eq 'monitor-readonly: apply is denied' denied "$(rpc "$ro_sid" luci.adblock-fast-monitor apply "$dry")"

before="$(guest_exec 'uci -q show adblock-fast-monitor; uci -q show adblock-fast' | sha256sum)"
t_eq 'monitor-readonly: uci set adblock-fast-monitor is denied' denied \
	"$(rpc "$ro_sid" uci set '{"config":"adblock-fast-monitor","section":"config","values":{"query_logging":"1"}}')"
t_eq 'monitor-readonly: uci delete adblock-fast-monitor is denied' denied \
	"$(rpc "$ro_sid" uci delete '{"config":"adblock-fast-monitor","section":"config"}')"
t_eq 'monitor-readonly: uci set adblock-fast is denied by uhttpd' denied \
	"$(rpc "$ro_sid" uci set '{"config":"adblock-fast","section":"config","values":{"enabled":"0"}}')"
# luci-base's write grant lets the call through uhttpd; rpcd's uci write check
# refuses the config (UBUS_STATUS_PERMISSION_DENIED = 6).
t_eq 'monitor-admin: uci set adblock-fast is refused by rpcd (rules change only through apply)' 'allowed 6 -' \
	"$(rpc "$admin_sid" uci set '{"config":"adblock-fast","section":"config","values":{"enabled":"0"}}')"
rm -f "$GUEST_RUN_DIR/acl-sse.out"
t_eq 'no configuration changed' "$before" "$(guest_exec 'uci -q show adblock-fast-monitor; uci -q show adblock-fast' | sha256sum)"
t_done
