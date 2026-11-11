#!/usr/bin/env bash
# §2 package inventory on the guest (package installed by run-guest-tests):
# dependencies, file modes and owners, conffile defaults, sysupgrade keep list,
# and that the v0 and v1 daemon files are gone.
# The config defaults are read from the APK as shipped (earlier tests in a
# shared guest may have changed the live /etc/config file).
set -u
. test/lib/sh/testlib.sh
pkg=luci-app-adblock-fast-monitor

t_ok "$pkg is installed" guest_exec "apk info -e $pkg"

deps="$(guest_exec "apk info -R $pkg" | sed -n 's/^\([a-z][a-z0-9.+-]*\)$/\1/p' | grep -v "^$pkg" | LC_ALL=C sort | tr '\n' ' ')"
t_eq 'depends exactly on luci-base, adblock-fast, ucode-mod-{io,resolv} (and libc)' \
	'adblock-fast libc luci-base ucode-mod-io ucode-mod-resolv ' "$deps"
t_ok 'luci-base provides rpcd, rpcd-mod-ucode and the ucode fs/uci/ubus modules' guest_exec \
	'for p in rpcd rpcd-mod-ucode ucode ucode-mod-fs ucode-mod-uci ucode-mod-ubus; do apk info -e $p >/dev/null || { echo missing $p; exit 1; }; done'

# default_postinst runs /etc/uci-defaults/* of the package and deletes each
# script that succeeded (§3 migration).
files="$(guest_exec "apk info -qL $pkg" | grep -v ' contains:$' | sed '/^$/d')"
t_eq 'the package ships one uci-defaults script' 'etc/uci-defaults/80_adblock-fast-monitor' "$(grep '^etc/uci-defaults/' <<<"$files")"
t_ok 'default_postinst ran and removed it' guest_exec 'test ! -e /etc/uci-defaults/80_adblock-fast-monitor'
# Mode/owner of every other packaged file: 0755 under /etc/init.d and
# /usr/libexec, 0644 elsewhere, all root:root (rpcd skips world-writable
# ucode plugins).
modes="$(grep -v '^etc/uci-defaults/' <<<"$files" | guest_exec \
	'. /tmp/abfm-test/lib/sh/testlib.sh; while read -r f; do printf "%s /%s\n" "$(abfm_stat "%a %u:%g" "/$f")" "$f"; done')"
bad="$(awk '{ want = ($3 ~ "^/etc/init.d/" || $3 ~ "^/usr/libexec/") ? "755" : "644";
	if ($1 != want || $2 != "0:0") print $0 " (want " want " 0:0)" }' <<<"$modes")"
t_eq "all $(wc -l <<<"$modes" | tr -d ' ') packaged files have the §2 mode and root ownership" '' "$bad"

inventory=(
	/etc/config/adblock-fast-monitor:644:WU4
	/usr/share/rpcd/acl.d/luci-app-adblock-fast-monitor.json:644:WU4
	/lib/upgrade/keep.d/luci-app-adblock-fast-monitor:644:WU4
	/etc/init.d/adblock-fast-monitor:755:WU1
	/usr/libexec/adblock-fast-monitor/logging.uc:755:WU1
	/usr/share/ucode/abfm/system.uc:644:WU1
	/usr/libexec/adblock-fast-monitor/job.uc:755:WU2
	/usr/share/ucode/abfm/domain.uc:644:WU2
	/usr/share/rpcd/ucode/luci.adblock-fast-monitor:644:WU2
	/usr/share/luci/menu.d/luci-app-adblock-fast-monitor.json:644:WU3
	/www/luci-static/resources/view/adblock-fast-monitor/overview.js:644:WU3
	/www/luci-static/resources/view/adblock-fast-monitor/settings.js:644:WU3
	/www/luci-static/resources/adblock-fast-monitor/model.js:644:WU3
)
for entry in "${inventory[@]}"; do
	IFS=: read -r path mode _ <<<"$entry"
	t_eq "§2 $path is packaged with mode $mode" "$mode" "$(awk -v p="$path" '$3 == p { print $1 }' <<<"$modes")"
done

v0="$(grep -E '^/(test/|usr/lib/adblock-fast-monitor/|usr/libexec/rpcd/adblock-fast-monitor|usr/libexec/adblock-fast-monitor-|usr/libexec/adblock-fast-monitor/monitord\.uc|usr/share/ucode/abfm/(logparse|stats)\.uc)' <<<"$(awk '{print $3}' <<<"$modes")" | tr '\n' ' ')"
t_eq 'no v0 or v1 daemon files are shipped (sh plugins, collector, monitord, logparse, stats)' '' "$v0"

t_ok 'the ACL file is valid JSON with the §9 grants (exact sets: package-acl.host.sh)' guest_exec "jsonfilter -i /usr/share/rpcd/acl.d/$pkg.json \
	-e '@[\"$pkg\"].read.ubus.log' -e '@[\"$pkg\"].read.uci' -e '@[\"$pkg\"].write.ubus[\"luci.adblock-fast-monitor\"]' >/dev/null"
shipped=/tmp/abfm-test/shipped
guest_exec "rm -rf $shipped && mkdir -p $shipped && apk extract --allow-untrusted --destination $shipped /tmp/abfm-test/package.apk" >/dev/null
cfg="$(guest_exec "uci -q -c $shipped/etc/config show adblock-fast-monitor")"
t_eq 'the shipped /etc/config/adblock-fast-monitor has the §3 defaults' "adblock-fast-monitor.config=monitor
adblock-fast-monitor.config.query_logging='0'
adblock-fast-monitor.config.dnsmasq_instance='*'
adblock-fast-monitor.config.exclude_router='1'
adblock-fast-monitor.config.poll_interval='2'" "$cfg"
t_ok 'the live /etc/config/adblock-fast-monitor is a registered conffile' guest_exec \
	"test -f /etc/config/adblock-fast-monitor && grep -qx '/etc/config/adblock-fast-monitor' /lib/apk/packages/$pkg.conffiles"
t_eq 'the registered conffile checksum is the shipped file' \
	"$(guest_exec "sha256sum < $shipped/etc/config/adblock-fast-monitor" | cut -d' ' -f1)" \
	"$(guest_exec "sed -n 's#^/etc/config/adblock-fast-monitor ##p' /lib/apk/packages/$pkg.conffiles_static")"
guest_exec "rm -rf $shipped"

# sysupgrade keeps the feed key (added through LuCI, not owned by any package)
# and this package's config.
t_ok 'sysupgrade -l keeps /etc/apk/keys/adblock-fast-monitor.pem when it exists' guest_exec \
	'k=/etc/apk/keys/adblock-fast-monitor.pem; had=0; [ -e $k ] && had=1 || echo probe >$k;
	 sysupgrade -l | grep -qx $k; rc=$?; [ $had = 1 ] || rm -f $k; exit $rc'
t_ok 'sysupgrade -l keeps /etc/config/adblock-fast-monitor' guest_exec 'sysupgrade -l | grep -qx /etc/config/adblock-fast-monitor'
t_done
