#!/bin/sh
# Run inside a stock OpenWrt guest after package installation. It validates the
# installed ucode helper, not a host substitute.
set -eu

helper=/usr/libexec/adblock-fast-monitor-metadata.uc
ring="${ADBLOCK_FAST_MONITOR_RING:-/usr/libexec/adblock-fast-monitor-ring.uc}"
base=/tmp/adblock-fast-monitor-ucode-regression
rm -rf "$base"
ring_pid=
stream_pid=
upstream_pid=
dhcp_backup=
adblock_fast_backup=

query_a() {
	local domain="$1" slug rc

	slug="$(printf '%s' "$domain" | tr '.' '_')"
	set +e
	nslookup -type=A "$domain" 127.0.0.1 \
		>"$base/query-${slug}.stdout" 2>"$base/query-${slug}.stderr"
	rc=$?
	set -e
	if [ "$rc" -ne 0 ]; then
		echo "A query failed for $domain (rc=$rc):" >&2
		cat "$base/query-${slug}.stdout" "$base/query-${slug}.stderr" >&2
		return "$rc"
	fi
}

cleanup() {
	if [ -n "$ring_pid" ]; then
		kill "$ring_pid" 2>/dev/null || true
		wait "$ring_pid" 2>/dev/null || true
	fi
	if [ -n "$stream_pid" ]; then
		kill "$stream_pid" 2>/dev/null || true
		wait "$stream_pid" 2>/dev/null || true
	fi
	if [ -n "$upstream_pid" ]; then
		kill "$upstream_pid" 2>/dev/null || true
		wait "$upstream_pid" 2>/dev/null || true
	fi
	if [ -n "$dhcp_backup" ] && [ -f "$dhcp_backup" ]; then
		cp "$dhcp_backup" /etc/config/dhcp
		/etc/init.d/dnsmasq reload >/dev/null 2>&1 || true
	fi
	if [ -n "$adblock_fast_backup" ] && [ -f "$adblock_fast_backup" ]; then
		cp "$adblock_fast_backup" /etc/config/adblock-fast
	fi
	rm -rf "$base"
}
trap cleanup EXIT INT TERM

set +e
/usr/bin/ucode "$helper" "$base" directory 448 >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = 3 ]

mkdir -m 0700 "$base"
/usr/bin/ucode "$helper" "$base" directory 448 | grep -qx ok
set +e
/usr/bin/ucode "$helper" "$base" file 448 >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = 1 ]
touch "$base/file"
chmod 0600 "$base/file"
/usr/bin/ucode "$helper" "$base/file" file 384 | grep -qx ok

chmod 0644 "$base/file"
! /usr/bin/ucode "$helper" "$base/file" file 384
chmod 0600 "$base/file"
ln -s file "$base/link"
! /usr/bin/ucode "$helper" "$base/link" file 384

if command -v chown >/dev/null && chown 65534:65534 "$base/file" 2>/dev/null; then
	! /usr/bin/ucode "$helper" "$base/file" file 384
else
	echo 'non-root ownership regression requires a guest with chown capability' >&2
	exit 1
fi

mkdir -m 0700 "$base/ring"
: >"$base/ring/activity.tsv"
printf 'state=running\nlost=0\ngeneration=0\n' >"$base/ring/status"
printf '0\n' >"$base/ring/generation"
: >"$base/ring/monitor.lock"
chmod 0600 "$base/ring/activity.tsv" "$base/ring/status" "$base/ring/generation" "$base/ring/monitor.lock"

set +e
/usr/bin/ucode "$ring" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = 64 ]

