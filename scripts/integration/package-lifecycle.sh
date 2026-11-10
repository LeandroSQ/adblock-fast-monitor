#!/usr/bin/env bash
set -euo pipefail

stage=initialization
on_failure() {
	local rc=$?
	printf 'package lifecycle failure: stage=%s command=<sanitized> rc=%s\n' \
		"$stage" "$rc" >&2
	exit "$rc"
}
trap on_failure ERR

fail() {
	printf 'package lifecycle test: %s\n' "$*" >&2
	exit 1
}

: "${OPENWRT_HOST:?Set OPENWRT_HOST to the SSH-reachable OpenWrt guest.}"
: "${PACKAGE_IPK:?Set PACKAGE_IPK to the built luci-app-adblock-fast-monitor APK.}"
: "${OPENWRT_SSH_KEY:?Set OPENWRT_SSH_KEY to the guest private-key path.}"
: "${OPENWRT_RUNTIME_TEST:=$PWD/scripts/integration/runtime-dns-lifecycle.sh}"
: "${OPENWRT_LUCI_BASE_URL:?Set OPENWRT_LUCI_BASE_URL to the QEMU LuCI URL.}"
: "${OPENWRT_PACKAGE_MIRROR_URL:?Set OPENWRT_PACKAGE_MIRROR_URL to the private guest-visible mirror.}"
: "${PACKAGE_SHA256:?Set PACKAGE_SHA256 to the immutable artifact SHA-256.}"
OPENWRT_SSH_PORT="${OPENWRT_SSH_PORT:-22}"
stage_artifacts="${OPENWRT_STAGE_ARTIFACTS:-${GUEST_RUN_DIR:?Set OPENWRT_STAGE_ARTIFACTS or run under scripts/guest/run-guest-tests.sh}/stages}"
mkdir -p "$stage_artifacts"
stage_probe=0

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
	-O
	-i "$OPENWRT_SSH_KEY"
	-P "$OPENWRT_SSH_PORT"
	-o BatchMode=yes
	-o ConnectTimeout=10
	-o StrictHostKeyChecking=accept-new
)
guest="root@${OPENWRT_HOST}"
remote() {
	stage_probe=$((stage_probe + 1))
	local prefix="$stage_artifacts/${stage}-${stage_probe}"
	set +e
	ssh "${ssh_opts[@]}" "$guest" \
		"OPENWRT_PACKAGE_MIRROR_URL='$OPENWRT_PACKAGE_MIRROR_URL' PACKAGE_SHA256='$PACKAGE_SHA256' RING_DIAGNOSTIC='${RING_DIAGNOSTIC:-0}'; export OPENWRT_PACKAGE_MIRROR_URL PACKAGE_SHA256 RING_DIAGNOSTIC; $*" \
		>"$prefix.stdout" 2>"$prefix.stderr"
	local rc=$?
	set -e
	cat "$prefix.stdout"
	cat "$prefix.stderr" >&2
	printf '%s\n' "$rc" >"$prefix.rc"
	return "$rc"
}
copy_to_guest() {
	scp "${scp_opts[@]}" "$1" "${guest}:$2"
}

remote 'mkdir -p /root/adblock-fast-monitor-test/lists'
copy_to_guest "$PACKAGE_IPK" /root/adblock-fast-monitor-test/package.apk
copy_to_guest test/fixtures/lists/primary.txt /root/adblock-fast-monitor-test/lists/primary.txt
copy_to_guest test/fixtures/lists/allow.txt /root/adblock-fast-monitor-test/lists/allow.txt
copy_to_guest root/test/monitoring-stock-ucode-regression.sh /root/adblock-fast-monitor-test/monitoring-stock-ucode-regression.sh
copy_to_guest root/test/dns-resolver-readiness.sh /root/adblock-fast-monitor-test/dns-resolver-readiness.sh
copy_to_guest root/usr/libexec/adblock-fast-monitor-ring.uc /root/adblock-fast-monitor-test/ring-diagnostic.uc
copy_to_guest scripts/integration/guest-timeout.sh /root/adblock-fast-monitor-test/timeout

