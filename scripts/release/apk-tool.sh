#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Prints the path of an apk-tools 3.0.5 binary, the same build OpenWrt 25.12.6
# uses (the SDK's host apk). Linux x86_64 only.
#
#   APK="$(scripts/release/apk-tool.sh)"
#
# The binary is staging_dir/host/bin/.apk.bin from the pinned SDK tarball
# (SDK_URL/SDK_SHA256 read from scripts/build-package.sh; downloaded if
# missing, always sha256-checked), extracted into $ABFM_APK_TOOL_DIR (default
# .local-validation/apk-tool). Every call checks the binary against
# APK_BIN_SHA256 and re-extracts it on a mismatch; $APK_TOOL, if set, must
# match it too. Nothing else (e.g. an SDK tree in .local-validation) is used.
set -euo pipefail

# sha256 of staging_dir/host/bin/.apk.bin in the SDK tarball pinned by
# scripts/build-package.sh (apk-tools 3.0.5); update both together.
readonly APK_BIN_SHA256='333ac1a66c2d616bedbb3bdf8d1d80fdf4e19f8512e0f4241bf8e865dd710930'

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
log() { printf 'apk-tool: %s\n' "$*" >&2; }
[[ "$(uname -s)-$(uname -m)" == Linux-x86_64 ]] ||
	{ log 'the SDK host apk needs Linux x86_64 (use scripts/in-docker.sh --platform linux/amd64)'; exit 1; }

pinned() { [[ -f "$1" && -x "$1" ]] && [[ "$(sha256sum <"$1" | cut -c1-64)" == "$APK_BIN_SHA256" ]]; }

if [[ -n "${APK_TOOL:-}" ]]; then
	pinned "$APK_TOOL" || { log "APK_TOOL=$APK_TOOL is not the pinned apk binary (sha256 $APK_BIN_SHA256)"; exit 1; }
	printf '%s\n' "$APK_TOOL"
	exit 0
fi

mkdir -p "$root/.local-validation"
cache="$(cd "$root/.local-validation" && pwd -P)"
dir="${ABFM_APK_TOOL_DIR:-$cache/apk-tool}"
mkdir -p "$dir"
dir="$(cd "$dir" && pwd -P)"
if pinned "$dir/apk"; then
	printf '%s\n' "$dir/apk"
	exit 0
fi

exec 8>"$dir/.lock"
flock 8
if ! pinned "$dir/apk"; then
	url="$(sed -n "s/^readonly SDK_URL='\(.*\)'$/\1/p" "$root/scripts/build-package.sh")"
	sha="$(sed -n "s/^readonly SDK_SHA256='\([0-9a-f]\{64\}\)'$/\1/p" "$root/scripts/build-package.sh")"
	[[ -n "$url" && -n "$sha" ]] || { log 'cannot read SDK_URL/SDK_SHA256 from scripts/build-package.sh'; exit 1; }
	tarball="${ABFM_SDK_TARBALL:-$cache/openwrt-sdk-25.12.6-${sha:0:16}.tar.zst}"
	if ! printf '%s  %s\n' "$sha" "$tarball" | sha256sum --check --status 2>/dev/null; then
		log "downloading $url"
		curl --fail --location --retry 3 --retry-all-errors --silent --show-error \
			--output "$tarball.partial.$$" "$url"
		mv "$tarball.partial.$$" "$tarball"
	fi
	printf '%s  %s\n' "$sha" "$tarball" | sha256sum --check --status || { log "SDK checksum mismatch: $tarball"; exit 1; }
	rm -rf "$dir/extract.$$"
	mkdir -p "$dir/extract.$$"
	tar --use-compress-program=unzstd -xf "$tarball" -C "$dir/extract.$$" --wildcards --strip-components=4 \
		'*/staging_dir/host/bin/.apk.bin'
	chmod 0755 "$dir/extract.$$/.apk.bin"
	pinned "$dir/extract.$$/.apk.bin" ||
		{ rm -rf "$dir/extract.$$"; log "the SDK's .apk.bin does not match APK_BIN_SHA256"; exit 1; }
	mv -f "$dir/extract.$$/.apk.bin" "$dir/apk"
	rm -rf "$dir/extract.$$"
fi
"$dir/apk" --version | grep -q '^apk-tools 3\.0\.5,' || { log "$dir/apk is not apk-tools 3.0.5"; exit 1; }
printf '%s\n' "$dir/apk"
