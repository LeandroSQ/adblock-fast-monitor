#!/usr/bin/env bash
# Builds the guest baseline: stock OpenWrt 25.12.6 x86/64 + adblock-fast (and
# any GUEST_BASELINE_PACKAGES), LAN on DHCP for QEMU user networking, no
# credentials, stock feed URLs. The baseline is a qcow2 overlay whose backing
# file is the verified stock image referenced by a relative path, so it works
# at any mount point. Tests never write to it: every run gets its own COW
# overlay. Never overwrites an existing baseline (delete it to rebuild).
#
#   GUEST_BASELINE=path/to/baseline.qcow2 scripts/guest/prepare-baseline.sh
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/guest/lib.sh
source "$root/scripts/guest/lib.sh"

cache="${GUEST_CACHE:-$root/.local-validation/qemu}"
baseline="${GUEST_BASELINE:-$cache/abfm-baseline-25.12.6.qcow2}"
packages="${GUEST_BASELINE_PACKAGES:-adblock-fast luci-app-package-manager luci-ssl}"

mkdir -p "$(dirname "$baseline")"
exec 9>"$baseline.lock"
flock 9
if [[ -f "$baseline" ]]; then
	printf 'baseline already present: %s\n' "$baseline" >&2
	exit 0
fi

raw="$(guest_base_image)"
partial="$baseline.partial"
rm -f "$partial"
# Relative backing path: resolved against the overlay's own directory.
backing="$(python3 -c 'import os, sys; print(os.path.relpath(sys.argv[1], os.path.dirname(os.path.abspath(sys.argv[2]))))' "$raw" "$partial")"
qemu-img create -q -f qcow2 -F raw -b "$backing" "$partial"

trap guest_stop EXIT
GUEST_DISK="$partial" GUEST_RUN_DIR="$cache/runs/baseline-$(date -u +%Y%m%dT%H%M%SZ)-$$" guest_start
guest_exec "set -e; apk update; apk add $packages; apk info -v | sort" >"$GUEST_RUN_DIR/baseline-packages.txt"
guest_exec 'set -e
	sed -i -E "s#http://10[.]0[.]2[.]2:[0-9]+#https://downloads.openwrt.org#" /etc/apk/repositories.d/distfeeds.list
	sed -i "s|^root:[^:]*:|root::|" /etc/shadow
	sed -i "/^monitor-readonly:/d" /etc/passwd /etc/shadow
	uci -q delete rpcd.monitor_readonly || :
	uci commit rpcd
	rm -f /etc/dropbear/authorized_keys
	rm -rf /tmp/* 2>/dev/null || :
	sync'
guest_exec 'poweroff' || true
for ((i = 0; i < 120; i++)); do kill -0 "$GUEST_QEMU_PID" 2>/dev/null || break; sleep 1; done
guest_stop
trap - EXIT

{
	printf 'release=25.12.6\nbase_image_sha256=%s\ncreated=%s\npackages=%s\n' \
		"$(sha256sum "$raw" | awk '{print $1}')" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$packages"
	grep -E '^(adblock-fast|luci-base|ucode|busybox|dnsmasq)' "$GUEST_RUN_DIR/baseline-packages.txt" || true
} >"$baseline.manifest"
mv "$partial" "$baseline"
printf 'baseline ready: %s\n' "$baseline" >&2
