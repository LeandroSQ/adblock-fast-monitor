#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# T22's removal half through apk itself (LuCI's Software page runs the same
# `apk del` through package-manager-call; the LuCI flow is
# test/browser/install-luci.spec.mjs): with query logging on and a finished
# job, removal stops the init script (drop-ins gone, one dnsmasq restart),
# removes the rc.d link, every packaged file, the ubus object and the runtime
# state (docs/CONTRACT.md §2). The package is then installed again from the
# same APK, so the guest is left as the harness installed it.
set -u
. test/lib/sh/testlib.sh
pkg=luci-app-adblock-fast-monitor

g() { guest_exec ". /tmp/abfm-test/lib/sh/testlib.sh; $1"; }
dropins() { guest_exec 'ls /tmp/dnsmasq*.d/adblock-fast-monitor.conf 2>/dev/null' || true; }

t_ok "$pkg is installed" guest_exec "apk info -e $pkg"
files="$(guest_exec "apk info -qL $pkg" | grep -v ' contains:$' | sed '/^$/d')"

# State to clean up: query logging on (drop-in), a finished job (job.json,
# the private UCI savedir, both lock files).
g "cp /etc/config/adblock-fast-monitor /root/abfm-remove-config.bak
	uci set adblock-fast-monitor.config.query_logging=1; uci commit adblock-fast-monitor
	/etc/init.d/adblock-fast-monitor restart" >/dev/null
t_match 'query logging on: drop-in present' 'adblock-fast-monitor\.conf' "$(dropins)"
r="$(g "cp /etc/config/adblock-fast /root/abfm-remove-af.bak
	uci set adblock-fast.config.enabled=0; uci commit adblock-fast
	ubus call luci.adblock-fast-monitor apply '{\"ops\":[{\"op\":\"block\",\"domain\":\"remove.example.com\"}]}'")"
t_match 'a persist-only job was queued' '"state": "queued"' "$r"
t_ok 'the job finished' g "abfm_wait_until 30 sh -c \"ubus call luci.adblock-fast-monitor job | jsonfilter -e @.job.state | grep -qx applied\""
t_ok 'runtime state exists before removal' guest_exec \
	'test -f /var/run/adblock-fast-monitor/job.json -a -d /var/run/adblock-fast-monitor/uci -a -e /var/lock/adblock-fast-monitor.lock -a -e /var/lock/adblock-fast-monitor.logging.lock'

mark="abfm-remove-mark-$RANDOM$RANDOM"
guest_exec "logger -t abfm-test $mark"
t_ok "apk del $pkg" guest_exec "apk del $pkg"
g 'abfm_wait_until 30 nslookup localhost 127.0.0.1' >/dev/null
t_eq 'removal: the drop-ins are gone' '' "$(dropins)"
t_eq 'removal: dnsmasq restarted exactly once' 1 \
	"$(guest_exec "logread | sed -n '/$mark/,\$p' | grep -c 'dnsmasq\\[[0-9]*\\]: started, version'" || true)"
t_ok 'removal: the rc.d link is gone' guest_exec 'test ! -e /etc/rc.d/S18adblock-fast-monitor'
t_ok 'removal: procd no longer knows the service' guest_exec \
	"! ubus call service list '{\"name\":\"adblock-fast-monitor\"}' | grep -q adblock-fast-monitor"
left="$(while read -r f; do [[ "$f" == etc/config/adblock-fast-monitor ]] && continue; guest_exec "test -e /$f" && echo "/$f"; done <<<"$files")"
t_eq 'removal: every packaged file is gone (except a changed conffile)' '' "$left"
t_ok 'removal: the runtime state is gone' guest_exec \
	'test ! -e /var/run/adblock-fast-monitor -a ! -e /var/lock/adblock-fast-monitor.lock -a ! -e /var/lock/adblock-fast-monitor.logging.lock'
t_ok 'removal: rpcd dropped the plugin (no rpcd restart by hand)' guest_exec '! ubus list luci.adblock-fast-monitor 2>/dev/null'
t_ok 'removal: no package process' guest_exec \
	'a=/usr/libexec/adblock-fast; b=-monitor/; for p in /proc/[0-9]*; do case "$(tr "\0" " " <$p/cmdline 2>/dev/null)" in *"$a$b"*) exit 1;; esac; done'

# Back to the harness state: the same APK, the original configs.
t_ok "reinstall $pkg" guest_exec 'apk add --allow-untrusted /tmp/abfm-test/package.apk'
g 'cp /root/abfm-remove-config.bak /etc/config/adblock-fast-monitor; cp /root/abfm-remove-af.bak /etc/config/adblock-fast
	rm -f /root/abfm-remove-config.bak /root/abfm-remove-af.bak /etc/config/adblock-fast-monitor.apk-new
	/etc/init.d/adblock-fast-monitor restart; abfm_wait_until 30 nslookup localhost 127.0.0.1' >/dev/null
t_ok 'reinstall: the plugin is back' guest_exec 'ubus -t 15 wait_for luci.adblock-fast-monitor'
t_eq 'reinstall: query logging off again, no drop-in' '' "$(dropins)"
t_done
