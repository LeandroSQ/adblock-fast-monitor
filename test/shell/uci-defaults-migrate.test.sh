#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# docs/CONTRACT.md §3 migration: root/etc/uci-defaults/80_adblock-fast-monitor
# run with OpenWrt's BusyBox ash and uci against /etc/config of the userland
# container (the file is put back afterwards). The guest upgrade test
# (test/guest/package-upgrade.host.sh) covers the same script through apk.
. "$ABFM_TESTLIB/sh/testlib.sh"

script=${ABFM_SRC:-/src}/root/etc/uci-defaults/80_adblock-fast-monitor
conf=/etc/config/adblock-fast-monitor
mkdir -p /etc/config
bak=$(abfm_tmpdir)/config.bak
had=0
[ -e "$conf" ] && { cp "$conf" "$bak"; had=1; }
restore() { if [ $had = 1 ]; then cp "$bak" "$conf"; else rm -f "$conf"; fi; }
trap restore EXIT

# run CONFIG_TEXT -> `uci show` after running the script as default_postinst does
run() {
	printf '%s' "$1" >"$conf"
	( . "$script" ) || return 1
	uci -q show adblock-fast-monitor
}

V1="config monitor 'config'
	option enabled '1'
	option manage_logging '1'
	list dnsmasq_instance 'lan'
	option recent_size '777'
	option top_size '256'
	option pending_size '512'
	option pending_ttl '10'
	option record_clients '1'
	option exclude_router '0'
	option poll_interval '5'
"
t_eq 'v1 enabled=1: query_logging=1, daemon options removed, UI options kept' \
"adblock-fast-monitor.config=monitor
adblock-fast-monitor.config.dnsmasq_instance='lan'
adblock-fast-monitor.config.exclude_router='0'
adblock-fast-monitor.config.poll_interval='5'
adblock-fast-monitor.config.query_logging='1'" "$(run "$V1")"

t_eq 'running it again changes nothing' "$(uci -q show adblock-fast-monitor)" "$( ( . "$script" ) && uci -q show adblock-fast-monitor)"

t_eq 'v1 enabled=1 with manage_logging=0 (no drop-ins in v1): query_logging=0' "0" \
	"$(run "config monitor 'config'
	option enabled 'yes'
	option manage_logging 'off'
" >/dev/null; uci -q get adblock-fast-monitor.config.query_logging)"

t_eq 'v1 enabled=0: query_logging=0' "adblock-fast-monitor.config=monitor
adblock-fast-monitor.config.query_logging='0'" "$(run "config monitor 'config'
	option enabled '0'
")"

V2="config monitor 'config'
	option query_logging '1'
	list dnsmasq_instance '*'
	option exclude_router '1'
	option poll_interval '2'
"
printf '%s' "$V2" >"$conf"
( . "$script" )
t_eq 'a v2 file is left byte-identical (no commit)' "$(printf '%s' "$V2" | md5sum)" "$(md5sum <"$conf")"

t_eq 'an existing query_logging wins over a stale enabled' 1 \
	"$(run "config monitor 'config'
	option query_logging '1'
	option enabled '0'
" >/dev/null; uci -q get adblock-fast-monitor.config.query_logging)"

rm -f "$conf"
t_ok 'no config file: exits 0 and creates nothing' sh -c "( . '$script' ) && test ! -e '$conf'"

t_done