# This must be a real dnsmasq logqueries=extra transaction, not a synthetic
# logger reply. The query proves a matching config line is present before the
# ring may publish it.
dhcp_backup="$base/dhcp"
cp /etc/config/dhcp "$dhcp_backup"
adblock_fast_backup="$base/adblock-fast"
cp /etc/config/adblock-fast "$adblock_fast_backup"
uci -q set dhcp.@dnsmasq[0].logqueries=1
uci -q add_list dhcp.@dnsmasq[0].address='/abfm-ring.test/192.0.2.1'
uci -q add_list dhcp.@dnsmasq[0].address='/abfm-known-block.test/0.0.0.0'
uci -q add_list dhcp.@dnsmasq[0].server='/abfm-upstream.test/127.0.0.1#55353'
uci -q add_list dhcp.@dnsmasq[0].server='/abfm-nxdomain.test/127.0.0.1#55353'
uci -q add_list dhcp.@dnsmasq[0].server='/abfm-cname.test/127.0.0.1#55353'
uci -q add_list adblock-fast.config.blocked_domain=abfm-known-block.test
uci -q commit dhcp
uci -q commit adblock-fast

. /usr/lib/adblock-fast-monitor/common.sh
ADBLOCK_FAST_MONITOR_STATE="$base/ring"
MONITOR_STATE="$base/ring"
MONITOR_KNOWN_BLOCKED="$base/ring/known-blocked.tsv"
monitor_refresh_known_blocks

dnsmasq --no-daemon --no-resolv --port=55353 --listen-address=127.0.0.1 \
	--address=/abfm-upstream.test/8.8.8.8 --address=/abfm-nxdomain.test/ \
	--cname=abfm-cname.test,abfm-upstream.test \
	>"$base/upstream.stdout" 2>"$base/upstream.stderr" &
upstream_pid=$!
sleep 1
kill -0 "$upstream_pid"
/etc/init.d/dnsmasq reload
ABFM_RESOLVER_ARTIFACTS="$base/dns-ready"
. /root/adblock-fast-monitor-test/dns-resolver-readiness.sh
abfm_wait_dns_a_fixture abfm-ring.test 192.0.2.1
grep -Rqx 'log-queries=extra' /var/etc/dnsmasq.conf*

/sbin/logread -f >"$base/logread.stream" 2>"$base/logread.stderr" &
stream_pid=$!
/usr/bin/ucode "$ring" "$base/ring" 32 >"$base/ring.stdout" 2>"$base/ring.stderr" &
ring_pid=$!
/sbin/logread --help >"$base/logread.help.stdout" 2>"$base/logread.help.stderr" || true
readlink "/proc/$stream_pid/fd/1" >"$base/logread.stream-destination" 2>&1 || true
logger -t abfm-stream-ready stream-ready
/sbin/logread >"$base/logread.oneshot.stdout" 2>"$base/logread.oneshot.stderr"
for _ in $(seq 1 10); do
	if grep -Fq 'abfm-stream-ready' "$base/logread.stream"; then
		echo 'stage=stream-subscription-ready'
		break
	fi
	sleep 1
done
if ! grep -Fq 'abfm-stream-ready' "$base/logread.stream"; then
	echo 'logread subscription marker was not delivered:' >&2
	echo '=== logread help ===' >&2
	cat "$base/logread.help.stdout" "$base/logread.help.stderr" >&2
	echo '=== long-lived stdout destination ===' >&2
	cat "$base/logread.stream-destination" >&2
	echo '=== one-shot logread ===' >&2
	cat "$base/logread.oneshot.stdout" "$base/logread.oneshot.stderr" >&2
	echo '=== long-lived logread ===' >&2
	cat "$base/logread.stream" "$base/logread.stderr" >&2
	exit 1
fi
kill -0 "$stream_pid"
kill -0 "$ring_pid"
echo 'stage=stream-reader-open'
query_a abfm-ring.test
query_a abfm-known-block.test
query_a abfm-upstream.test
query_a abfm-upstream.test
query_a abfm-nxdomain.test || true
query_a abfm-cname.test
grep -Fq 'abfm-upstream.test' "$base/query-abfm-cname_test.stdout"

