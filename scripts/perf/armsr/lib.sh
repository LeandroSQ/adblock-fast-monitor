# shellcheck shell=bash
# SPDX-License-Identifier: Apache-2.0
# Hardware-accelerated measurement guest (docs/performance.md → "Guests"):
# stock OpenWrt 25.12.6 armsr-armv8 under qemu-system-aarch64 with
# `-accel hvf`, run natively on an Apple-silicon Mac (no Docker). The package
# is PKGARCH all, so the x86/64 APK installs unchanged. Source it instead of
# scripts/guest/lib.sh; it keeps that API (guest_start, guest_exec,
# guest_copy, guest_reboot, guest_stop, GUEST_* outputs) and replaces only
# the image, the host checks and the QEMU command line.
#
# Inputs, in addition to scripts/guest/lib.sh's:
#   GUEST_BASELINE  default $GUEST_CACHE/abfm-baseline-25.12.6-armsr.qcow2,
#                   built by scripts/perf/armsr/prepare-baseline.sh
#   GUEST_ACCEL     auto (hvf when the host supports it, else tcg) | hvf | tcg
#   GUEST_FIRMWARE  UEFI code image (default: QEMU's edk2-aarch64-code.fd)
# Outputs: GUEST_ACCEL_USED (and ARMSR_ACCEL) is hvf or tcg; GUEST_TARGET=armsr-armv8.

ARMSR_LIB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=scripts/guest/lib.sh
source "$ARMSR_LIB_ROOT/scripts/guest/lib.sh"

# Pinned from https://downloads.openwrt.org/releases/25.12.6/targets/armsr/armv8/sha256sums
ARMSR_IMAGE_URL='https://downloads.openwrt.org/releases/25.12.6/targets/armsr/armv8/openwrt-25.12.6-armsr-armv8-generic-ext4-combined-efi.img.gz'
ARMSR_IMAGE_SHA256='77a3802b583a6964ccb868c80f83a6ea0eb5847d3835350b5f0bcbf6f141d1d3'
GUEST_TARGET=armsr-armv8

armsr__sha256() { # FILE
	if command -v shasum >/dev/null; then shasum -a 256 "$1"; else sha256sum "$1"; fi | awk '{print $1}'
}

armsr__firmware() {
	local f
	for f in "${GUEST_FIRMWARE:-}" "$(dirname "$(command -v qemu-system-aarch64 2>/dev/null || echo /x/x)")/../share/qemu/edk2-aarch64-code.fd" \
		/opt/homebrew/share/qemu/edk2-aarch64-code.fd /usr/local/share/qemu/edk2-aarch64-code.fd \
		/usr/share/qemu-efi-aarch64/QEMU_EFI.fd /usr/share/AAVMF/AAVMF_CODE.fd; do
		[[ -n "$f" && -f "$f" ]] && { printf '%s\n' "$f"; return 0; }
	done
	return 1
}

armsr__accel() {
	case "${GUEST_ACCEL:-auto}" in
		hvf | tcg) printf '%s\n' "$GUEST_ACCEL" ;;
		auto) if [[ "$(uname -s)" == Darwin && "$(sysctl -n kern.hv_support 2>/dev/null)" == 1 && "$(uname -m)" == arm64 ]]; then
			echo hvf; else echo tcg; fi ;;
		*) guest__die "GUEST_ACCEL=${GUEST_ACCEL} is not supported by the armsr guest (hvf|tcg)" ;;
	esac
}

