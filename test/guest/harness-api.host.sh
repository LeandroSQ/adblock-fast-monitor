#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Harness smoke test, host side: the guest API and port forwards work.
set -u
fail=0 n=0
check() {
	n=$((n + 1))
	if "${@:2}" >/dev/null 2>&1; then echo "ok $n - $1"; else echo "not ok $n - $1"; fail=1; fi
}

check "guest_exec runs commands in the guest" guest_exec 'test -f /etc/openwrt_release'
echo "abfm-harness" >"$GUEST_RUN_DIR/copy-probe.txt"
guest_copy "$GUEST_RUN_DIR/copy-probe.txt" /tmp/abfm-copy/probe.txt
guest_fetch /tmp/abfm-copy/probe.txt "$GUEST_RUN_DIR/copy-probe.back"
check "guest_copy/guest_fetch round-trip" cmp "$GUEST_RUN_DIR/copy-probe.txt" "$GUEST_RUN_DIR/copy-probe.back"
# LuCI serves its login form with HTTP 403 until a session exists.
check "LuCI login form is served on GUEST_HTTP_URL" \
	bash -c 'curl --silent --max-time 10 "$GUEST_HTTP_URL/cgi-bin/luci/" | grep -q luci_username'
check "readonly LuCI account can log in" bash -c 'curl --silent --max-time 10 -o /dev/null -w "%{http_code}" \
	--data-urlencode "luci_username=$GUEST_READONLY_USER" --data-urlencode "luci_password=$GUEST_READONLY_PASSWORD" \
	"$GUEST_HTTP_URL/cgi-bin/luci/" | grep -qx 302'
if command -v dig >/dev/null; then
	check "dnsmasq answers on GUEST_DNS_PORT" dig +time=2 +tries=3 +short @127.0.0.1 -p "$GUEST_DNS_PORT" localhost
fi
echo "1..$n"
exit "$fail"
