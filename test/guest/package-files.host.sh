#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# shellcheck disable=SC2016 # single-quoted commands are expanded by the guest shell
# T31, §2 package inventory on the guest (package installed by
# run-guest-tests): dependencies, file modes and owners, conffile defaults,
# package metadata, sysupgrade keep list.
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

files="$(guest_exec "apk info -qL $pkg" | grep -v ' contains:$' | sed '/^$/d')"
t_eq 'the package ships no uci-defaults script (nothing to migrate)' '' "$(grep '^etc/uci-defaults/' <<<"$files")"
# Mode/owner of every packaged file: 0755 under /etc/init.d and
# /usr/libexec, 0644 elsewhere, all root:root (rpcd skips world-writable
# ucode plugins).
modes="$(guest_exec \
	'. /tmp/abfm-test/lib/sh/testlib.sh; while read -r f; do printf "%s /%s\n" "$(abfm_stat "%a %u:%g" "/$f")" "$f"; done' <<<"$files")"
bad="$(awk '{ want = ($3 ~ "^/etc/init.d/" || $3 ~ "^/usr/libexec/") ? "755" : "644";
	if ($1 != want || $2 != "0:0") print $0 " (want " want " 0:0)" }' <<<"$modes")"
t_eq "all $(wc -l <<<"$modes" | tr -d ' ') packaged files have the §2 mode and root ownership" '' "$bad"

inventory=(
	/etc/config/adblock-fast-monitor:644
	/usr/share/rpcd/acl.d/luci-app-adblock-fast-monitor.json:644
	/lib/upgrade/keep.d/luci-app-adblock-fast-monitor:644
	/etc/init.d/adblock-fast-monitor:755
	/usr/libexec/adblock-fast-monitor/logging.uc:755
	/usr/share/ucode/abfm/system.uc:644
	/usr/libexec/adblock-fast-monitor/job.uc:755
	/usr/share/ucode/abfm/domain.uc:644
	/usr/share/rpcd/ucode/luci.adblock-fast-monitor:644
	/usr/share/luci/menu.d/luci-app-adblock-fast-monitor.json:644
	/www/luci-static/resources/view/adblock-fast-monitor/overview.js:644
	/www/luci-static/resources/view/status/include/75_adblock-fast-monitor.js:644
	/www/luci-static/resources/adblock-fast-monitor/model.js:644
	/www/luci-static/resources/adblock-fast-monitor/querylog.js:644
)
for entry in "${inventory[@]}"; do
	IFS=: read -r path mode <<<"$entry"
	t_eq "§2 $path is packaged with mode $mode" "$mode" "$(awk -v p="$path" '$3 == p { print $1 }' <<<"$modes")"
done
# apk lists its own bookkeeping for the package under /lib/apk/packages/.
extra="$(awk '{print $3}' <<<"$modes" | grep -v '^/lib/apk/packages/' | grep -vxF -f <(printf '%s\n' "${inventory[@]%%:*}") | tr '\n' ' ')"
t_eq "the package ships exactly the §2 files" '' "$extra"

t_ok 'the ACL file is valid JSON with the §9 grants (exact sets: package-acl.host.sh)' guest_exec "jsonfilter -i /usr/share/rpcd/acl.d/$pkg.json \
	-e '@[\"$pkg\"].read.ubus.log' -e '@[\"$pkg\"].read.uci' -e '@[\"$pkg\"].write.ubus[\"luci.adblock-fast-monitor\"]' >/dev/null"
shipped=/tmp/abfm-test/shipped
guest_exec "rm -rf $shipped && mkdir -p $shipped && apk extract --allow-untrusted --destination $shipped /tmp/abfm-test/package.apk" >/dev/null
cfg="$(guest_exec "uci -q -c $shipped/etc/config show adblock-fast-monitor")"
t_eq 'the shipped /etc/config/adblock-fast-monitor has the §3 defaults' "adblock-fast-monitor.config=monitor
adblock-fast-monitor.config.query_logging='0'" "$cfg"
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
# apk's installed database: P: name, L: license, m: maintainer.
meta="$(guest_exec "awk -v p='P:$pkg' '/^P:/ { on = (\$0 == p) } on' /lib/apk/db/installed")"
t_match 'package metadata: license Apache-2.0' '^L:Apache-2\.0$' "$meta"
t_match 'package metadata: a maintainer with a contact address' '^m:.+<[^ @>]+@[^ >]+>$' "$meta"
t_done
