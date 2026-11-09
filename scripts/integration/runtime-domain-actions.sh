#!/usr/bin/env bash
set -euo pipefail

: "${OPENWRT_HOST:?}"
: "${OPENWRT_SSH_PORT:?}"
: "${OPENWRT_SSH_KEY:?}"
: "${FIXTURE_LIST_URL:?}"

ssh_opts=(-i "$OPENWRT_SSH_KEY" -p "$OPENWRT_SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new)
remote() { ssh "${ssh_opts[@]}" "root@$OPENWRT_HOST" "$@"; }
dns_a() { dig +time=2 +tries=1 +short @"$OPENWRT_HOST" -p 5353 "$1" A; }
dns_aaaa() { dig +time=2 +tries=1 +short @"$OPENWRT_HOST" -p 5353 "$1" AAAA; }

wait_job() {
	local expected_state="$1" job state result
	for _ in $(seq 1 60); do
		job="$(remote "ubus call adblock-fast-monitor-actions job '{}'")"
		state="$(printf '%s' "$job" | jsonfilter -e '@.state')"
		case "$state" in
			queued|applying) sleep 1 ;;
			*)
				result="$(printf '%s' "$job" | jsonfilter -e '@.result')"
				[ "$state" = "$expected_state" ] || {
					printf 'unexpected action job: %s\n' "$job" >&2
					return 1
				}
				printf '%s\n' "$result"
				return 0
				;;
		esac
	done
	echo 'timed out waiting for an adblock-fast monitor action job' >&2
	return 1
}

wait_terminal_state() {
	local job state
	for _ in $(seq 1 60); do
		job="$(remote "ubus call adblock-fast-monitor-actions job '{}'")"
		state="$(printf '%s' "$job" | jsonfilter -e '@.state')"
		case "$state" in
			queued|applying) sleep 1 ;;
			*) printf '%s\n' "$state"; return 0 ;;
		esac
	done
	echo 'timed out waiting for an adblock-fast monitor action job' >&2
	return 1
}

call_action() {
	local action="$1" domain="$2" confirmation="$3" response
	response="$(remote "ubus call adblock-fast-monitor-actions action '{\"action\":\"$action\",\"domain\":\"$domain\",\"confirm_rebuild\":$confirmation}'")"
	printf '%s' "$response" | jsonfilter -e '@.accepted' | grep -Eq 'true|1' || {
		printf 'action was not accepted: %s\n' "$response" >&2
		return 1
	}
	printf '%s' "$response" | jsonfilter -e '@.state' | grep -qx queued
}

assert_blocked_a() {
	dns_a "$1" | grep -qx '0.0.0.0'
}

assert_blocked_aaaa() {
	local answer
	answer="$(dns_aaaa "$1")"
	[ -z "$answer" ] || [ "$answer" = '::' ]
}

assert_not_blocked_a() {
	! dns_a "$1" | grep -qx '0.0.0.0'
}

assert_job_string() {
	remote "ubus call adblock-fast-monitor-actions job '{}' | jsonfilter -e '@.$1'" | grep -qx "$2"
}

assert_job_boolean() {
	remote "ubus call adblock-fast-monitor-actions job '{}' | jsonfilter -e '@.$1'" | grep -Eq 'true|1'
}

