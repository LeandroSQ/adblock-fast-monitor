#!/usr/bin/env bash
set -euo pipefail

fail() {
	printf 'package lifecycle test: %s\n' "$*" >&2
	exit 1
}

: "${OPENWRT_HOST:?Set OPENWRT_HOST to the SSH-reachable OpenWrt guest.}"
: "${PACKAGE_IPK:?Set PACKAGE_IPK to the built luci-app-adblock-fast-monitor APK.}"
: "${OPENWRT_SSH_KEY:?Set OPENWRT_SSH_KEY to the guest private-key path.}"
: "${OPENWRT_RUNTIME_TEST:?Set OPENWRT_RUNTIME_TEST to the in-repository runtime adapter.}"
: "${OPENWRT_LUCI_BASE_URL:?Set OPENWRT_LUCI_BASE_URL to the QEMU LuCI URL.}"
OPENWRT_SSH_PORT="${OPENWRT_SSH_PORT:-22}"

[[ -f "$PACKAGE_IPK" ]] || fail "PACKAGE_IPK does not exist: $PACKAGE_IPK"
[[ -f "$OPENWRT_SSH_KEY" ]] || fail "OPENWRT_SSH_KEY does not exist: $OPENWRT_SSH_KEY"
[[ -x "$OPENWRT_RUNTIME_TEST" ]] || fail "OPENWRT_RUNTIME_TEST is not executable: $OPENWRT_RUNTIME_TEST"

ssh_opts=(
	-i "$OPENWRT_SSH_KEY"
	-p "$OPENWRT_SSH_PORT"
	-o BatchMode=yes
	-o ConnectTimeout=10
	-o StrictHostKeyChecking=accept-new
)
scp_opts=(
	-i "$OPENWRT_SSH_KEY"
	-P "$OPENWRT_SSH_PORT"
	-o BatchMode=yes
	-o ConnectTimeout=10
	-o StrictHostKeyChecking=accept-new
)
guest="root@${OPENWRT_HOST}"
remote() {
	ssh "${ssh_opts[@]}" "$guest" "$@"
}
copy_to_guest() {
	scp "${scp_opts[@]}" "$1" "${guest}:$2"
}

remote 'mkdir -p /root/adblock-fast-monitor-test/lists'
copy_to_guest "$PACKAGE_IPK" /root/adblock-fast-monitor-test/package.apk
copy_to_guest test/fixtures/lists/primary.txt /root/adblock-fast-monitor-test/lists/primary.txt
copy_to_guest test/fixtures/lists/allow.txt /root/adblock-fast-monitor-test/lists/allow.txt

remote '
	set -eu
	apk update
	apk add luci-ssl luci-app-package-manager adblock-fast
	/etc/init.d/rpcd restart
	/etc/init.d/uhttpd enable
	/etc/init.d/uhttpd restart
	apk --print-arch
	apk info --allow-untrusted --info /root/adblock-fast-monitor-test/package.apk |
		grep -Eq "^arch: all$" ||
		{ echo "APK metadata is not arch: all" >&2; exit 1; }
	apk add --allow-untrusted /root/adblock-fast-monitor-test/package.apk
	apk info -e luci-base adblock-fast rpcd rpcd-mod-uci jsonfilter
	test -x /usr/libexec/rpcd/adblock-fast-monitor
	test -x /usr/libexec/rpcd/adblock-fast-monitor-actions
	test -f /usr/share/rpcd/acl.d/luci-app-adblock-fast-monitor.json
	test -f /usr/share/luci/menu.d/luci-app-adblock-fast-monitor.json
	test -f /www/luci-static/resources/view/adblock-fast-monitor/settings.js
	test -f /www/luci-static/resources/adblock-fast-monitor/model.js
	/etc/init.d/adblock-fast-monitor enable
	/etc/init.d/adblock-fast-monitor start
	/etc/init.d/adblock-fast-monitor status
	uci set adblock-fast-monitor.config.max_events=123
	uci commit adblock-fast-monitor
	/etc/init.d/adblock-fast-monitor reload
	grep -qx "	option max_events '\''123'\''" /etc/config/adblock-fast-monitor
	apk add --allow-untrusted --upgrade /root/adblock-fast-monitor-test/package.apk
	grep -qx "	option max_events '\''123'\''" /etc/config/adblock-fast-monitor
'
remote "
	set -eu
	session=\$(ubus call session login '{\"username\":\"$MONITOR_READONLY_LUCI_USERNAME\",\"password\":\"$MONITOR_READONLY_LUCI_PASSWORD\"}' | jsonfilter -e '@.ubus_rpc_session')
	test -n \"\$session\"
	ubus call session access '{\"ubus_rpc_session\":\"'\$session'\",\"scope\":\"ubus\",\"object\":\"adblock-fast-monitor\",\"function\":\"status\"}' | jsonfilter -e '@.access' | grep -qx true
	ubus call session access '{\"ubus_rpc_session\":\"'\$session'\",\"scope\":\"ubus\",\"object\":\"adblock-fast-monitor-actions\",\"function\":\"action\"}' | jsonfilter -e '@.access' | grep -qx false
"
"$OPENWRT_RUNTIME_TEST"

MONITOR_BASE_URL="$OPENWRT_LUCI_BASE_URL" \
MONITOR_LUCI_USERNAME="$MONITOR_READONLY_LUCI_USERNAME" \
MONITOR_LUCI_PASSWORD="$MONITOR_READONLY_LUCI_PASSWORD" \
npm run test:browser:required

node scripts/integration/measure-performance.mjs

if [[ -n "${UPGRADE_PACKAGE_IPK:-}" ]]; then
	[[ -f "$UPGRADE_PACKAGE_IPK" ]] || fail "UPGRADE_PACKAGE_IPK does not exist: $UPGRADE_PACKAGE_IPK"
	copy_to_guest "$UPGRADE_PACKAGE_IPK" /root/adblock-fast-monitor-test/upgrade.apk
	remote '
		set -eu
		apk add --allow-untrusted --upgrade /root/adblock-fast-monitor-test/upgrade.apk
		grep -qx "	option max_events '\''123'\''" /etc/config/adblock-fast-monitor
	'
fi

remote '/etc/init.d/adblock-fast-monitor stop; apk del luci-app-adblock-fast-monitor'
node scripts/integration/luci-software-upload.mjs

remote '
	set -eu
	test -x /usr/libexec/adblock-fast-monitor-collector
	/etc/init.d/adblock-fast-monitor stop
	apk del luci-app-adblock-fast-monitor
	test ! -e /etc/init.d/adblock-fast-monitor
	grep -qx "	option max_events '\''123'\''" /etc/config/adblock-fast-monitor
'
printf 'Package lifecycle verification passed.\n'
