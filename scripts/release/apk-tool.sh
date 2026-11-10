#!/usr/bin/env bash
# Prints the path of an apk-tools 3.0.5 binary, the same build OpenWrt 25.12.6
# uses (the SDK's host apk). Linux x86_64 only.
#
#   APK="$(scripts/release/apk-tool.sh)"
#
# Order: $APK_TOOL if set; the SDK tree that scripts/build-package.sh unpacked
# into .local-validation; otherwise .apk.bin extracted from the pinned SDK
# tarball (SDK_URL/SDK_SHA256 read from scripts/build-package.sh, downloaded
# if missing, always sha256-checked) into $ABFM_APK_TOOL_DIR
# (default .local-validation/apk-tool).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
log() { printf 'apk-tool: %s\n' "$*" >&2; }
if [[ -n "${APK_TOOL:-}" ]]; then
	printf '%s\n' "$APK_TOOL"
	exit 0
fi
[[ "$(uname -s)-$(uname -m)" == Linux-x86_64 ]] ||
	{ log 'the SDK host apk needs Linux x86_64 (use scripts/in-docker.sh --platform linux/amd64)'; exit 1; }

check() { [[ -x "$1" ]] && "$1" --version 2>/dev/null | grep -q '^apk-tools 3\.0\.5,'; }

mkdir -p "$root/.local-validation"
cache="$(cd "$root/.local-validation" && pwd -P)"
sdk="$(find "$cache" -maxdepth 1 -type d -name 'openwrt-sdk-25.12.6-*' -print -quit)"
if [[ -n "$sdk" ]] && check "$sdk/staging_dir/host/bin/apk"; then
	printf '%s\n' "$sdk/staging_dir/host/bin/apk"
	exit 0
fi

dir="${ABFM_APK_TOOL_DIR:-$cache/apk-tool}"
if check "$dir/apk"; then
	printf '%s\n' "$dir/apk"
	exit 0
fi
url="$(sed -n "s/^readonly SDK_URL='\(.*\)'$/\1/p" "$root/scripts/build-package.sh")"
sha="$(sed -n "s/^readonly SDK_SHA256='\([0-9a-f]\{64\}\)'$/\1/p" "$root/scripts/build-package.sh")"
[[ -n "$url" && -n "$sha" ]] || { log 'cannot read SDK_URL/SDK_SHA256 from scripts/build-package.sh'; exit 1; }
tarball="${ABFM_SDK_TARBALL:-$cache/openwrt-sdk-25.12.6-${sha:0:16}.tar.zst}"
if ! printf '%s  %s\n' "$sha" "$tarball" | sha256sum --check --status 2>/dev/null; then
	log "downloading $url"
	curl --fail --location --retry 3 --silent --show-error --output "$tarball.partial.$$" "$url"
	mv "$tarball.partial.$$" "$tarball"
fi
printf '%s  %s\n' "$sha" "$tarball" | sha256sum --check --status || { log "SDK checksum mismatch: $tarball"; exit 1; }
mkdir -p "$dir"
tar --use-compress-program=unzstd -xf "$tarball" -C "$dir" --wildcards --strip-components=4 \
	'*/staging_dir/host/bin/.apk.bin'
mv "$dir/.apk.bin" "$dir/apk"
check "$dir/apk" || { log "extracted $dir/apk is not apk-tools 3.0.5"; exit 1; }
printf '%s\n' "$dir/apk"
