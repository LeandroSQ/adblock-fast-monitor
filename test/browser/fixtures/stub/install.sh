#!/bin/sh
# TEST-ONLY: replaces the package's backends in a disposable guest with the
# contract-shaped stubs in this directory (ABFM_UI_STUB=1 only; never shipped).
set -e
src="$(cd "$(dirname "$0")" && pwd)"
lib=/usr/libexec/adblock-fast-monitor
/etc/init.d/adblock-fast-monitor stop >/dev/null 2>&1 || :
mkdir -p "$lib" /usr/share/rpcd/ucode
cp "$src/monitord.uc" "$lib/stub-monitord.uc"
cp "$src/job.uc" "$lib/stub-job.uc"
chmod 0755 "$lib/stub-monitord.uc" "$lib/stub-job.uc"
cp "$src/plugin.uc" /usr/share/rpcd/ucode/luci.adblock-fast-monitor
chmod 0644 /usr/share/rpcd/ucode/luci.adblock-fast-monitor
cp "$src/acl.json" /usr/share/rpcd/acl.d/luci-app-adblock-fast-monitor.json
cp "$src/init" /etc/init.d/adblock-fast-monitor
chmod 0755 /etc/init.d/adblock-fast-monitor
/etc/init.d/adblock-fast-monitor enable
rm -f /tmp/luci-indexcache*
rm -rf /tmp/luci-modulecache/
/etc/init.d/rpcd reload
i=0
until ubus list luci.adblock-fast-monitor >/dev/null 2>&1; do
	i=$((i + 1)); [ $i -lt 30 ] || { echo 'stub plugin did not load' >&2; exit 1; }
	sleep 1
done
echo 'abfm UI stub installed'
