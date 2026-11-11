#!/usr/bin/env bash
# Package upgrade, old -> new, from a signed feed (no --allow-untrusted). Run
# it with
#
#   scripts/release/verify-upgrade.sh NEW.apk
#
# which builds the old package (by default the last api-1 source, with its
# resident daemon; PKG_VERSION 0.0.9), signs a throwaway-key feed in two
# releases (ABFM_FEED_DIR/v1: old only, ABFM_FEED_DIR/v2: new + old, key under
# keys/*.pem) and boots a --no-install guest with ABFM_UPGRADE_TEST=1,
# ABFM_OLD_VERSION=0.0.9-r1 and ABFM_OLD_API (1 or 2). In ordinary guest runs
# it is skipped.
#
# Flow: trust the key, add the feed (serving v1), install the package (old),
# turn query logging on (v1: enabled=1 with the daemon running) and change
# conffile options, apply one rule through LuCI's /ubus, publish v2 on the
# same URL, then `apk update && apk upgrade` (what LuCI's Update lists… and
# Updates → Upgrade… run through package-manager-call) and check the result:
# the v1 `enabled` is migrated to `query_logging` (docs/CONTRACT.md §3), the
# daemon is gone, the drop-in stays, dnsmasq restarts at most once.
set -u
. test/lib/sh/testlib.sh
pkg=luci-app-adblock-fast-monitor
rule=upgrade-probe.example.com

if [[ "${ABFM_UPGRADE_TEST:-0}" != 1 ]]; then
	t_skip 'package upgrade from a signed feed' 'run scripts/release/verify-upgrade.sh NEW.apk'
	t_done
fi
if guest_exec "apk info -e $pkg" >/dev/null 2>&1; then
	t__result 1 'the guest does not have the package yet' 'run scripts/release/verify-upgrade.sh NEW.apk'
	t_done
fi
old_version="${ABFM_OLD_VERSION:?}"
old_api="${ABFM_OLD_API:-1}"
site="$(cd "${ABFM_FEED_DIR:?}" && pwd)"
key="$(find "$site/v1/keys" -name '*.pem' | head -n 1)"
work="$GUEST_RUN_DIR/upgrade"
mkdir -p "$work/serve"
ln -sfn "$site/v1/apk" "$work/serve/apk"
server=''
trap '[[ -z "$server" ]] || kill "$server" 2>/dev/null' EXIT
python3 scripts/release/serve-site.py --dir "$work/serve" --ready-file "$work/port" 2>"$work/serve-site.log" &
server=$!
for _ in $(seq 50); do [[ -s "$work/port" ]] && break; sleep 0.1; done
port="$(cat "$work/port")"
feed="${GUEST_HOST_URL%:*}:$port/apk/packages.adb"
new_version="$(sed -n 's/^luci-app-adblock-fast-monitor-\(.*\)\.apk$/\1/p' <(ls "$site/v2/apk") | grep -vx "$old_version" | head -n 1)"
t_ok "v1 has only $old_version; v2 has $old_version and $new_version" test -n "$new_version" \
	-a "$(ls "$site/v1/apk" | grep -c '\.apk$')" = 1 -a -s "$site/v1/apk/$pkg-$old_version.apk" -a -s "$site/v2/apk/$pkg-$old_version.apk"
installed() { guest_exec "apk list -I $pkg" | sed -n "s/^$pkg-\([^ ]*\) .*/\1/p"; }

# root session through uhttpd, exactly like LuCI
rpc() { # SID OBJECT METHOD [ARGS] -> raw JSON
	local args="${4:-}"; [[ -n "$args" ]] || args='{}'
	curl --silent --max-time 30 "$GUEST_HTTP_URL/ubus" -H 'Content-Type: application/json' \
		--data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"call\",\"params\":[\"$1\",\"$2\",\"$3\",$args]}"
}
js() { python3 -c 'import json,sys; d=json.load(sys.stdin); exec("try:\n r=" + sys.argv[1] + "\nexcept Exception: r=None"); print("" if r is None else (json.dumps(r) if isinstance(r,(dict,list,bool)) else r))' "$1"; }
login() {
	rpc 00000000000000000000000000000000 session login "{\"username\":\"$1\",\"password\":\"$2\"}" | js 'd["result"][1]["ubus_rpc_session"]'
}
wait_guest() { guest_exec ". /tmp/abfm-test/lib/sh/testlib.sh; abfm_wait_until $1 $2"; }

