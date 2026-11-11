#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Builds luci-app-adblock-fast-monitor with the pinned OpenWrt 25.12.6 x86/64
# SDK (Linux x86_64 only; on macOS run: scripts/in-docker.sh --platform
# linux/amd64 -- scripts/build-package.sh).
#
# Output: $ABFM_BUILD_OUT (must be absent or empty; default
# .local-validation/artifacts/<UTC run id>) with package.apk, package.sha256,
# source/, source.sha256 and build.log; the APK path is the only line on
# stdout. On failure the last 60 lines of build.log go to stderr.
#
# Source: the packaged paths (Makefile, root, htdocs, po, LICENSE) of git HEAD
# when this checkout is a git work tree; uncommitted changes to them fail the
# build, so an APK always matches a commit. ABFM_BUILD_FROM=worktree builds
# the working tree instead (also the fallback outside a git work tree, e.g.
# the scratch copy of scripts/release/verify-upgrade.sh).
#
# SDK: the tarball .local-validation/openwrt-sdk-25.12.6-<sha16>.tar.zst is
# downloaded if missing and sha256-checked before every use.
# - Fresh (always when CI is set, or ABFM_SDK_FRESH=1): the verified tarball
#   is extracted into OUT/sdk for this build only and deleted afterwards
#   (ABFM_KEEP_SDK=1 keeps it). CI and release builds trust nothing but the
#   tarball checksum.
# - Shared (local default): the tree .local-validation/openwrt-sdk-25.12.6-*
#   that this script extracted from the verified tarball, or $OPENWRT_SDK, is
#   reused. It is a developer convenience; builds in it are serialised with
#   flock, so concurrent worktrees cannot interleave.
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

fresh="${ABFM_SDK_FRESH:-0}"
[[ -z "${CI:-}" || "${CI:-}" == false ]] || fresh=1

if [[ -n "${ABFM_BUILD_OUT:-}" ]]; then
	mkdir -p "$ABFM_BUILD_OUT"
	out="$(cd "$ABFM_BUILD_OUT" && pwd)"
	[[ -z "$(ls -A "$out")" ]] || { log "ABFM_BUILD_OUT is not empty: $out"; exit 1; }
else
	out="$cache/artifacts/$(date -u +%Y%m%dT%H%M%SZ)-$$"
	mkdir -p "$out"
fi
build_log="$out/build.log"
: >"$build_log"
fresh_sdk=''
on_exit() {
	local status=$?
	if ((status != 0)) && [[ -s "$build_log" ]]; then
		log "failed; last 60 lines of $build_log:"
		tail -n 60 "$build_log" >&2
	fi
	if [[ -n "$fresh_sdk" && "${ABFM_KEEP_SDK:-0}" != 1 ]]; then rm -rf "$fresh_sdk"; fi
	return "$status"
}
trap on_exit EXIT

# Downloads the tarball if needed; fails unless it matches SDK_SHA256.
verified_tarball() {
	# Content-addressed name: an existing tarball is never overwritten.
	local tarball="$cache/openwrt-sdk-25.12.6-${SDK_SHA256:0:16}.tar.zst"
	if ! printf '%s  %s\n' "$SDK_SHA256" "$tarball" | sha256sum --check --status 2>/dev/null; then
		log "downloading $SDK_URL"
		curl --fail --location --retry 3 --retry-all-errors --silent --show-error \
			--output "$tarball.partial.$$" "$SDK_URL"
		mv "$tarball.partial.$$" "$tarball"
	fi
	printf '%s  %s\n' "$SDK_SHA256" "$tarball" | sha256sum --check --status ||
		{ log "SDK checksum mismatch: $tarball"; return 1; }
	printf '%s\n' "$tarball"
}

# 1. Source
from="${ABFM_BUILD_FROM:-auto}"
git_() { git -C "$root" -c safe.directory='*' "$@"; }
if [[ "$from" == auto ]]; then
	from=worktree
	top="$(git_ rev-parse --show-toplevel 2>/dev/null)" &&
		[[ "$(cd "$top" && pwd -P)" == "$(cd "$root" && pwd -P)" ]] && from=head
