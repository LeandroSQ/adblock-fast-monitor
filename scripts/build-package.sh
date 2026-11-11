#!/usr/bin/env bash
# Builds luci-app-adblock-fast-monitor with the pinned OpenWrt 25.12.6 x86/64
# SDK (Linux x86_64 only; on macOS run: scripts/in-docker.sh --platform
# linux/amd64 -- scripts/build-package.sh).
#
# Output: .local-validation/artifacts/<UTC run id>/{package.apk,package.sha256,source.sha256}
# and the APK path on stdout. The SDK tree (and, when it has to be fetched, the
# verified tarball openwrt-sdk-25.12.6-<sha16>.tar.zst) is cached in
# .local-validation; an existing SDK tree is reused as-is (OPENWRT_SDK overrides). Builds in a shared SDK are
# serialised with flock, so concurrent worktrees cannot interleave.
set -euo pipefail

readonly SDK_URL='https://downloads.openwrt.org/releases/25.12.6/targets/x86/64/openwrt-sdk-25.12.6-x86-64_gcc-14.3.0_musl.Linux-x86_64.tar.zst'
readonly SDK_SHA256='1864152619092e781fa36a401960c8e9ae42d6a364c44ee5f0b197ca5f3c0fcc'
readonly PKG=luci-app-adblock-fast-monitor

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$root/.local-validation"
# Physical path: .local-validation may be a symlink to a shared cache.
cache="$(cd "$root/.local-validation" && pwd -P)"
log() { printf 'build-package: %s\n' "$*" >&2; }
[[ "$(uname -s)-$(uname -m)" == Linux-x86_64 ]] ||
	{ log 'the OpenWrt SDK needs Linux x86_64 (use scripts/in-docker.sh --platform linux/amd64)'; exit 1; }

sdk="${OPENWRT_SDK:-$(find "$cache" -maxdepth 1 -type d -name 'openwrt-sdk-25.12.6-*' -print -quit)}"
if [[ -z "$sdk" ]]; then
	exec 8>"$cache/.sdk-extract.lock"
	flock 8
	sdk="$(find "$cache" -maxdepth 1 -type d -name 'openwrt-sdk-25.12.6-*' -print -quit)"
	if [[ -z "$sdk" ]]; then
		# Content-addressed name: an existing tarball is never overwritten.
		tarball="$cache/openwrt-sdk-25.12.6-${SDK_SHA256:0:16}.tar.zst"
		if ! printf '%s  %s\n' "$SDK_SHA256" "$tarball" | sha256sum --check --status 2>/dev/null; then
			curl --fail --location --retry 3 --output "$tarball.partial.$$" "$SDK_URL"
			mv "$tarball.partial.$$" "$tarball"
		fi
		printf '%s  %s\n' "$SDK_SHA256" "$tarball" | sha256sum --check --status ||
			{ log 'SDK checksum mismatch'; exit 1; }
		tar --use-compress-program=unzstd -xf "$tarball" -C "$cache"
		sdk="$(find "$cache" -maxdepth 1 -type d -name 'openwrt-sdk-25.12.6-*' -print -quit)"
	fi
	exec 8>&-
fi
[[ -d "$sdk" ]] || { log "SDK not found: $sdk"; exit 1; }

run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
out="$cache/artifacts/$run_id"
mkdir -p "$out/source"
tar -C "$root" -cf - Makefile root htdocs $( [[ -d "$root/po" ]] && echo po) | tar -C "$out/source" -xf -
(cd "$out/source" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum) >"$out/source.sha256"

exec 9>"$sdk/.abfm-build.lock"
flock 9
if [[ ! -d "$sdk/feeds/base" || "${ABFM_SDK_FEEDS_UPDATE:-0}" == 1 ]]; then
	(cd "$sdk" && ./scripts/feeds update -a >/dev/null && ./scripts/feeds install -a >/dev/null)
fi
rm -rf "${sdk:?}/package/$PKG"
mkdir -p "$sdk/package/$PKG"
tar -C "$out/source" -cf - . | tar -C "$sdk/package/$PKG" -xf -
[[ -f "$sdk/.config" ]] || make -C "$sdk" defconfig >/dev/null
make -C "$sdk" "package/$PKG/clean" >"$out/build.log" 2>&1
make -C "$sdk" "package/$PKG/compile" V=s >>"$out/build.log" 2>&1 ||
	{ tail -n 60 "$out/build.log" >&2; log "build failed; log: $out/build.log"; exit 1; }
apk="$(find "$sdk/bin/packages" -type f -name "$PKG-*.apk" -newer "$out/source.sha256" -print -quit)"
[[ -n "$apk" ]] || { log 'build produced no APK'; exit 1; }
install -m 0644 "$apk" "$out/package.apk"
exec 9>&-

(cd "$out" && sha256sum package.apk >package.sha256)
log "built $(cat "$out/package.sha256")"
printf '%s\n' "$out/package.apk"
