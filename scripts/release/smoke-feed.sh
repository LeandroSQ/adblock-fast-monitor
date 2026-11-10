#!/bin/sh
# Post-publish smoke test of the public feed, run INSIDE a stock OpenWrt
# 25.12.6 rootfs container (apk 3.0.5, uclient-fetch), exactly as a router
# would consume it:
#
#   docker run --rm -v "$PWD/scripts/release:/r:ro" openwrt/rootfs:x86-64-25.12.6 \
#       /r/smoke-feed.sh https://leandrosq.github.io/adblock-fast-monitor
#
# Fetches the key and adds the feed line, then `apk update` must trust the
# index (no --allow-untrusted) and `apk add --simulate` must resolve the
# package with its dependencies from the official feeds.
set -eu
base="${1%/}"
pkg=luci-app-adblock-fast-monitor
mkdir -p /var/lock /var/run /tmp
uclient-fetch -q -O /etc/apk/keys/adblock-fast-monitor.pem "$base/keys/adblock-fast-monitor.pem"
grep -q 'PUBLIC KEY' /etc/apk/keys/adblock-fast-monitor.pem
echo "$base/apk/packages.adb" >>/etc/apk/repositories.d/customfeeds.list
out="$(apk update 2>&1)" || { echo "$out"; exit 1; }
echo "$out"
if echo "$out" | grep -q UNTRUSTED; then echo 'smoke: the feed index is not trusted'; exit 1; fi
apk search -x "$pkg" | grep -q "^$pkg-" || { echo "smoke: $pkg not in the feed"; exit 1; }
apk add --simulate "$pkg"
echo "smoke: ok"
