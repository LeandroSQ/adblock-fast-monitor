#!/usr/bin/env bash
# Regenerates the captured dnsmasq 2.93 log fixtures in this directory from a
# real OpenWrt 25.12.6 guest (real dnsmasq + real adblock-fast serving the
# local fixture list). Run through the guest harness, e.g.
#
#   scripts/guest/run-guest-tests.sh --no-install --no-tests \
#     --host-cmd test/fixtures/dnsmasq/capture.sh PACKAGE.apk
#
# Queries come from the host side of QEMU user networking (10.0.2.2), plus
# router-local ones from 127.0.0.1 and ::1. Names are RFC 2606/6761 test
# names and RFC 5737/3849 addresses only.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
lib="$root/test/guest/dataplane-lib"
q() { python3 "$lib/dnsq.py" 127.0.0.1 "$GUEST_DNS_PORT" "$@" >/dev/null; }

guest_copy_dir "$lib" /tmp/abfm-dp
guest_exec ". /tmp/abfm-dp/guest.sh
	mkdir -p \"\$DP_CONFDIR\" && echo log-queries=extra >\"\$DP_CONFDIR/adblock-fast-monitor.conf\"
	dp_upstream_start"

capture() { # mode file
	guest_exec ". /tmp/abfm-dp/guest.sh && dp_af_setup $1 '$GUEST_FIXTURE_URL/lists/primary.txt' && logger -t abfm-capture begin-$1"
	q A ads.example.test sub.ads.example.test telemetry.example.test metrics.example.test
	q AAAA ads.example.test
	q HTTPS ads.example.test
	q A www.up.example.test www.up.example.test
	q AAAA www.up.example.test
	q HTTPS www.up.example.test
	q A nx.example.test err.example.test localhost openwrt.lan wpad printer.local
	q PTR 1.0.0.10.in-addr.arpa 1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.d.f.ip6.arpa
	q A 'victim.example.com is 0.0.0.0.example.test' 'bad\x01name.example.test' 'MiXeD.Example.Test'
	guest_exec "nslookup ads.example.test 127.0.0.1 >/dev/null 2>&1; nslookup www.up.example.test ::1 >/dev/null 2>&1; sleep 4
		logread | sed -n '/abfm-capture: begin-$1$/,\$p' | grep 'dnsmasq\\['" >"$here/$2"
	echo "captured $(wc -l <"$here/$2") lines into $2"
}

capture dnsmasq.servers servers.log
capture dnsmasq.addnhosts addnhosts.log
guest_exec ". /tmp/abfm-dp/guest.sh; dp_upstream_stop; rm -f \"\$DP_CONFDIR/adblock-fast-monitor.conf\""