remote "
	set -eu
	# The production worker requires PSL data before it will mutate UCI. This
	# minimal runtime fixture has no public suffix matching the test domains.
	mkdir -p /usr/share/publicsuffix
	printf 'com\nco.uk\n' > /usr/share/publicsuffix/public_suffix_list.dat
	chmod 0644 /usr/share/publicsuffix/public_suffix_list.dat

	# Exercise adblock-fast itself, rather than dnsmasq addnhosts configured by
	# the monitor test. A real file_url is downloaded from the QEMU host.
	uci -q del_list dhcp.@dnsmasq[0].addnhosts=/root/adblock-fast-monitor-test/lists/primary.txt || true
	uci -q delete adblock-fast.runtime_fixture || true
	uci set adblock-fast.runtime_fixture=file_url
	uci set adblock-fast.runtime_fixture.name='QEMU action fixture'
	uci set adblock-fast.runtime_fixture.url='$FIXTURE_LIST_URL/primary.txt'
	uci set adblock-fast.runtime_fixture.action='block'
	uci set adblock-fast.runtime_fixture.enabled='1'
	uci set adblock-fast.runtime_fixture.size='256'
	uci set adblock-fast.config.enabled='1'
	uci set adblock-fast.config.dns='dnsmasq.addnhosts'
	uci -q del_list adblock-fast.config.allowed_domain=ads.example.test || true
	uci -q del_list adblock-fast.config.blocked_domain=action-block.example.test || true
	uci -q del_list adblock-fast.config.blocked_domain=action-failure.example.test || true
	uci commit adblock-fast
	uci commit dhcp
	/etc/init.d/dnsmasq restart
	/etc/init.d/adblock-fast enable
	/etc/init.d/adblock-fast dl
	ABFM_RESOLVER_ARTIFACTS=/root/adblock-fast-monitor-test/domain-actions-ready
	. /root/adblock-fast-monitor-test/dns-resolver-readiness.sh
	abfm_wait_dns_a_fixture ads.example.test 0.0.0.0
	/etc/init.d/adblock-fast check ads.example.test | grep -F 'Found'
"

# A real generated list must block the fixture domain before allow removes it.
assert_blocked_a ads.example.test
confirmation_denied="$(remote "ubus call adblock-fast-monitor-actions action '{\"action\":\"block\",\"domain\":\"action-unconfirmed.example.test\",\"confirm_rebuild\":false}'")"
printf '%s' "$confirmation_denied" | jsonfilter -e '@.error' | grep -qx confirmation-required
remote "! uci -q get adblock-fast.config.blocked_domain | tr ' ' '\n' | grep -Fx action-unconfirmed.example.test"
conflict_denied="$(remote "ubus call adblock-fast-monitor-actions action '{\"action\":\"block\",\"domain\":\"ads.example.test\",\"confirm_rebuild\":true}'")"
printf '%s' "$conflict_denied" | jsonfilter -e '@.accepted' | grep -Eq 'true|1'
[ "$(wait_job rejected)" = conflict ]
call_action allow ads.example.test false
[ "$(wait_job degraded)" = persisted-active-unknown ]
remote "uci -q get adblock-fast.config.allowed_domain | tr ' ' '\n' | grep -Fx ads.example.test"
assert_job_boolean persisted
assert_job_string active_dns unknown
assert_not_blocked_a ads.example.test
call_action unallow ads.example.test true
[ "$(wait_job degraded)" = persisted-active-unknown ]
remote "! uci -q get adblock-fast.config.allowed_domain | tr ' ' '\n' | grep -Fx ads.example.test"
assert_job_string persisted false
assert_job_string active_dns unknown
assert_blocked_a ads.example.test

# Cache a pre-action response, then verify the real dl lifecycle changes both
# direct and CNAME resolution. IPv6 must not expose a routable response.
assert_not_blocked_a action-block.example.test
dns_a action-block.example.test >/dev/null || true
remote "
	uci -q add_list dhcp.@dnsmasq[0].cname='action-cname.example.test,action-block.example.test'
	uci commit dhcp
	/etc/init.d/dnsmasq restart
	abfm_wait_dns_a_fixture ads.example.test 0.0.0.0
"
call_action block action-block.example.test true
[ "$(wait_job degraded)" = persisted-active-unknown ]
remote "/etc/init.d/adblock-fast check action-block.example.test | grep -F 'Found'"
remote "uci -q get adblock-fast.config.blocked_domain | tr ' ' '\n' | grep -Fx action-block.example.test"
assert_job_boolean persisted
assert_job_string active_dns unknown
assert_blocked_a action-block.example.test
assert_blocked_a action-cname.example.test
assert_blocked_aaaa action-block.example.test
call_action block action-block.example.test true
[ "$(wait_job completed)" = noop ]
assert_blocked_a action-block.example.test

# Removing the custom rule runs dl again; it must invalidate the cached block.
call_action unblock action-block.example.test true
[ "$(wait_job degraded)" = persisted-active-unknown ]
remote "! uci -q get adblock-fast.config.blocked_domain | tr ' ' '\n' | grep -Fx action-block.example.test"
assert_job_string persisted false
assert_job_string active_dns unknown
assert_not_blocked_a action-block.example.test

