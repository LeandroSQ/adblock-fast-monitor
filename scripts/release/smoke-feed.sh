#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Post-publish smoke test of the public feed, run INSIDE a stock OpenWrt
# 25.12.6 rootfs container (apk 3.0.5, uclient-fetch), exactly as a router
# would consume it:
#
#   docker run --rm -v "$PWD/scripts/release:/r:ro" openwrt/rootfs:x86-64-25.12.6 \
#       sh /r/smoke-feed.sh https://leandrosq.github.io/adblock-fast-monitor 0.2.0-r1
#
# Fetches the key and adds the feed line; then `apk update` must trust the
# index (no --allow-untrusted), the index must offer exactly VERSION of the
# package, and `apk add --simulate` must resolve that version with its
# dependencies from the official feeds. GitHub Pages serves with
# max-age=600, so a fresh deploy may show the previous feed for a while:
# missing files or an older version are retried for up to
# SMOKE_ATTEMPTS x SMOKE_DELAY seconds (default 24 x 30 s = 12 min). An
# untrusted index is never retried.
set -eu
base="${1:?usage: smoke-feed.sh BASE_URL VERSION}"
base="${base%/}"
version="${2:?usage: smoke-feed.sh BASE_URL VERSION}"
attempts="${SMOKE_ATTEMPTS:-24}"
delay="${SMOKE_DELAY:-30}"
pkg=luci-app-adblock-fast-monitor
key=/etc/apk/keys/adblock-fast-monitor.pem
mkdir -p /var/lock /var/run /tmp
echo "$base/apk/packages.adb" >>/etc/apk/repositories.d/customfeeds.list

try() {
	rm -f "$key"
	uclient-fetch -q -O "$key" "$base/keys/adblock-fast-monitor.pem" || { echo 'smoke: key not reachable yet'; return 1; }
	grep -q 'PUBLIC KEY' "$key" || { echo 'smoke: the key file is not a public key'; return 1; }
	out="$(apk update 2>&1)" && status=0 || status=$?
	echo "$out"
	if echo "$out" | grep -q UNTRUSTED; then echo 'smoke: the feed index is not trusted'; exit 1; fi
	[ "$status" = 0 ] || return 1
	found="$(apk search -x "$pkg")"
	echo "smoke: feed offers: ${found:-nothing}"
	echo "$found" | grep -qx "$pkg-$version"
}

n=1
until try; do
	[ "$n" -lt "$attempts" ] || { echo "smoke: $pkg-$version not served by $base after $n attempts"; exit 1; }
	echo "smoke: attempt $n/$attempts failed; retrying in ${delay}s"
	n=$((n + 1))
	sleep "$delay"
done
apk add --simulate "$pkg=$version"
echo "smoke: ok ($pkg-$version)"
