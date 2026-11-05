#!/usr/bin/env bash
set -euo pipefail

readonly SDK_URL='https://downloads.openwrt.org/releases/25.12.6/targets/x86/64/openwrt-sdk-25.12.6-x86-64_gcc-14.3.0_musl.Linux-x86_64.tar.zst'
readonly SDK_SHA256='1864152619092e781fa36a401960c8e9ae42d6a364c44ee5f0b197ca5f3c0fcc'
workdir=.local-validation

rm -rf "$workdir"
mkdir -p "$workdir"
curl --fail --location --retry 3 --output "$workdir/sdk.tar.zst" "$SDK_URL"
printf '%s  %s\n' "$SDK_SHA256" "$workdir/sdk.tar.zst" | sha256sum --check
tar --use-compress-program=unzstd -xf "$workdir/sdk.tar.zst" -C "$workdir"
sdk="$(find "$workdir" -maxdepth 1 -type d -name 'openwrt-sdk-*' -print -quit)"
test -n "$sdk"

mkdir -p "$sdk/package/luci-app-adblock-fast-monitor"
tar --exclude-vcs --exclude=node_modules --exclude=dist --exclude=.ci-work --exclude=.local-validation -cf - . |
	tar -C "$sdk/package/luci-app-adblock-fast-monitor" -xf -
timeout 10m bash -c "cd '$sdk' && ./scripts/feeds update -a && ./scripts/feeds install -a"
make -C "$sdk" defconfig
timeout 25m make -C "$sdk" package/luci-app-adblock-fast-monitor/compile V=s

export PACKAGE_IPK
PACKAGE_IPK="$(find "$sdk/bin/packages" -type f -name 'luci-app-adblock-fast-monitor_*.apk' -print -quit)"
test -n "$PACKAGE_IPK"
npm ci
npx playwright install --with-deps chromium
timeout 25m npm run test:qemu