# An actual lifecycle execution failure must not be reported as a successful
# rebuild. Temporarily removing the real executable guarantees exec failure
# without substituting a mock implementation.
init_disabled=0
restore_init() {
	if [ "$init_disabled" = 1 ]; then
		remote 'mv /etc/init.d/adblock-fast.runtime-test-disabled /etc/init.d/adblock-fast' >/dev/null 2>&1 || true
	fi
}
trap restore_init EXIT
remote 'mv /etc/init.d/adblock-fast /etc/init.d/adblock-fast.runtime-test-disabled'
init_disabled=1
call_action block action-failure.example.test true
[ "$(wait_job failed)" = rebuild-failed-active-unverified ]
assert_job_boolean persisted
assert_job_string active_dns unknown
assert_blocked_a ads.example.test
restore_init
init_disabled=0
remote "uci -q get adblock-fast.config.blocked_domain | tr ' ' '\n' | grep -Fx action-failure.example.test"
call_action unblock action-failure.example.test true
[ "$(wait_job degraded)" = persisted-active-unknown ]

# Production RPC validation rejects malformed payloads before it writes a
# queued job; PSL cases are then rejected by the worker before lifecycle use.
malformed="$(remote "ubus call adblock-fast-monitor-actions action '{\"action\":\"block\",\"domain\":\"bad;domain\",\"confirm_rebuild\":true}'")"
printf '%s' "$malformed" | jsonfilter -e '@.error' | grep -qx invalid-domain
call_action block co.uk true
[ "$(wait_job rejected)" = public-suffix ]
remote "
	printf '*.ck\n!www.ck\n' >> /usr/share/publicsuffix/public_suffix_list.dat
"
call_action block foo.ck true
[ "$(wait_job rejected)" = public-suffix ]

# A real slow file_url keeps the first lifecycle job active long enough to
# prove the RPC lock rejects a concurrent request without launching another dl.
remote "
	uci -q delete adblock-fast.runtime_slow || true
	uci set adblock-fast.runtime_slow=file_url
	uci set adblock-fast.runtime_slow.name='QEMU slow action fixture'
	uci set adblock-fast.runtime_slow.url='http://10.255.255.1/never'
	uci set adblock-fast.runtime_slow.action='block'
	uci set adblock-fast.runtime_slow.enabled='1'
	uci set adblock-fast.runtime_slow.size='1'
	uci set adblock-fast.config.download_connect_timeout='10'
	uci commit adblock-fast
"
call_action block action-concurrent-one.example.test true
for _ in $(seq 1 20); do
	second="$(remote "ubus call adblock-fast-monitor-actions action '{\"action\":\"allow\",\"domain\":\"action-concurrent-two.example.test\",\"confirm_rebuild\":false}'")"
	if printf '%s' "$second" | jsonfilter -e '@.error' | grep -qx busy; then
		break
	fi
	sleep 1
done
printf '%s' "${second:-}" | jsonfilter -e '@.error' | grep -qx busy
case "$(wait_terminal_state)" in
	degraded|failed) ;;
	*) echo 'concurrent lifecycle job did not reach a terminal state' >&2; exit 1 ;;
esac
remote "
	uci -q delete adblock-fast.runtime_slow
	uci set adblock-fast.config.download_connect_timeout='10'
	uci commit adblock-fast
	/etc/init.d/adblock-fast dl
"

# A persisted custom block remains active after an actual guest reboot while
# volatile job state correctly stops claiming a pre-reboot result.
call_action block action-reboot.example.test true
[ "$(wait_job degraded)" = persisted-active-unknown ]
assert_blocked_a action-reboot.example.test
remote 'sync; reboot' || true
for _ in $(seq 1 90); do
	if remote true 2>/dev/null; then
		break
	fi
	sleep 2
done
remote true
assert_blocked_a action-reboot.example.test
remote "uci -q get adblock-fast.config.blocked_domain | tr ' ' '\n' | grep -Fx action-reboot.example.test"
job_after_reboot="$(remote "ubus call adblock-fast-monitor-actions job '{}'")"
printf '%s' "$job_after_reboot" | jsonfilter -e '@.state' | grep -qx unknown

printf 'Domain action runtime verification passed.\n'