# --- old version from the feed, key trusted -------------------------------
guest_exec "cat >/etc/apk/keys/adblock-fast-monitor.pem" <"$key"
guest_exec "echo '$feed' >>/etc/apk/repositories.d/customfeeds.list"
t_ok 'apk update trusts the feed' guest_exec 'out=$(apk update 2>&1); rc=$?; echo "$out"; [ $rc = 0 ] && ! echo "$out" | grep -q UNTRUSTED'
t_ok "install $pkg from the feed (no --allow-untrusted)" guest_exec "apk add $pkg"
t_eq 'old version installed' "$old_version" "$(installed)"

# adblock-fast on the deterministic local fixture list (as the browser suite does)
guest_exec "set -e
while uci -q delete adblock-fast.@file_url[0]; do :; done
s=\$(uci add adblock-fast file_url)
uci set adblock-fast.\$s.url='$GUEST_FIXTURE_URL/lists/primary.txt'
uci set adblock-fast.\$s.action=block
uci set adblock-fast.\$s.enabled=1
uci set adblock-fast.config.enabled=1
uci set adblock-fast.config.dns=dnsmasq.servers
uci set adblock-fast.config.heartbeat_domain='-'
uci set adblock-fast.config.config_update_enabled=0
uci commit adblock-fast
/etc/init.d/adblock-fast enable
/etc/init.d/adblock-fast restart >/dev/null 2>&1 || :" >/dev/null

if [[ "$old_api" == 1 ]]; then
	guest_exec 'uci set adblock-fast-monitor.config.enabled=1 && uci set adblock-fast-monitor.config.recent_size=777 &&
		uci set adblock-fast-monitor.config.poll_interval=7 &&
		uci commit adblock-fast-monitor && /etc/init.d/adblock-fast-monitor restart' >/dev/null 2>&1
	t_ok 'old daemon object is up' wait_guest 30 'ubus list adblock-fast-monitor'
else
	guest_exec 'uci set adblock-fast-monitor.config.query_logging=1 && uci set adblock-fast-monitor.config.poll_interval=7 &&
		uci commit adblock-fast-monitor && /etc/init.d/adblock-fast-monitor restart' >/dev/null 2>&1
fi
sid="$(login root "$GUEST_ROOT_PASSWORD")"
t_match 'root logs in through /ubus' '^[0-9a-f]{32}$' "$sid"
r="$(rpc "$sid" luci.adblock-fast-monitor apply "{\"ops\":[{\"op\":\"block\",\"domain\":\"$rule\"}],\"confirm_rebuild\":true}")"
t_eq 'apply of one block rule is accepted' 'true' "$(js 'd["result"][1]["ok"]' <<<"$r")"
for _ in $(seq 120); do
	state="$(rpc "$sid" luci.adblock-fast-monitor job | js 'd["result"][1]["job"]["state"]')"
	[[ "$state" =~ ^(applied|partial|failed)$ ]] && break
	sleep 2
done
t_eq 'the rule job finished before the upgrade' applied "$state"
t_match 'adblock-fast UCI has the rule' "(^| )$rule( |$)" "$(guest_exec 'uci -q get adblock-fast.config.blocked_domain')"

# --- state before the upgrade ---------------------------------------------
dropins_before="$(guest_exec 'ls /tmp/dnsmasq*.d/adblock-fast-monitor.conf 2>/dev/null')"
t_match 'drop-in present before the upgrade' 'adblock-fast-monitor\.conf' "$dropins_before"
blocked_before="$(guest_exec 'uci -q get adblock-fast.config.blocked_domain; uci -q get adblock-fast.config.allowed_domain')"
rpcd_before="$(guest_exec 'ubus -v list session' | sed -n 's/.*@\([0-9a-f]*\).*/\1/p')"
guest_exec 'touch /tmp/luci-indexcache.abfm-probe; mkdir -p /tmp/luci-modulecache && touch /tmp/luci-modulecache/abfm-probe'
mark="abfm-upgrade-mark-$RANDOM$RANDOM"
guest_exec "logger -t abfm-test $mark"
t_upgrade="$(guest_exec 'date +%s')"

# --- upgrade --------------------------------------------------------------
ln -sfn "$site/v2/apk" "$work/serve/apk"
t_ok 'apk update sees the next release' guest_exec "apk update >/dev/null && apk list -u $pkg | grep -q '^$pkg-$new_version '"
t_ok "apk upgrade $pkg to $new_version" guest_exec "apk upgrade $pkg"
t_eq 'new version installed' "$new_version" "$(installed)"

