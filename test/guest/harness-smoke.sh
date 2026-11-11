#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Harness smoke test: proves the guest runner boots a fresh stock 25.12.6
# overlay, installed the APK under test, and exposes the shared helpers.
# It deliberately checks no monitor feature.
. "$ABFM_TESTLIB/sh/testlib.sh"

t_match "guest runs OpenWrt 25.12.6" "25\.12\.6" "$(cat /etc/openwrt_release)"
t_ok "APK under test is installed" apk info -e luci-app-adblock-fast-monitor
t_ok "adblock-fast is installed in the baseline" apk info -e adblock-fast
t_not "stock BusyBox has no stat applet" sh -c 'command -v stat'
t_not "stock BusyBox has no timeout applet" sh -c 'command -v timeout'

dir=$(abfm_tmpdir)
mkdir -m 0700 "$dir/state"
t_eq "abfm_stat works on the guest" "0:700:directory" "$(abfm_stat '%u:%a:%F' "$dir/state")"
t_ok "fixtures were copied" test -f "$ABFM_FIXTURES/lists/primary.txt"
t_ok "host fixture server is reachable from the guest" \
	sh -c 'uclient-fetch -q -O - "$ABFM_FIXTURE_URL/lists/primary.txt" | grep -q example.test'
t_ok "dnsmasq answers on the LAN" nslookup localhost 127.0.0.1

t_done
