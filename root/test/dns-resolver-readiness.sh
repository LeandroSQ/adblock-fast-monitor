#!/bin/sh
# Source this in guest runtime tests after every dnsmasq restart or reload.
# It verifies an A-only fixture response and retains diagnostics on failure.

abfm_dns_diagnostics() {
	local prefix="${ABFM_RESOLVER_ARTIFACTS:?Set ABFM_RESOLVER_ARTIFACTS}"

	{
		echo '=== dnsmasq service ==='
		ubus call service list '{"name":"dnsmasq"}' 2>&1 || true
		echo '=== dnsmasq processes ==='
		ps w 2>&1 || true
		echo '=== dnsmasq UCI ==='
		uci show dhcp 2>&1 || true
		echo '=== dnsmasq logs ==='
		logread -e dnsmasq 2>&1 || true
	} >"$prefix.diagnostics"
}

abfm_wait_dns_a_fixture() {
	local domain="$1" expected="$2"
	local attempt=1 rc
	local prefix="${ABFM_RESOLVER_ARTIFACTS:?Set ABFM_RESOLVER_ARTIFACTS}"
	local stdout="$prefix.stdout"
	local stderr="$prefix.stderr"
	local service="$prefix.service"

	while [ "$attempt" -le 15 ]; do
		ubus call service list '{"name":"dnsmasq"}' >"$service" 2>&1 || true
		if ! grep -q '"running": true' "$service"; then
			sleep 1
			attempt=$((attempt + 1))
			continue
		fi

		set +e
		nslookup -type=A "$domain" 127.0.0.1 >"$stdout" 2>"$stderr"
		rc=$?
		set -e
		if [ "$rc" -eq 0 ] && grep -Fq "$expected" "$stdout"; then
			echo "stage=dns-ready-a-fixture domain=$domain"
			return 0
		fi

		sleep 1
		attempt=$((attempt + 1))
	done

	abfm_dns_diagnostics
	echo "fixture resolver did not return $expected for $domain; retained:" >&2
	cat "$stdout" "$stderr" "$service" "$prefix.diagnostics" >&2
	return 1
}