# --- after ------------------------------------------------------------------
t_eq 'conffile migrated: query_logging=1, v1 options gone, poll_interval kept' 'query_logging=<1> poll_interval=<7> enabled=<> recent_size=<>' \
	"$(guest_exec 'for o in query_logging poll_interval enabled recent_size; do printf "%s=<%s> " $o "$(uci -q get adblock-fast-monitor.config.$o)"; done' | sed 's/ $//')"
t_ok 'the uci-defaults script ran and was removed' guest_exec 'test ! -e /etc/uci-defaults/80_adblock-fast-monitor'
# apk keeps a modified conffile and drops the packaged default next to it as
# .apk-new (like opkg's -opkg); that copy must be the shipped default.
apknew="$(guest_exec 'cat /etc/config/adblock-fast-monitor.apk-new 2>/dev/null' || true)"
[[ -z "$apknew" ]] || t_match '.apk-new (if any) is the shipped default, not the user file' "option query_logging '0'" "$apknew"
t_ok 'LuCI index cache cleared' guest_exec '! ls /tmp/luci-indexcache.abfm-probe 2>/dev/null'
t_ok 'LuCI module cache cleared' guest_exec '! ls /tmp/luci-modulecache/abfm-probe 2>/dev/null'
t_ok 'rpcd reloaded by the package scripts' test "$rpcd_before" != "$(guest_exec 'ubus -v list session' | sed -n 's/.*@\([0-9a-f]*\).*/\1/p')"

sid="$(login root "$GUEST_ROOT_PASSWORD")"
info="$(rpc "$sid" luci.adblock-fast-monitor info)"
t_eq 'info via /ubus without an rpcd restart: api 2, query_logging on, local_domains' '2 true true list' \
	"$(js 'd["result"][1]["api"]' <<<"$info") $(js 'd["result"][1]["ok"]' <<<"$info") $(js 'd["result"][1]["monitor"]["query_logging"]' <<<"$info") $(js 'type(d["result"][1]["local_domains"]).__name__' <<<"$info")"
t_eq 'luci.adblock-fast-monitor job still reports the pre-upgrade job' applied \
	"$(rpc "$sid" luci.adblock-fast-monitor job | js 'd["result"][1]["job"]["state"]')"
t_eq 'log read via /ubus' 'list' "$(rpc "$sid" log read '{"lines":16,"stream":false,"oneshot":true}' | js 'type(d["result"][1]["log"]).__name__')"
ro="$(login "$GUEST_READONLY_USER" "$GUEST_READONLY_PASSWORD")"
t_eq 'read-only principal: info allowed after the upgrade' 'true' "$(rpc "$ro" luci.adblock-fast-monitor info | js 'd["result"][1]["ok"]')"
t_eq 'read-only principal: log read allowed after the upgrade (new ACL loaded)' 'list' \
	"$(rpc "$ro" log read '{"lines":16,"stream":false,"oneshot":true}' | js 'type(d["result"][1]["log"]).__name__')"

t_eq 'the v1 daemon object is gone' 1 "$(guest_exec 'ubus list adblock-fast-monitor >/dev/null 2>&1; echo $?')"
t_eq 'procd has no instance for the package' '' \
	"$(guest_exec "ubus call service list '{\"name\":\"adblock-fast-monitor\"}'" | js 'd["adblock-fast-monitor"].get("instances")')"
# patterns are split so this shell's own command line never matches
procs="$(guest_exec 'a=monitord; b=.uc; l=logread; f=" -f"; for p in /proc/[0-9]*; do c=$(tr "\0" " " <$p/cmdline 2>/dev/null); [ -n "$c" ] || continue;
	case "$c" in *"$a$b"*|*"$l$f"*) echo "${p#/proc/} $(cut -d" " -f4 $p/stat) $c";; esac; done')"
t_eq 'no monitord.uc and no logread -f process remain' '' "$procs"

t_eq 'drop-in still present' "$dropins_before" "$(guest_exec 'ls /tmp/dnsmasq*.d/adblock-fast-monitor.conf 2>/dev/null')"
restarts="$(guest_exec "logread | sed -n '/$mark/,\$p' | grep -c 'dnsmasq\\[[0-9]*\\]: started, version'" || true)"
t_ok "dnsmasq restarted at most once during the upgrade ($restarts)" test "${restarts:-99}" -le 1
t_eq 'adblock-fast rule lists unchanged' "$blocked_before" \
	"$(guest_exec 'uci -q get adblock-fast.config.blocked_domain; uci -q get adblock-fast.config.allowed_domain')"
t_ok "$rule is still blocked by the running adblock-fast" guest_exec "grep -q '/$rule/' /var/run/adblock-fast/dnsmasq.servers"
t_done