fi
mkdir -p "$out/source"
case "$from" in
head)
	mapfile -t paths < <(git_ ls-tree --name-only HEAD -- Makefile root htdocs po LICENSE)
	[[ " ${paths[*]} " == *' Makefile '* ]] || { log 'HEAD has no Makefile'; exit 1; }
	dirty="$(git_ status --porcelain --untracked-files=all -- Makefile root htdocs po LICENSE)"
	if [[ -n "$dirty" ]]; then
		log "uncommitted changes in packaged paths (commit them, or set ABFM_BUILD_FROM=worktree):"
		printf '%s\n' "$dirty" >&2
		exit 1
	fi
	git_ archive --format=tar HEAD -- "${paths[@]}" | tar -C "$out/source" -xf -
	log "source: git $(git_ rev-parse --short=12 HEAD)"
	;;
worktree)
	paths=()
	for p in Makefile root htdocs po LICENSE; do [[ ! -e "$root/$p" ]] || paths+=("$p"); done
	tar -C "$root" -cf - "${paths[@]}" | tar -C "$out/source" -xf -
	log "source: working tree $root"
	;;
*) log "ABFM_BUILD_FROM must be auto, head or worktree"; exit 1 ;;
esac
(cd "$out/source" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum) >"$out/source.sha256"

# 2. SDK
if ((fresh)); then
	tarball="$(verified_tarball)"
	fresh_sdk="$out/sdk"
	mkdir -p "$fresh_sdk"
	log "extracting the verified SDK into $fresh_sdk"
	tar --use-compress-program=unzstd -xf "$tarball" -C "$fresh_sdk"
	sdk="$(find "$fresh_sdk" -mindepth 1 -maxdepth 1 -type d -name 'openwrt-sdk-25.12.6-*' -print -quit)"
else
	sdk="${OPENWRT_SDK:-$(find "$cache" -maxdepth 1 -type d -name 'openwrt-sdk-25.12.6-*' -print -quit)}"
	if [[ -z "$sdk" ]]; then
		exec 8>"$cache/.sdk-extract.lock"
		flock 8
		sdk="$(find "$cache" -maxdepth 1 -type d -name 'openwrt-sdk-25.12.6-*' -print -quit)"
		if [[ -z "$sdk" ]]; then
			tar --use-compress-program=unzstd -xf "$(verified_tarball)" -C "$cache"
			sdk="$(find "$cache" -maxdepth 1 -type d -name 'openwrt-sdk-25.12.6-*' -print -quit)"
		fi
		exec 8>&-
	fi
fi
[[ -n "$sdk" && -d "$sdk" ]] || { log "SDK not found: ${sdk:-none}"; exit 1; }

# 3. Build
exec 9>"$sdk/.abfm-build.lock"
flock 9
if [[ ! -d "$sdk/feeds/base" || "${ABFM_SDK_FEEDS_UPDATE:-0}" == 1 ]]; then
	# git.openwrt.org fails transiently; the feeds are pinned by commit in feeds.conf.default.
	for attempt in 1 2 3; do
		echo "== feeds update (attempt $attempt)" >>"$build_log"
		(cd "$sdk" && ./scripts/feeds update -a) >>"$build_log" 2>&1 && break
		((attempt < 3)) || { log 'feeds update failed 3 times'; exit 1; }
		sleep $((attempt * 15))
	done
	echo '== feeds install' >>"$build_log"
	(cd "$sdk" && ./scripts/feeds install -a) >>"$build_log" 2>&1
fi
rm -rf "${sdk:?}/package/$PKG"
mkdir -p "$sdk/package/$PKG"
tar -C "$out/source" -cf - . | tar -C "$sdk/package/$PKG" -xf -
if [[ ! -f "$sdk/.config" ]]; then
	echo '== defconfig' >>"$build_log"
	make -C "$sdk" defconfig >>"$build_log" 2>&1
fi
echo '== clean and compile' >>"$build_log"
make -C "$sdk" "package/$PKG/clean" >>"$build_log" 2>&1
make -C "$sdk" "package/$PKG/compile" V=s >>"$build_log" 2>&1
apk="$(find "$sdk/bin/packages" -type f -name "$PKG-*.apk" -newer "$out/source.sha256" -print -quit)"
[[ -n "$apk" ]] || { log 'build produced no APK'; exit 1; }
install -m 0644 "$apk" "$out/package.apk"
exec 9>&-

(cd "$out" && sha256sum package.apk >package.sha256)
log "built $(cat "$out/package.sha256") in $out"
printf '%s\n' "$out/package.apk"