for _ in $(seq 1 10); do
	if grep -Eq '(^|dnsmasq.*: .*?)query\[A\] abfm-ring\.test from ' "$base/logread.stream" &&
		grep -Eq '(^|dnsmasq.*: .*?)config abfm-ring\.test is ' "$base/logread.stream"; then
		echo 'stage=stream-bytes'
		break
	fi
	sleep 1
done
if ! grep -Eq '(^|dnsmasq.*: .*?)query\[A\] abfm-ring\.test from ' "$base/logread.stream" ||
	! grep -Eq '(^|dnsmasq.*: .*?)config abfm-ring\.test is ' "$base/logread.stream"; then
	echo 'missing authentic DNS records from a live logread stream:' >&2
	cat "$base/logread.stream" "$base/logread.stderr" >&2
	logread -e dnsmasq >&2 || true
	grep -R 'log-queries' /var/etc/dnsmasq.conf* >&2 || true
	exit 1
fi
if grep -Eq 'dnsmasq.*: .*query\[A\] abfm-ring\.test from ' "$base/logread.stream"; then
	echo 'stage=stream-framing=syslog-pid-or-serial'
else
	echo 'stage=stream-framing=raw-payload'
fi

for _ in $(seq 1 10); do
	if grep -Eq '^[0-9]+\tunknown\tabfm-ring\.test\tlocal-config\tunknown$' "$base/ring/activity.tsv" &&
		grep -Eq '^[0-9]+\tblocked\tabfm-known-block\.test\tadblock-fast-config\tunknown$' "$base/ring/activity.tsv" &&
		grep -Eq '^[0-9]+\tallowed\tabfm-upstream\.test\tupstream-reply\tunknown$' "$base/ring/activity.tsv" &&
		grep -Eq '^[0-9]+\tallowed\tabfm-upstream\.test\tcached-response\tunknown$' "$base/ring/activity.tsv" &&
		grep -Eq '^[0-9]+\tallowed\tabfm-nxdomain\.test\tupstream-nxdomain\tunknown$' "$base/ring/activity.tsv" &&
		grep -Eq '^[0-9]+\tunknown\tabfm-cname\.test\tcname-ambiguous\tunknown$' "$base/ring/activity.tsv"; then
		echo 'stage=classification-accepted'
		break
	fi
	sleep 1
done
if ! kill -0 "$ring_pid" 2>/dev/null; then
	echo 'resident ring exited before publication:' >&2
	cat "$base/ring.stderr" >&2
	exit 1
fi
grep -Eq '^[0-9]+\tunknown\tabfm-ring\.test\tlocal-config\tunknown$' "$base/ring/activity.tsv"
grep -Eq '^[0-9]+\tblocked\tabfm-known-block\.test\tadblock-fast-config\tunknown$' "$base/ring/activity.tsv"
grep -Eq '^[0-9]+\tallowed\tabfm-upstream\.test\tupstream-reply\tunknown$' "$base/ring/activity.tsv"
grep -Eq '^[0-9]+\tallowed\tabfm-upstream\.test\tcached-response\tunknown$' "$base/ring/activity.tsv"
grep -Eq '^[0-9]+\tallowed\tabfm-nxdomain\.test\tupstream-nxdomain\tunknown$' "$base/ring/activity.tsv"
grep -Eq '^[0-9]+\tunknown\tabfm-cname\.test\tcname-ambiguous\tunknown$' "$base/ring/activity.tsv"
echo 'stage=bounded-retention-insert'

for _ in $(seq 1 10); do
	if grep -Eq '^unknown=[1-9][0-9]*$' "$base/ring/status" &&
		grep -qx 'generation=0' "$base/ring/status"; then
		echo 'stage=publication-generation'
		break
	fi
	sleep 1
done
grep -Eq '^unknown=[1-9][0-9]*$' "$base/ring/status"
grep -qx 'generation=0' "$base/ring/status"
test ! -s "$base/ring.stderr"
