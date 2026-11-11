#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# P6 attribution (docs/performance.md → "P6: dnsmasq cost of query logging"):
# A/B of dnsmasq and logd CPU on one guest, so host noise is shared by every
# arm. Host command for either guest runner:
#
#   scripts/verify-guest.sh --no-install --no-tests --host-cmd scripts/perf/ab-dnsmasq.sh PKG.apk   # x86/64
#   scripts/perf/armsr/run-guest.sh scripts/perf/ab-dnsmasq.sh PKG.apk                          # armsr-armv8, hvf
#
# Arms (ABFM_AB_REPEATS, default 5; ABFM_AB_QPS, default "50 200"):
#   off      package installed, query_logging=0, no drop-in
#   manual   query_logging=0 + the package's drop-in copied by hand
#            (dnsmasq's own query logging, no package involvement)
#   product  query_logging=1 (the package's drop-in and procd trigger)
# The arm order rotates every repeat, and every arm starts with a dnsmasq
# restart and waits until dnsmasq is ABFM_AB_SETTLE_AGE (20) s old, so
# neither order nor restart age favours an arm. Switches go through uci
# commit + reload_config only (what LuCI does). Output: $ABFM_AB_OUT/ab.jsonl
# (one line per window, CPU with the gate's task-based validity check) and
# summary.txt (medians, spreads, product − manual and product − off).
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root" || exit 1
out="${ABFM_AB_OUT:-$root/.local-validation/perf/ab-$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM}"
mkdir -p "$out/raw"
reps="${ABFM_AB_REPEATS:-5}"
secs="${ABFM_AB_SECONDS:-20}"
rates="${ABFM_AB_QPS:-50 200}"
age="${ABFM_AB_SETTLE_AGE:-20}"
G=/tmp/abfm-perf
log() { printf 'ab: %s\n' "$*" >&2; }
gl() { guest_exec ". $G/lib.sh; $*"; }

if ! { guest_exec "mkdir -p $G" && guest_copy scripts/perf/guest/probe.uc "$G/probe.uc" && guest_copy scripts/perf/guest/lib.sh "$G/lib.sh"; }; then
	log 'cannot copy the probe into the guest'; exit 1
fi
gl perf_prepare >"$out/prepare.json" 2>&1 || { log 'fixtures failed'; exit 1; }
guest_exec 'apk add --allow-untrusted /tmp/abfm-test/package.apk' >"$out/install.log" 2>&1 || { log 'install failed'; exit 1; }
if ! { gl perf_set 1 >"$out/enable.json" 2>&1 && gl perf_capture_dropin >"$out/dropin.json" 2>&1; }; then
	log 'cannot capture the drop-in'; exit 1
fi
printf '{"accel":"%s","guest":"%s","repeats":%d,"seconds":%d,"rates":"%s","settle_age_s":%d,"package_sha256":"%s"}\n' \
	"${GUEST_ACCEL_USED:-?}" "${GUEST_TARGET:-x86-64}" "$reps" "$secs" "$rates" "$age" "${PACKAGE_SHA256:-}" >"$out/meta.json"

