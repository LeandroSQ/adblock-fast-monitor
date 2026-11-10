#!/usr/bin/env bash
# Builds (or loads from cache) the OpenWrt 25.12.6 host userland image that
# provides the real ucode interpreter and BusyBox ash for host tests.
#
#   scripts/build-host-ucode.sh            # print the image tag, building if needed
#   scripts/build-host-ucode.sh --rebuild  # force a rebuild
#
# Cache: the Docker image itself (tag abfm-openwrt-userland:<hash>), plus a
# `docker save` tarball under .local-validation/host-ucode/<hash>.tar so a
# fresh Docker daemon or CI runner can `docker load` instead of compiling.
# The hash covers every build input, so changing a pin yields a new tag.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
context="$root/scripts/hosttools"
cache_dir="${ABFM_HOSTTOOLS_CACHE:-$root/.local-validation/host-ucode}"

hash="$(cat "$context/Dockerfile" "$context/pins.env" "$context/busybox-defaults.awk" \
	"$context/build-userland.sh" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-16)"
tag="abfm-openwrt-userland:$hash"
tarball="$cache_dir/$hash.tar"

log() { printf 'build-host-ucode: %s\n' "$*" >&2; }

docker info >/dev/null 2>&1 || { log 'Docker daemon is unavailable.'; exit 1; }

if [[ "${1:-}" != --rebuild ]] && docker image inspect "$tag" >/dev/null 2>&1; then
	printf '%s\n' "$tag"
	exit 0
fi
if [[ "${1:-}" != --rebuild && -f "$tarball" ]]; then
	log "loading cached image $tarball"
	docker load --quiet --input "$tarball" >/dev/null
	printf '%s\n' "$tag"
	exit 0
fi

log "building $tag (ucode/BusyBox at OpenWrt $(sed -n 's/^OPENWRT_RELEASE=//p' "$context/pins.env"))"
docker build --quiet --tag "$tag" --file "$context/Dockerfile" "$context" >/dev/null
if [[ "${ABFM_HOSTTOOLS_SAVE:-1}" == 1 ]]; then
	mkdir -p "$cache_dir"
	docker save --output "$tarball.partial" "$tag"
	mv "$tarball.partial" "$tarball"
fi
printf '%s\n' "$tag"
