#!/usr/bin/env bash
set -euo pipefail

readonly release=25.12.6
readonly mirror_root=.local-validation/openwrt-package-mirror
readonly metadata="$mirror_root/manifest.env"

if [[ -f "$metadata" ]] && grep -qx "release=$release" "$metadata"; then
	exit 0
fi

rm -rf "$mirror_root"
mkdir -p "$mirror_root"
# The guest's stock repository file is authoritative. run-openwrt-qemu.sh
# captures it before mutation and fetches exactly those signed index paths.
printf 'release=%s\n' "$release" >"$metadata"