logging=1
arm_state() { # arm r
	local want=0 manual=0
	[[ $1 == product ]] && want=1
	[[ $1 == manual ]] && manual=1
	if [[ $logging != "$want" ]]; then gl perf_set "$want" >"$out/raw/set-$1-r$2.json" 2>&1; logging=$want; fi
	gl "perf_manual $manual && perf_restart $age" >"$out/raw/restart-$1-r$2.json" 2>&1
}
window() { # arm q r
	local name="$1-$2-r$3" wpid
	node scripts/perf/dnsload.mjs --port "$GUEST_DNS_PORT" --tag w --qps "$2" --seconds 3 >/dev/null 2>&1
	guest_exec "ucode $G/probe.uc window $secs ab-$name" >"$out/raw/win-$name.json" 2>/dev/null &
	wpid=$!
	node scripts/perf/dnsload.mjs --port "$GUEST_DNS_PORT" --tag "a$3" --qps "$2" --seconds $((secs + 4)) --out "$out/raw/load-$name.json" >/dev/null 2>&1
	wait "$wpid"
	python3 - "$out" "$1" "$2" "$3" <<-'EOF' >>"$out/ab.jsonl"
		import json, sys
		out, arm, q, r = sys.argv[1:]
		name = f'{arm}-{q}-r{r}'
		w = json.load(open(f'{out}/raw/win-{name}.json')); d = json.load(open(f'{out}/raw/load-{name}.json'))
		wall = (w['t1']['wall_ms'] - w['t0']['wall_ms']) / 1000
		sel = lambda s, c: {(p['pid'], p['starttime']): p for p in s['procs'] if p['comm'] == c and '--port=5300' not in p['cmdline']}
		def delta(c, f):
		    a, b = sel(w['t0'], c), sel(w['t1'], c)
		    return sum(f(p) - (f(a[k]) if k in a else 0) for k, p in b.items())
		cpu = lambda c: delta(c, lambda p: p['utime'] + p['stime']) / wall
		allt = lambda s: sum(p['utime'] + p['stime'] + p.get('cutime', 0) + p.get('cstime', 0) for p in s['procs'])
		total = (allt(w['t1']) - allt(w['t0'])) / wall
		measured = sum(cpu(c) for c in ('dnsmasq', 'logd', 'rpcd', 'uhttpd', 'ubusd'))
		valid = measured <= total + 6 * 100 / 100 / wall and total <= w['t1']['cpu']['ncpu'] * 100 + 600 / 100 / wall
		print(json.dumps({'arm': arm, 'q': int(q), 'r': int(r), 'valid': valid, 'dnsmasq_pct': round(cpu('dnsmasq'), 2), 'logd_pct': round(cpu('logd'), 2),
		  'system_total_pct': round(total, 2),
		  'dnsmasq_ctxsw_per_query': round(delta('dnsmasq', lambda p: p['vctx'] + p['nvctx']) / max(1, d['received']), 2),
		  'dnsmasq_pids': [sorted(k[0] for k in sel(w['t0'], 'dnsmasq')), sorted(k[0] for k in sel(w['t1'], 'dnsmasq'))],
		  'p50_ms': d['latency_ms']['p50'], 'p95_ms': d['latency_ms']['p95'], 'lost': d['lost'],
		  'package_procs': len([p for p in w['t1']['procs'] if 'adblock-fast-monitor' in p['cmdline'] and 'probe.uc' not in p['cmdline']])}))
	EOF
}
arms=(off manual product)
for ((r = 1; r <= reps; r++)); do
	for ((k = 0; k < 3; k++)); do
		arm=${arms[$(((k + r - 1) % 3))]}
		log "r$r $arm"
		arm_state "$arm" "$r"
		for q in $rates; do window "$arm" "$q" "$r"; done
	done
done
gl 'perf_manual 0 && perf_set 1' >/dev/null 2>&1
python3 - "$out" <<-'EOF' | tee "$out/summary.txt"
	import json, sys, statistics as st
	rows = [json.loads(l) for l in open(sys.argv[1] + '/ab.jsonl')]
	bad = [r for r in rows if not r['valid']]
	rows = [r for r in rows if r['valid']]
	print(f"{len(rows)} valid windows, {len(bad)} invalid (excluded)")
	med = lambda v: st.median(v) if v else float('nan')
	spr = lambda v: max(v) - min(v) if len(v) > 1 else float('nan')
	for q in sorted({r['q'] for r in rows}):
	    print(f"\n{q} qps   {'dnsmasq % med (spread) [runs]':44} {'logd % med (spread)':20} {'p95 ms':>7} {'p50 ms':>7} {'restarts':>8}")
	    m = {}
	    for a in ('off', 'manual', 'product'):
	        rs = [r for r in rows if r['arm'] == a and r['q'] == q]
	        f = lambda k: [r[k] for r in rs]
	        m[a] = {k: f(k) for k in ('dnsmasq_pct', 'logd_pct', 'p95_ms', 'p50_ms')}
	        restarts = sum(r['dnsmasq_pids'][0] != r['dnsmasq_pids'][1] for r in rs)
	        print(f"  {a:8} {med(f('dnsmasq_pct')):6.2f} ({spr(f('dnsmasq_pct')):4.2f}) {str(f('dnsmasq_pct')):30} {med(f('logd_pct')):6.2f} ({spr(f('logd_pct')):4.2f})"
	              f"       {med(f('p95_ms')):7.2f} {med(f('p50_ms')):7.2f} {restarts:8d}")
	    for k, unit in (('dnsmasq_pct', 'pp'), ('logd_pct', 'pp'), ('p95_ms', 'ms')):
	        noise = max(spr(m['product'][k]), spr(m['manual'][k]))
	        print(f"  {k:12} product-manual {med(m['product'][k]) - med(m['manual'][k]):+6.2f} {unit} (noise {noise:.2f}),"
	              f" manual-off {med(m['manual'][k]) - med(m['off'][k]):+6.2f}, product-off {med(m['product'][k]) - med(m['off'][k]):+6.2f}")
EOF
log "done: $out"
