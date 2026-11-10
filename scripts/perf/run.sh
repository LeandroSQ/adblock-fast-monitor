#!/usr/bin/env bash
# P0 performance measurement driver (T26, docs/performance.md). Runs on the
# host with a guest already booted by scripts/guest/run-guest-tests.sh
# (--no-install --no-tests --host-cmd scripts/perf/run.sh PACKAGE.apk): the
# APK is at /tmp/abfm-test/package.apk in the guest but not yet installed, so
# the stock system can be measured first.
#
# Environment:
#   ABFM_PERF_OUT        output directory (default .local-validation/perf/<UTC>-<rand>)
#   ABFM_PERF_REPEATS    off/on repetitions of the load runs (default 3)
#   ABFM_PERF_LOAD_SECONDS  measured window per load run (default 30)
#   ABFM_PERF_IDLE_SECONDS  idle window (default 60, never less)
#   ABFM_PERF_QPS        load rates (default "50 200")
#   ABFM_PERF_SKIP_BOOT=1   skip the two reboots of P10
# Raw JSON lands in $ABFM_PERF_OUT/raw; run.json indexes it. Every phase
# records its own errors and the run continues, so a broken daemon still
# yields every off-baseline number. The verdict comes from
# scripts/performance-gate.mjs.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
out="${ABFM_PERF_OUT:-$root/.local-validation/perf/$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM}"
raw="$out/raw"
mkdir -p "$raw"
repeats="${ABFM_PERF_REPEATS:-3}"
load_s="${ABFM_PERF_LOAD_SECONDS:-30}"
idle_s="${ABFM_PERF_IDLE_SECONDS:-60}"
((idle_s >= 60)) || idle_s=60
rates="${ABFM_PERF_QPS:-50 200}"
G=/tmp/abfm-perf
P="ucode $G/probe.uc"
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
errors=()

log() { printf 'perf: %s\n' "$*" >&2; }
err() { log "ERROR: $*"; errors+=("$*"); }
# probe NAME ARGS... : runs the guest probe and stores raw/NAME.json
probe() {
	local name="$1" cmd="$P" arg; shift
	for arg; do cmd+=" $(guest__sq "$arg")"; done
	guest_exec "$cmd" >"$raw/$name.json" 2>"$raw/$name.err" || err "probe $name failed: $(head -c 300 "$raw/$name.err")"
	[[ -s "$raw/$name.err" ]] || rm -f "$raw/$name.err"
}
gsh() { guest_exec "$@"; }
push_tools() {
	guest_exec "mkdir -p $G" && guest_copy scripts/perf/guest/probe.uc "$G/probe.uc" &&
		guest_copy scripts/perf/guest/lib.sh "$G/lib.sh"
}
dnsload() { # tag qps seconds outfile [mix]
	node scripts/perf/dnsload.mjs --port "$GUEST_DNS_PORT" --tag "$1" --qps "$2" --seconds "$3" \
		${5:+--mix "$5"} ${4:+--out "$4"}
}

log "output $out (accel ${GUEST_ACCEL_USED:-?}, repeats $repeats, load ${load_s}s, idle ${idle_s}s, rates $rates)"
push_tools || { err 'cannot copy the probe into the guest'; exit 1; }

# --- meta -----------------------------------------------------------------
gsh "cat /etc/openwrt_release; uname -a; grep -c ^processor /proc/cpuinfo; free; apk info -v 2>/dev/null | grep -E '^(adblock-fast|dnsmasq|ucode|rpcd|logd|ubox|procd|luci-base)-[0-9]'" \
	>"$raw/meta-guest.txt" 2>&1
