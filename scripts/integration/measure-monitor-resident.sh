#!/usr/bin/env bash
# Measures the deployed, resident monitor in QEMU. This is intentionally not a
# host mock: it injects real syslog records into the guest and reads its procfs.
set -euo pipefail

output="${1:?output path required}"
fixtures=("${@:2}")
: "${OPENWRT_HOST:?Set OPENWRT_HOST to the QEMU guest.}"
: "${OPENWRT_SSH_KEY:?Set OPENWRT_SSH_KEY to the guest key.}"
: "${MONITOR_DNS_PROBE:?Set MONITOR_DNS_PROBE to an executable real-DNS probe.}"
: "${MONITOR_SATURATION_EVENTS:=2048}"

port="${OPENWRT_SSH_PORT:-22}"
ssh_opts=(-i "$OPENWRT_SSH_KEY" -p "$port" -o BatchMode=yes -o StrictHostKeyChecking=accept-new)
remote() { ssh "${ssh_opts[@]}" "root@$OPENWRT_HOST" "$@"; }

tree_snapshot() {
	remote '
		roots="$(ps w | awk "/[a]dblock-fast-monitor-(collector|ring\\.uc)/ {print \$1}")"
		[ -n "$roots" ] || exit 1
		pids="$roots"; frontier="$roots"
		while [ -n "$frontier" ]; do
			next=
			for proc in /proc/[0-9]*; do
				[ -r "$proc/stat" ] || continue
				ppid="$(awk "{print \$4}" "$proc/stat")"
				for parent in $frontier; do
					[ "$ppid" = "$parent" ] || continue
					pid="${proc#/proc/}"; pids="$pids $pid"; next="$next $pid"
				done
			done
			frontier="$next"
		done
		cpu=0; rss=0; count=0
		for pid in $pids; do
			[ -r "/proc/$pid/stat" ] || continue
			set -- $(awk "{print \$14, \$15}" "/proc/$pid/stat"); cpu=$((cpu + ${1:-0} + ${2:-0}))
			set -- $(awk "/VmRSS:/{print \$2}" "/proc/$pid/status"); rss=$((rss + ${1:-0}))
			count=$((count + 1))
		done
		printf "{\"cpuTicks\":%s,\"rssKiB\":%s,\"processes\":%s}\\n" "$cpu" "$rss" "$count"
	'
}
before_tree="$(tree_snapshot)"
status_total() {
	remote 'ubus call adblock-fast-monitor status' | node --input-type=module -e '
		let input = "";
		process.stdin.on("data", chunk => input += chunk);
		process.stdin.on("end", () => {
			const counters = JSON.parse(input).counters || {};
			console.log(Number(counters.allowed || 0) + Number(counters.blocked || 0) +
				Number(counters.unknown || 0) + Number(counters.lost || 0));
		});
	'
}
before_total="$(status_total)"
started_ns="$(date +%s%N)"

# logger writes through the actual guest syslog path consumed by logread -f.
remote "i=0; while [ \$i -lt $MONITOR_SATURATION_EVENTS ]; do logger -t dnsmasq \"reply load-\$i.example.test is 192.0.2.1\"; i=\$((i+1)); done"
expected_total=$((before_total + MONITOR_SATURATION_EVENTS))
status=
for _ in $(seq 1 20); do
	# A final event after the five-second coalescing interval forces publication.
	remote 'logger -t dnsmasq "reply saturation-flush.example.test is 192.0.2.1"'
	status="$(remote 'ubus call adblock-fast-monitor status')"
	current_total="$(printf '%s' "$status" | node --input-type=module -e '
		let input = ""; process.stdin.on("data", chunk => input += chunk);
		process.stdin.on("end", () => {
			const c = JSON.parse(input).counters || {};
			console.log(Number(c.allowed || 0) + Number(c.blocked || 0) + Number(c.unknown || 0) + Number(c.lost || 0));
		});
	')"
	if [ "$current_total" -ge "$expected_total" ]; then
		break
	fi
	status=
	sleep 1
done
[ -n "$status" ] || {
	echo "timed out waiting for a fresh ring status after $MONITOR_SATURATION_EVENTS injected events" >&2
	exit 1
}
after_tree="$(tree_snapshot)"

dns_json="$(node "$MONITOR_DNS_PROBE" "$OPENWRT_HOST" "$port" "${fixtures[@]}")"
after_dns_tree="$(tree_snapshot)"
ended_ns="$(date +%s%N)"

node --input-type=module - "$output" "$status" "$dns_json" "$before_tree" "$after_tree" "$after_dns_tree" "$started_ns" "$ended_ns" <<'NODE'
import { writeFileSync } from 'node:fs';
const [output, statusText, dnsText, beforeTreeText, afterTreeText, afterDnsTreeText, started, ended] = process.argv.slice(2);
const status = JSON.parse(statusText);
const dns = JSON.parse(dnsText);
const beforeTree = JSON.parse(beforeTreeText);
const afterTree = JSON.parse(afterTreeText);
const afterDnsTree = JSON.parse(afterDnsTreeText);
const elapsed = Math.max(1, Number(ended) - Number(started)) / 1e9;
const counters = status.counters || {};
const observed = Number(counters.allowed || 0) + Number(counters.blocked || 0) + Number(counters.unknown || 0);
const lost = Number(counters.lost || 0);
writeFileSync(output, `${JSON.stringify({
  measurementState: 'measured',
  measuredAt: new Date().toISOString(),
  p0: { classification: 'measured', label: 'P0 measured resident-ring QEMU run' },
  environment: { kind: 'openwrt-qemu', monitor: 'ucode resident ring', processTree: 'collector and descendants' },
  dnsQueryP95Ms: dns.p95Ms,
  peakRssMiB: Math.max(beforeTree.rssKiB, afterTree.rssKiB, afterDnsTree.rssKiB) / 1024,
  refreshSeconds: elapsed,
  monitor: {
    injectedEvents: Number(process.env.MONITOR_SATURATION_EVENTS || 2048),
    observedEvents: observed,
    lostEvents: lost,
    throughputEventsPerSecond: observed / elapsed,
    processTreeBefore: beforeTree,
    processTreeAfterSaturation: afterTree,
    processTreeAfterDns: afterDnsTree,
    collectorCpuTicks: afterDnsTree.cpuTicks - beforeTree.cpuTicks,
    dnsImpact: dns
  }
}, null, 2)}\n`);
NODE
