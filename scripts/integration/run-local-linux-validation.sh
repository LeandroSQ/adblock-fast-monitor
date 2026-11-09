#!/usr/bin/env bash
set -euo pipefail

readonly SDK_URL='https://downloads.openwrt.org/releases/25.12.6/targets/x86/64/openwrt-sdk-25.12.6-x86-64_gcc-14.3.0_musl.Linux-x86_64.tar.zst'
readonly SDK_SHA256='1864152619092e781fa36a401960c8e9ae42d6a364c44ee5f0b197ca5f3c0fcc'
workdir=.local-validation
run_id="$(date -u +%Y%m%dT%H%M%SZ)"
artifact_dir="$workdir/artifacts/$run_id"
source_manifest="$artifact_dir/source.sha256"
staged_source="$artifact_dir/source"
sdk_package_manifest="$workdir/sdk-package-source.sha256"

freeze_sources() {
	find "$staged_source/Makefile" "$staged_source/root" -type f -print0 |
		sort -z |
		xargs -0 sha256sum >"$source_manifest"
}

mkdir -p "$workdir"
sdk="$(find "$workdir" -maxdepth 1 -type d -name 'openwrt-sdk-*' -print -quit)"
if [[ -z "$sdk" ]]; then
	if [[ ! -f "$workdir/sdk.tar.zst" ]] ||
		! printf '%s  %s\n' "$SDK_SHA256" "$workdir/sdk.tar.zst" | sha256sum --check --status; then
		curl --fail --location --retry 3 --output "$workdir/sdk.tar.zst" "$SDK_URL"
	fi
	printf '%s  %s\n' "$SDK_SHA256" "$workdir/sdk.tar.zst" | sha256sum --check
	tar --use-compress-program=unzstd -xf "$workdir/sdk.tar.zst" -C "$workdir"
	sdk="$(find "$workdir" -maxdepth 1 -type d -name 'openwrt-sdk-*' -print -quit)"
fi
test -n "$sdk"
mkdir -p "$artifact_dir"
mkdir -p "$staged_source"
tar -cf - Makefile root | tar -C "$staged_source" -xf -
freeze_sources
export OPENWRT_SDK="$PWD/$sdk"

export PACKAGE_IPK
PACKAGE_IPK="$(find "$sdk/bin/packages" -type f -name 'luci-app-adblock-fast-monitor-*.apk' -print -quit)"
if [[ -z "$PACKAGE_IPK" || "${REBUILD_PACKAGE:-0}" == 1 ]] ||
	! cmp -s "$source_manifest" "$sdk_package_manifest"; then
	mkdir -p "$sdk/package/luci-app-adblock-fast-monitor"
	rm -rf "$sdk/package/luci-app-adblock-fast-monitor"/*
	tar -C "$staged_source" -cf - . |
		tar -C "$sdk/package/luci-app-adblock-fast-monitor" -xf -
	(cd "$sdk" && ./scripts/feeds update -a && ./scripts/feeds install -a)
	make -C "$sdk" defconfig
	make -C "$sdk" package/luci-app-adblock-fast-monitor/clean
	make -C "$sdk" package/luci-app-adblock-fast-monitor/compile V=s
	PACKAGE_IPK="$(find "$sdk/bin/packages" -type f -name 'luci-app-adblock-fast-monitor-*.apk' -print -quit)"
	install -m 0644 "$source_manifest" "$sdk_package_manifest"
fi
test -n "$PACKAGE_IPK"
source_manifest_after="$artifact_dir/source-after-build.sha256"
find "$staged_source/Makefile" "$staged_source/root" -type f -print0 | sort -z | xargs -0 sha256sum >"$source_manifest_after"
cmp -s "$source_manifest" "$source_manifest_after" ||
	{ echo "staged source inputs changed during package build" >&2; exit 1; }
install -m 0644 "$PACKAGE_IPK" "$artifact_dir/package.apk.partial"
mv "$artifact_dir/package.apk.partial" "$artifact_dir/package.apk"
sha256sum "$artifact_dir/package.apk" >"$artifact_dir/package.sha256"
sha256sum -c "$artifact_dir/package.sha256"
PACKAGE_IPK="$PWD/$artifact_dir/package.apk"
PACKAGE_SHA256="$(awk '{print $1}' "$artifact_dir/package.sha256")"
export PACKAGE_IPK PACKAGE_SHA256
scripts/integration/prepare-openwrt-package-mirror.sh
npm ci
npx playwright install --with-deps chromium
USE_RETAINED_PREPARED_BASELINE=1 npm run test:qemu
