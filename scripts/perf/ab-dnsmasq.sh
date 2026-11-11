#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# P6 diagnosis (docs/performance.md → "P6 dnsmasq cost"): A/B of dnsmasq CPU
# with query logging on one guest, so host noise is shared by every arm.
# Host command for scripts/guest/run-guest-tests.sh:
#
#   ABFM_AB_OLD_APK=.local-validation/artifacts/<A>/package.apk \
#   scripts/verify-guest.sh --no-install --no-tests --host-cmd scripts/perf/ab-dnsmasq.sh NEW.apk
#
# NEW.apk stays installed. Arms, interleaved in every repeat (ABFM_AB_REPEATS,
# default 5; 50 qps unless ABFM_AB_QPS):
#   off                query_logging=0, no drop-in
#   manual             query_logging=0 + a hand-written drop-in with the
#                      product's content (log-queries=extra, log-async=25): no trigger
#   manual-sub         manual + one `logread -f -e ^dnsmasq\[` subscriber (what
#                      design A's daemon ran)
#   product            query_logging=1: the package's drop-in and its procd
#                      instance.update trigger
#   product-notrigger  query_logging=1 with the trigger line removed from the init script
#   old-off / old-on   then ABFM_AB_OLD_APK (design A) with enabled 0 / 1
# Each window records dnsmasq and logd CPU (task times), context switches,
# dnsmasq pids before/after (restarts), the /proc/stat totals and the DNS
# latency. Output: $ABFM_AB_OUT/ab.jsonl (one line per window) + summary.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
out="${ABFM_AB_OUT:-$root/.local-validation/perf/ab-$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM}"
mkdir -p "$out/raw"
reps="${ABFM_AB_REPEATS:-5}"
secs="${ABFM_AB_SECONDS:-20}"
qps="${ABFM_AB_QPS:-50}"
G=/tmp/abfm-perf
log() { printf 'ab: %s\n' "$*" >&2; }

guest_exec "mkdir -p $G" && guest_copy scripts/perf/guest/probe.uc "$G/probe.uc" && guest_copy scripts/perf/guest/lib.sh "$G/lib.sh" || exit 1
[[ -n "${ABFM_AB_OLD_APK:-}" ]] && guest_copy "$ABFM_AB_OLD_APK" /tmp/abfm-test/old.apk
guest_exec ". $G/lib.sh; perf_prepare" >"$out/prepare.json" 2>&1 || { log 'fixtures failed'; exit 1; }

# dropin CONTENT|'' : the arm's manual drop-in, dnsmasq restarted once
dropin() {
	guest_exec "for d in /tmp/dnsmasq*.d; do rm -f \$d/abfm-ab.conf; [ -z '$1' ] || printf '$1' >\$d/abfm-ab.conf; done
		/etc/init.d/dnsmasq restart; sleep 3; pidof dnsmasq >/dev/null"
}
subscriber() { # on|off
	if [[ $1 == on ]]; then guest_exec 'setsid logread -f -e "^dnsmasq\[" </dev/null >/dev/null 2>&1 &'
	else guest_exec 'for p in $(pidof logread); do kill $p; done; :'; fi
}
window() { # arm r
	local name="$1-r$2" wpid
	node scripts/perf/dnsload.mjs --port "$GUEST_DNS_PORT" --tag w --qps "$qps" --seconds 3 >/dev/null 2>&1
	guest_exec "ucode $G/probe.uc window $secs ab-$name" >"$out/raw/win-$name.json" 2>/dev/null &
	wpid=$!
	node scripts/perf/dnsload.mjs --port "$GUEST_DNS_PORT" --tag "a$2" --qps "$qps" --seconds $((secs + 4)) --out "$out/raw/load-$name.json" >/dev/null 2>&1
	wait "$wpid"
	guest_exec "for p in \$(pidof dnsmasq); do echo \$p \$(ls -Li /proc/\$p/root/dev/log 2>/dev/null | cut -d' ' -f1); done; echo dev \$(ls -Li /dev/log | cut -d' ' -f1); ps w | grep -c '[a]dblock-fast-monitor'" >"$out/raw/state-$name.txt" 2>&1
	python3 - "$out" "$1" "$2" <<-'EOF' >>"$out/ab.jsonl"
		import json, sys
		out, arm, r = sys.argv[1:]
		w = json.load(open(f'{out}/raw/win-{arm}-r{r}.json')); d = json.load(open(f'{out}/raw/load-{arm}-r{r}.json'))
		wall = (w['t1']['wall_ms'] - w['t0']['wall_ms']) / 1000
		sel = lambda s, c: {(p['pid'], p['starttime']): p for p in s['procs'] if p['comm'] == c and '--port=5300' not in p['cmdline']}
		def delta(c, f):
		    a, b = sel(w['t0'], c), sel(w['t1'], c)
		    return sum(f(p) - (f(a[k]) if k in a else 0) for k, p in b.items())
		cpu = lambda c: round(delta(c, lambda p: p['utime'] + p['stime']) / wall, 2)
		c0, c1 = w['t0']['cpu'], w['t1']['cpu']
		busy = sum(c1[k] - c0[k] for k in c0 if k not in ('idle', 'iowait')) / wall
		print(json.dumps({'arm': arm, 'r': int(r), 'dnsmasq_pct': cpu('dnsmasq'), 'logd_pct': cpu('logd'), 'logread_pct': cpu('logread'),
		  'dnsmasq_ctxsw_per_query': round(delta('dnsmasq', lambda p: p['vctx'] + p['nvctx']) / max(1, d['received']), 2),
		  'logd_ctxsw_per_query': round(delta('logd', lambda p: p['vctx'] + p['nvctx']) / max(1, d['received']), 2),
		  'dnsmasq_pids': [sorted(k[0] for k in sel(w['t0'], 'dnsmasq')), sorted(k[0] for k in sel(w['t1'], 'dnsmasq'))],
		  'system_busy_pct': round(busy, 1), 'p50_ms': d['latency_ms']['p50'], 'p95_ms': d['latency_ms']['p95'], 'lost': d['lost'],
		  'state': open(f'{out}/raw/state-{arm}-r{r}.txt').read().split()}))
	EOF
}
arm() { # name setup...
	local name="$1" r="$2"; shift 2
	log "$name r$r"
	"$@" >/dev/null 2>&1
	window "$name" "$r"
}
setflag() { guest_exec "uci set adblock-fast-monitor.config.$1=$2; uci commit adblock-fast-monitor; reload_config; sleep 8"; }

