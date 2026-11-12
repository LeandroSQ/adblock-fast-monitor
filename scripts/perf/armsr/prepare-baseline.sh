#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Builds the hardware-accelerated measurement baseline (docs/performance.md →
# "Guests"), the armsr-armv8 counterpart of scripts/guest/prepare-baseline.sh:
# stock OpenWrt 25.12.6 armsr-armv8 (image verified against the pinned
# sha256 from downloads.openwrt.org) + adblock-fast 1.2.4-r4 and the other
# GUEST_BASELINE_PACKAGES from the official aarch64_generic feed (through the
# host pull-through cache), LAN on DHCP for QEMU user networking, no
# credentials, stock feed URLs. A qcow2 overlay over the verified raw image
# (relative backing path). Never overwrites an existing baseline; measurement
# runs get their own COW overlay and never write to it.
#
#   brew install qemu                      # once (macOS, Apple silicon)
#   scripts/perf/armsr/prepare-baseline.sh # ~1 min with hvf
#   GUEST_BASELINE=path.qcow2 GUEST_ACCEL=tcg scripts/perf/armsr/prepare-baseline.sh
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=scripts/perf/armsr/lib.sh
source "$root/scripts/perf/armsr/lib.sh"

cache="${GUEST_CACHE:-$root/.local-validation/qemu}"
baseline="${GUEST_BASELINE:-$cache/abfm-baseline-25.12.6-armsr.qcow2}"
packages="${GUEST_BASELINE_PACKAGES:-adblock-fast=1.2.4-r4 luci-app-package-manager luci-ssl}"

mkdir -p "$(dirname "$baseline")"
# mkdir is atomic everywhere (macOS has no flock(1)).
lock="$baseline.lockdir"
until mkdir "$lock" 2>/dev/null; do
	printf 'waiting for %s\n' "$lock" >&2
	sleep 5
done
partial="$baseline.partial"
cleanup() { guest_stop 2>/dev/null || true; rm -f "$partial"; rmdir "$lock" 2>/dev/null || true; }
trap cleanup EXIT
if [[ -f "$baseline" ]]; then
	printf 'baseline already present: %s\n' "$baseline" >&2
	exit 0
fi
guest_require_host
raw="$(guest_base_image)"
rm -f "$partial"
backing="$(python3 -c 'import os, sys; print(os.path.relpath(sys.argv[1], os.path.dirname(os.path.abspath(sys.argv[2]))))' "$raw" "$partial")"
qemu-img create -q -f qcow2 -F raw -b "$backing" "$partial"
# The stock combined image has a 120 MiB root; adblock-fast and LuCI fit.

GUEST_DISK="$partial" GUEST_RUN_DIR="$cache/runs/baseline-armsr-$$"
guest_start
guest_exec "set -e
	retry() { n=1; until \"\$@\"; do [ \$n -lt 3 ] || return 1; n=\$((n + 1)); sleep 10; done; }
	retry apk update >&2
	retry apk add $packages >&2
	apk info -v | sort" >"$GUEST_RUN_DIR/baseline-packages.txt"
grep -qx 'adblock-fast-1.2.4-r4' "$GUEST_RUN_DIR/baseline-packages.txt" ||
	{ echo 'prepare-baseline: adblock-fast 1.2.4-r4 is not installed' >&2; exit 1; }
guest_exec 'set -e
	grep -q "/packages/aarch64_generic/" /etc/apk/repositories.d/distfeeds.list
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

{
	printf 'release=25.12.6\ntarget=armsr-armv8\nimage_sha256=%s\nbase_image_sha256=%s\ncreated=%s\npackages=%s\naccel=%s\n' \
		"$ARMSR_IMAGE_SHA256" "$(armsr__sha256 "$raw")" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$packages" "$ARMSR_ACCEL"
	grep -E '^(adblock-fast|luci-base|ucode|busybox|dnsmasq|kernel)' "$GUEST_RUN_DIR/baseline-packages.txt" || true
} >"$baseline.manifest"
mv "$partial" "$baseline"
printf 'baseline ready: %s\n' "$baseline" >&2
