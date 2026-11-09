#!/bin/sh
# Run on the stock guest. Generates, but does not retain, a 5M-domain fixture.
set -eu
: "${CLASSIFIER:=/usr/libexec/adblock-fast-monitor-classifier.uc}"
: "${STATE:=/tmp/adblock-fast-monitor-classifier-p0}"
output="$STATE/active.servers"
rm -rf "$STATE"
mkdir -m 0700 "$STATE"
: >"$output"
i=0
while [ "$i" -lt 5000000 ]; do
	printf 'server=/entropy-%08d.example.test/\n' "$i" >>"$output"
	i=$((i + 1))
done
printf '0\n' >"$STATE/generation"
: >"$STATE/activity.tsv"
: >"$STATE/monitor.lock"
chmod 0600 "$STATE"/*
q=0
while [ "$q" -lt 128 ]; do
	printf '%s\tunknown\tentropy-%08d.example.test\tattribution-pending\tunknown\t0\n' "$q" "$q" >>"$STATE/activity.tsv"
	q=$((q + 1))
done
started="$(date +%s)"
/usr/bin/ucode "$CLASSIFIER" "$STATE" "$output" 128 128 &
pid=$!
rss_kib=0
cpu_ticks=0
while kill -0 "$pid" 2>/dev/null; do
	if [ -r "/proc/$pid/status" ]; then
		rss_kib="$(sed -n 's/^VmRSS:[[:space:]]*\\([0-9]*\\).*/\\1/p' "/proc/$pid/status" | head -n 1)"
	fi
	if [ -r "/proc/$pid/stat" ]; then
		cpu_ticks="$(awk '{ print $14 + $15 }' "/proc/$pid/stat")"
	fi
	sleep 1
done
wait "$pid"
finished="$(date +%s)"
[ -s "$STATE/classifications.tsv" ]
printf 'p0_scan_ms=%s\np0_rss_kib=%s\np0_cpu_ticks=%s\n' \
	"$(( (finished - started) * 1000 ))" "${rss_kib:-0}" "${cpu_ticks:-0}"
printf 'p0_fixture_domains=5000000\np0_query_entropy=128\np0_required_metrics=cpu_ticks,rss_kib,scan_ms,queue_delay_ms,overflow,stale\n'