guest_exec 'apk add --allow-untrusted /tmp/abfm-test/package.apk && cp /etc/init.d/adblock-fast-monitor /tmp/abfm-init.trigger &&
	sed "/procd_add_raw_trigger/d" /tmp/abfm-init.trigger >/tmp/abfm-init.notrigger' >"$out/install-new.log" 2>&1
# init VARIANT : the package's init script with or without its instance.update trigger
init() { guest_exec "cp /tmp/abfm-init.$1 /etc/init.d/adblock-fast-monitor; /etc/init.d/adblock-fast-monitor reload; sleep 5"; }
for ((r = 1; r <= reps; r++)); do
	arm off "$r" eval 'init trigger; setflag query_logging 0; dropin ""'
	arm manual "$r" dropin 'log-queries=extra\nlog-async=25\n'
	arm manual-sub "$r" eval 'subscriber on'
	subscriber off >/dev/null 2>&1
	arm product "$r" eval 'dropin ""; setflag query_logging 1'
	arm product-notrigger "$r" init notrigger
done
init trigger >/dev/null 2>&1
if [[ -n "${ABFM_AB_OLD_APK:-}" ]]; then
	guest_exec 'apk del luci-app-adblock-fast-monitor; apk add --allow-untrusted /tmp/abfm-test/old.apk' >"$out/install-old.log" 2>&1
	for ((r = 1; r <= reps; r++)); do
		arm old-off "$r" setflag enabled 0
		arm old-on "$r" setflag enabled 1
	done
fi
python3 - "$out" <<-'EOF' | tee "$out/summary.txt"
	import json, sys, statistics as st
	rows = [json.loads(l) for l in open(sys.argv[1] + '/ab.jsonl')]
	arms = list(dict.fromkeys(r['arm'] for r in rows))
	print(f"{'arm':14} {'dnsmasq %':>22} {'logd %':>18} {'ctxsw/q':>8} {'p50 ms':>8} {'restarts':>8}")
	for a in arms:
	    rs = [r for r in rows if r['arm'] == a]
	    f = lambda k: [r[k] for r in rs]
	    restarts = sum(r['dnsmasq_pids'][0] != r['dnsmasq_pids'][1] for r in rs)
	    print(f"{a:14} {st.median(f('dnsmasq_pct')):6.2f} {str(f('dnsmasq_pct')):>15} {st.median(f('logd_pct')):6.2f} {str(f('logd_pct')):>11}"
	          f" {st.median(f('dnsmasq_ctxsw_per_query')):8.2f} {st.median(f('p50_ms')):8.2f} {restarts:8d}")
EOF
log "done: $out"