guest_require_host() {
	local missing=() command
	for command in qemu-img qemu-system-aarch64 ssh ssh-keygen openssl python3 curl gzip; do
		command -v "$command" >/dev/null || missing+=("$command")
	done
	((${#missing[@]} == 0)) || guest__die "missing host prerequisites: ${missing[*]} (macOS: brew install qemu)" || return 1
	armsr__firmware >/dev/null || guest__die 'no aarch64 UEFI firmware (edk2-aarch64-code.fd); set GUEST_FIRMWARE'
}

# Downloads and verifies the stock armsr image once; never rewrites it.
guest_base_image() {
	local cache="${GUEST_CACHE:-$ARMSR_LIB_ROOT/.local-validation/qemu}"
	local raw="$cache/openwrt-armsr-base.img" gz="$cache/openwrt-armsr.img.gz"
	if [[ ! -f "$raw" ]]; then
		mkdir -p "$cache"
		if [[ ! -f "$gz" ]]; then
			curl --fail --location --retry 3 --output "$gz.partial" "$ARMSR_IMAGE_URL" || return 1
			mv "$gz.partial" "$gz"
		fi
		[[ "$(armsr__sha256 "$gz")" == "$ARMSR_IMAGE_SHA256" ]] ||
			guest__die "checksum mismatch: $gz (expected $ARMSR_IMAGE_SHA256)" || return 1
		# gzip exits 2 on the image's trailing padding warning; the data is complete.
		gzip -dc "$gz" >"$raw.partial" || [[ $? -eq 2 ]]
		mv "$raw.partial" "$raw"
	fi
	printf '%s\n' "$raw"
}

guest__launch_qemu() {
	local accel fw
	fw="$(armsr__firmware)"
	# shellcheck disable=SC2054 # the comma is part of the QEMU option value
	if [[ "${ARMSR_ACCEL:-tcg}" == hvf ]]; then accel=(-accel hvf -cpu host); else accel=(-accel tcg,thread=multi -cpu max); fi
	rm -f "$GUEST_RUN_DIR/serial.sock"
	qemu-system-aarch64 -M virt "${accel[@]}" -smp "${GUEST_CPUS:-2}" -m "${GUEST_MEMORY:-256}" \
		-bios "$fw" -display none -nic none \
		-chardev "socket,id=serial0,path=$GUEST_RUN_DIR/serial.sock,server=on,wait=off,logfile=$GUEST_RUN_DIR/serial.log,logappend=on" \
		-serial chardev:serial0 \
		-drive "file=$GUEST__DISK,format=qcow2,if=virtio" \
		-netdev "user,id=lan,hostfwd=tcp:127.0.0.1:$GUEST_SSH_PORT-:22,hostfwd=tcp:127.0.0.1:$GUEST_HTTP_PORT-:80,hostfwd=udp:127.0.0.1:$GUEST_DNS_PORT-:53" \
		-device virtio-net-pci,netdev=lan >>"$GUEST_RUN_DIR/qemu.log" 2>&1 &
	GUEST_QEMU_PID=$!
	echo "$GUEST_QEMU_PID" >"$GUEST_RUN_DIR/qemu.pid"
}

# scripts/guest/lib.sh's guest_start, renamed, does the run directory,
# overlay, keys, cache proxy, port retry and serial provisioning.
eval "$(declare -f guest_start | sed '1s/^guest_start/guest__generic_start/')"

guest_start() {
	local cache="${GUEST_CACHE:-$ARMSR_LIB_ROOT/.local-validation/qemu}" rc
	GUEST_BASELINE="${GUEST_BASELINE:-$cache/abfm-baseline-25.12.6-armsr.qcow2}"
	if [[ -z "${GUEST_DISK:-}" && ! -f "$GUEST_BASELINE" ]]; then
		guest__die "armsr baseline missing: $GUEST_BASELINE (build it with scripts/perf/armsr/prepare-baseline.sh)"
		return 1
	fi
	# macOS limits AF_UNIX paths to 103 bytes, and the serial socket lives in
	# the run directory: use it relative to the current directory when the
	# absolute path is too long (callers stay in the repository root).
	GUEST_RUN_DIR="${GUEST_RUN_DIR:-$cache/runs/armsr-$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM}"
	mkdir -p "$GUEST_RUN_DIR"
	if ((${#GUEST_RUN_DIR} + 12 > 103)); then
		GUEST_RUN_DIR="$(python3 -c 'import os, sys; print(os.path.relpath(sys.argv[1]))' "$GUEST_RUN_DIR")"
		((${#GUEST_RUN_DIR} + 12 <= 103)) || { guest__die "run directory path too long for a socket: $GUEST_RUN_DIR"; return 1; }
	fi
	ARMSR_ACCEL="$(armsr__accel)" || return 1
	local used="$ARMSR_ACCEL"
	# guest__generic_start finds no /dev/kvm and records tcg; the launcher
	# above uses ARMSR_ACCEL, and GUEST_ACCEL_USED is corrected afterwards.
	GUEST_BOOT_TIMEOUT="${GUEST_BOOT_TIMEOUT:-$([[ $used == hvf ]] && echo 120 || echo 900)}" \
		GUEST_ACCEL=tcg guest__generic_start
	rc=$?
	GUEST_ACCEL_USED="$used"
	export GUEST_ACCEL_USED GUEST_TARGET ARMSR_ACCEL
	((rc == 0)) && guest__log "armsr-armv8 guest up with $used"
	return "$rc"
}