stage=package-surface-and-stock-ucode
remote '
	set -eu
	printf "%s  /root/adblock-fast-monitor-test/package.apk\n" "$PACKAGE_SHA256" | sha256sum -c -
	echo "=== private package mirror ==="
	cat /etc/apk/repositories.d/distfeeds.list
	! grep -R -q "downloads.openwrt.org" /etc/apk/repositories.d
	apk update
	apk add luci-ssl luci-app-package-manager adblock-fast
	/etc/init.d/rpcd restart
	/etc/init.d/uhttpd enable
	/etc/init.d/uhttpd restart
	apk --print-arch
	apk del luci-app-adblock-fast-monitor 2>/dev/null || true
	apk add --allow-untrusted /root/adblock-fast-monitor-test/package.apk
	apk info -e luci-app-adblock-fast-monitor
	apk info -e luci-base adblock-fast rpcd jsonfilter
	ubus list uci | grep -qx uci
	ubus call uci get '\''{"config":"adblock-fast-monitor"}'\'' | grep -q '"values"'
	ubus list session | grep -qx session
	test -x /usr/libexec/rpcd/adblock-fast-monitor
	test -x /usr/libexec/rpcd/adblock-fast-monitor-actions
	test -f /usr/share/rpcd/acl.d/luci-app-adblock-fast-monitor.json
	test -f /usr/share/luci/menu.d/luci-app-adblock-fast-monitor.json
	test -f /www/luci-static/resources/view/adblock-fast-monitor/settings.js
	test -f /www/luci-static/resources/adblock-fast-monitor/model.js
	test -x /usr/libexec/adblock-fast-monitor-metadata.uc
	grep -F 'ARGV[0]' /usr/libexec/adblock-fast-monitor-metadata.uc
	grep -F 'ARGV[1]' /usr/libexec/adblock-fast-monitor-metadata.uc
	grep -F 'ARGV[2]' /usr/libexec/adblock-fast-monitor-metadata.uc
	chmod 0755 /root/adblock-fast-monitor-test/timeout
	if [ "$RING_DIAGNOSTIC" = 1 ]; then
		chown root:root /root/adblock-fast-monitor-test/ring-diagnostic.uc
		chmod 0700 /root/adblock-fast-monitor-test/ring-diagnostic.uc
		ADBLOCK_FAST_MONITOR_RING=/root/adblock-fast-monitor-test/ring-diagnostic.uc
		export ADBLOCK_FAST_MONITOR_RING
	fi
	PATH=/root/adblock-fast-monitor-test:$PATH sh -x /root/adblock-fast-monitor-test/monitoring-stock-ucode-regression.sh
	if [ "${READER_ONLY_DIAGNOSTIC:-0}" = 1 ]; then
		echo "reader-only diagnostic passed; stopping before collector/LuCI/actions/P0"
		exit 0
	fi
	if [ "${PREPARE_INSTALLED_BASELINE:-0}" = 1 ]; then
		echo "installed package baseline prepared"
		exit 0
	fi
	uci get adblock-fast-monitor.config.enabled | grep -qx 0
	if /etc/init.d/adblock-fast-monitor status; then
		echo "monitor unexpectedly running while opt-in is disabled" >&2
		exit 1
	fi
	uci set adblock-fast-monitor.config.enabled=1
	uci commit adblock-fast-monitor
	/etc/init.d/adblock-fast-monitor enable
	/etc/init.d/adblock-fast-monitor restart
	sleep 2
	if ! /etc/init.d/adblock-fast-monitor status; then
		echo "collector failed after enabling opt-in monitoring" >&2
		echo "=== collector foreground trace ===" >&2
		set +e
		sh -x /usr/libexec/adblock-fast-monitor-collector
		collector_exit=$?
		set -e
		printf 'collector foreground exit=%s\n' "$collector_exit" >&2
		ubus call service list '\''{"name":"adblock-fast-monitor"}'\'' || true
		logread -e adblock-fast-monitor || true
		exit 1
	fi
	uci set adblock-fast-monitor.config.max_events=123
	uci commit adblock-fast-monitor
	/etc/init.d/adblock-fast-monitor reload
	grep -qx "	option max_events '\''123'\''" /etc/config/adblock-fast-monitor
	apk add --allow-untrusted --upgrade /root/adblock-fast-monitor-test/package.apk
	grep -qx "	option max_events '\''123'\''" /etc/config/adblock-fast-monitor
'

stage=readonly-acl
remote "
	set -eu
	session=\$(ubus call session login '{\"username\":\"$MONITOR_READONLY_LUCI_USERNAME\",\"password\":\"$MONITOR_READONLY_LUCI_PASSWORD\"}' | jsonfilter -e '@.ubus_rpc_session')
	test -n \"\$session\"
	ubus call session access '{\"ubus_rpc_session\":\"'\$session'\",\"scope\":\"ubus\",\"object\":\"adblock-fast-monitor\",\"function\":\"status\"}' | jsonfilter -e '@.access' | grep -qx true
	ubus call session access '{\"ubus_rpc_session\":\"'\$session'\",\"scope\":\"ubus\",\"object\":\"adblock-fast-monitor-actions\",\"function\":\"action\"}' | jsonfilter -e '@.access' | grep -qx false
"

stage=dns-actions
"$OPENWRT_RUNTIME_TEST"

stage=luci-browser
MONITOR_BASE_URL="$OPENWRT_LUCI_BASE_URL" \
MONITOR_LUCI_USERNAME="$MONITOR_READONLY_LUCI_USERNAME" \
MONITOR_LUCI_PASSWORD="$MONITOR_READONLY_LUCI_PASSWORD" \
npm run test:browser:required

stage=performance-p0
node scripts/integration/measure-performance.mjs

if [[ -n "${UPGRADE_PACKAGE_IPK:-}" ]]; then
	stage=package-upgrade
	[[ -f "$UPGRADE_PACKAGE_IPK" ]] || fail "UPGRADE_PACKAGE_IPK does not exist: $UPGRADE_PACKAGE_IPK"
	copy_to_guest "$UPGRADE_PACKAGE_IPK" /root/adblock-fast-monitor-test/upgrade.apk
	remote '
		set -eu
		apk add --allow-untrusted --upgrade /root/adblock-fast-monitor-test/upgrade.apk
		grep -qx "	option max_events '\''123'\''" /etc/config/adblock-fast-monitor
	'
fi

stage=luci-software-upload
remote '/etc/init.d/adblock-fast-monitor stop; apk del luci-app-adblock-fast-monitor'
node scripts/integration/luci-software-upload.mjs

stage=package-removal
remote '
	set -eu
	test -x /usr/libexec/adblock-fast-monitor-collector
	/etc/init.d/adblock-fast-monitor stop
	apk del luci-app-adblock-fast-monitor
	test ! -e /etc/init.d/adblock-fast-monitor
	grep -qx "	option max_events '\''123'\''" /etc/config/adblock-fast-monitor
'
printf 'Package lifecycle verification passed.\n'