cat >"$raw/meta-host.json" <<-EOF
	{"started_at":"$started_at","accel":"${GUEST_ACCEL_USED:-unknown}","guest_boot_seconds":${GUEST_BOOT_SECONDS:-null},
	 "host_uname":"$(uname -srm)","guest_cpus":${GUEST_CPUS:-2},"guest_memory_mib":${GUEST_MEMORY:-256},
	 "package_sha256":"${PACKAGE_SHA256:-}","package_file":"$(basename "${PACKAGE_APK:-unknown}")",
	 "repeats":$repeats,"load_seconds":$load_s,"idle_seconds":$idle_s,"rates":[${rates// /,}],
	 "guest_run_dir":"${GUEST_RUN_DIR:-}"}
EOF

# --- fixtures: local responder, no WAN, quiet log --------------------------
log 'preparing fixtures (local responder, perf drop-in, ntpd stopped)'
gsh ". $G/lib.sh; perf_prepare" >"$raw/prepare.json" 2>"$raw/prepare.err" || err "fixture preparation failed: $(tail -c 300 "$raw/prepare.err")"
sanity_ok=1
for name in u-sanity-1.perf.test c0.perf.test b-sanity-1.perf-block.test; do
	answer="$(dig +time=3 +tries=2 +short @127.0.0.1 -p "$GUEST_DNS_PORT" "$name" A 2>&1 || true)"
	printf '%s %s\n' "$name" "${answer:-<empty>}" >>"$raw/sanity.txt"
done
grep -q '^u-sanity-1.perf.test 192.0.2.1$' "$raw/sanity.txt" || sanity_ok=0
grep -q '^b-sanity-1.perf-block.test <empty>$' "$raw/sanity.txt" || sanity_ok=0
((sanity_ok)) || err "DNS fixtures do not answer as expected: $(tr '\n' ';' <"$raw/sanity.txt")"

# --- P1: stock vs installed with enabled=0 ---------------------------------
log 'P1: stock snapshots'
for i in 1 2 3; do probe "p1-stock-$i" snapshot; sleep 5; done
log 'P1: installing the package (enabled=0)'
gsh ". $G/lib.sh; perf_install /tmp/abfm-test/package.apk" >"$raw/install.json" 2>"$raw/install.log" ||
	err "package installation failed: $(tail -c 300 "$raw/install.log")"
push_tools
gsh 'uci show adblock-fast-monitor; /etc/init.d/adblock-fast-monitor enabled && echo init-enabled || echo init-disabled' \
	>"$raw/p1-config.txt" 2>&1
gsh ". $G/lib.sh; perf_set 0" >"$raw/p1-ensure-off.json" 2>>"$raw/p1-config.txt" || err 'cannot ensure enabled=0'
sleep 10
for i in 1 2 3; do probe "p1-installed-$i" snapshot; sleep 5; done
gsh ". $G/lib.sh; perf_state" >"$raw/p1-state.json" 2>&1

# --- calibration ------------------------------------------------------------
log 'calibration: regex cost, reference footprint, ubus floor'
for i in 1 2 3; do probe "calib-parsebench-$i" parsebench 20000; done
probe calib-memref-0 memref 0 0 0
probe calib-memref-default memref 500 256 512
probe calib-memref-cap memref 2000 256 512
probe calib-memref-max memref 2000 1024 4096
probe calib-rpc-system-board rpc system board '{}' 20
probe calib-rpc-session-list rpc session list '{}' 20

# --- off/on alternation: idle windows (P3), load runs (P4, P5, P6) ---------
for ((r = 1; r <= repeats; r++)); do
	for state in off on; do
		value=$([[ $state == on ]] && echo 1 || echo 0)
		log "repeat $r: monitor $state"
		gsh ". $G/lib.sh; perf_set $value" >"$raw/toggle-$state-r$r.json" 2>"$raw/toggle-$state-r$r.err" ||
			err "toggle $state r$r failed"
		[[ -s "$raw/toggle-$state-r$r.err" ]] || rm -f "$raw/toggle-$state-r$r.err"
		if ((r == 1)); then
			log "idle window ${idle_s}s ($state)"
			probe "idle-$state" window "$idle_s" "idle-$state"
			[[ $state == on ]] && probe p2-idle snapshot
		fi
		for q in $rates; do
			dnsload "warm-$state-$q-$r" "$q" 3 '' >/dev/null 2>&1 || true
			guest_exec "$P window $load_s load-$state-$q-r$r" >"$raw/win-$state-$q-r$r.json" 2>"$raw/win-$state-$q-r$r.err" &
			wpid=$!
			dnsload "l-$state-$q-$r" "$q" $((load_s + 4)) "$raw/load-$state-$q-r$r.json" >/dev/null 2>"$raw/load-$state-$q-r$r.err" ||
				err "load $state $q r$r failed: $(head -c 300 "$raw/load-$state-$q-r$r.err")"
			wait "$wpid" || err "window $state $q r$r failed"
			for f in "$raw/win-$state-$q-r$r.err" "$raw/load-$state-$q-r$r.err"; do [[ -s "$f" ]] || rm -f "$f"; done
		done
	done
done

# --- P10 settings save, P2 at the recent_size=2000 cap, P7 handler times ---
log 'P10: settings save (recent_size=2000)'
gsh ". $G/lib.sh; perf_save recent_size 2000" >"$raw/p10-save.json" 2>"$raw/p10-save.err" || err 'settings save failed'
[[ -s "$raw/p10-save.err" ]] || rm -f "$raw/p10-save.err"
log 'P2: filling the tables (3000 distinct names)'
dnsload fill 200 15 "$raw/fill.json" unique:60,blocked:40 >/dev/null 2>&1 || err 'fill load failed'
sleep 15 # pending entries expire (pending_ttl 10 s), tables settle
probe p2-full snapshot
probe rpc-status rpc adblock-fast-monitor status '{}' 20
probe rpc-domains-recent rpc adblock-fast-monitor domains '{"view":"recent","limit":100}' 20
probe rpc-domains-recent-q rpc adblock-fast-monitor domains '{"view":"recent","q":"perf","offset":1000,"limit":100}' 20
probe rpc-domains-top-blocked rpc adblock-fast-monitor domains '{"view":"top_blocked","limit":100}' 20
probe rpc-domains-top-allowed rpc adblock-fast-monitor domains '{"view":"top_allowed","limit":100}' 20
probe rpc-info rpc luci.adblock-fast-monitor info '{}' 10

# --- P8 apply, P9 rules on a 100k-line output file -------------------------
log 'P8/P9: rules on a 100k-line output file, apply'
gsh ". $G/lib.sh; perf_rules_fixture setup" >"$raw/p9-fixture.json" 2>&1 || err 'rules fixture setup failed'
domains="$(python3 -c 'import json; print(json.dumps({"domains": ["perf-list-%06d.example" % (i * 2003) for i in range(48)] + ["u-x.perf.test", "not-listed.example"]}))')"
guest_exec "$P rpcprobe 12 20" >"$raw/p9-rpcd-probe.json" 2>"$raw/p9-rpcd-probe.err" &
ppid=$!
sleep 2
probe p9-rules rpc luci.adblock-fast-monitor rules "$domains" 3
probe p8-apply-dry rpc luci.adblock-fast-monitor apply '{"ops":[{"op":"allow","domain":"perf-apply-1.example.com"}],"dry_run":true}' 10
probe p8-apply rpc luci.adblock-fast-monitor apply '{"ops":[{"op":"allow","domain":"perf-apply-1.example.com"}]}' 1
wait "$ppid" || err 'rpcd probe failed'
[[ -s "$raw/p9-rpcd-probe.err" ]] || rm -f "$raw/p9-rpcd-probe.err"
gsh ". $G/lib.sh; perf_wait_job 60" >"$raw/p8-job.json" 2>&1 || true
gsh ". $G/lib.sh; perf_rules_fixture teardown" >"$raw/p9-fixture-teardown.json" 2>&1 || err 'rules fixture teardown failed'

# --- P10 boot with the monitor on and off; P1 after a disabled boot ---------
if [[ "${ABFM_PERF_SKIP_BOOT:-0}" != 1 ]]; then
	# shellcheck source=scripts/guest/lib.sh
	source "$root/scripts/guest/lib.sh"
	for state in on off; do
		value=$([[ $state == on ]] && echo 1 || echo 0)
		log "P10: boot with the monitor $state"
		push_tools
		gsh ". $G/lib.sh; perf_set $value" >"$raw/p10-preboot-$state.json" 2>&1 || err "pre-boot toggle $state failed"
		if guest_reboot; then
			push_tools
			gsh ". $G/lib.sh; sleep 10; perf_boot_report" >"$raw/p10-boot-$state.json" 2>&1 || err "boot report $state failed"
			if [[ $state == off ]]; then
				for i in 1 2 3; do probe "p1-after-boot-$i" snapshot; sleep 5; done
			fi
		else
			err "reboot ($state) failed"
		fi
	done
fi

finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
python3 - "$out" "$started_at" "$finished_at" "${errors[@]+"${errors[@]}"}" <<-'EOF'
	import json, os, sys
	out, started, finished, errors = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
	files = sorted(os.listdir(os.path.join(out, 'raw')))
	json.dump({'harness': 'scripts/perf/run.sh', 'started_at': started, 'finished_at': finished,
	           'errors': errors, 'raw_files': files}, open(os.path.join(out, 'run.json'), 'w'), indent=1)
EOF
log "done: $out (${#errors[@]} harness error(s))"
