#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# P0 performance measurement driver (T26, docs/performance.md, CONTRACT §11).
# Runs on the host with a guest already booted, either by
# scripts/guest/run-guest-tests.sh (--no-install --no-tests --host-cmd
# scripts/perf/run.sh PACKAGE.apk; x86/64, KVM or TCG) or by
# scripts/perf/armsr/run-guest.sh (armsr-armv8 under hvf; ABFM_PERF_GUEST=armsr-hvf):
# the APK is at /tmp/abfm-test/package.apk in the guest but not yet
# installed, so the stock system is measured first.
#
# Environment:
#   ABFM_PERF_OUT        output directory (default .local-validation/perf/<UTC>-<rand>)
#   ABFM_PERF_REPEATS    repetitions of the off / on / page load runs (default 3, min 3)
#   ABFM_PERF_LOAD_SECONDS  measured window per load run (default 30)
#   ABFM_PERF_HIDDEN_SECONDS  hidden and closed page windows (default 60, never less)
#   ABFM_PERF_QPS        load rates (default "50 200")
#   ABFM_PERF_PAGE       LuCI page polled by the browser (default the overview)
#   ABFM_PERF_SKIP_BOOT=1     skip the two power cycles (P10 boot, P1 after boot)
#   ABFM_PERF_SKIP_BROWSER=1  skip the Playwright phases (P2, P3 page, P4)
#   ABFM_PERF_SETTLE_AGE  seconds from the dnsmasq restart that starts every
#                        alternation state to its first window (default 20)
#   ABFM_PERF_GUEST      x86 (default) or armsr-hvf: which guest library the
#                        power cycles use (set by the entrypoints)
# Raw JSON lands in $ABFM_PERF_OUT/raw; run.json indexes it. Every phase
# records its own errors and the run continues. The verdict comes from
# scripts/performance-gate.mjs.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root" || exit 1
out="${ABFM_PERF_OUT:-$root/.local-validation/perf/$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM}"
raw="$out/raw"
ctl="$out/ctl"
mkdir -p "$raw" "$ctl"
repeats="${ABFM_PERF_REPEATS:-3}"
((repeats >= 3)) || repeats=3
load_s="${ABFM_PERF_LOAD_SECONDS:-30}"
hidden_s="${ABFM_PERF_HIDDEN_SECONDS:-60}"
((hidden_s >= 60)) || hidden_s=60
rates="${ABFM_PERF_QPS:-50 200}"
settle_age="${ABFM_PERF_SETTLE_AGE:-20}"
guest_lib=scripts/guest/lib.sh
[[ "${ABFM_PERF_GUEST:-x86}" == armsr-hvf ]] && guest_lib=scripts/perf/armsr/lib.sh
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
# set_logging NAME 0|1 : query logging through uci commit + reload_config
set_logging() {
	gsh ". $G/lib.sh; perf_set $2" >"$raw/$1.json" 2>"$raw/$1.err" || err "query logging $2 ($1) failed"
	[[ -s "$raw/$1.err" ]] || rm -f "$raw/$1.err"
}
# load_window STATE Q R : a guest window inside a host load run
load_window() {
	local state="$1" q="$2" r="$3" wpid f
	dnsload "warm-$state-$q-$r" "$q" 3 '' >/dev/null 2>&1 || true
	guest_exec "$P window $load_s load-$state-$q-r$r" >"$raw/win-$state-$q-r$r.json" 2>"$raw/win-$state-$q-r$r.err" &
	wpid=$!
	dnsload "l-$state-$q-$r" "$q" $((load_s + 4)) "$raw/load-$state-$q-r$r.json" >/dev/null 2>"$raw/load-$state-$q-r$r.err" ||
		err "load $state $q r$r failed: $(head -c 300 "$raw/load-$state-$q-r$r.err")"
	wait "$wpid" || err "window $state $q r$r failed"
	for f in "$raw/win-$state-$q-r$r.err" "$raw/load-$state-$q-r$r.err"; do [[ -s "$f" ]] || rm -f "$f"; done
}

browser_ok=0
if [[ "${ABFM_PERF_SKIP_BROWSER:-0}" != 1 ]]; then
	# Before any measurement, so npm/apt work never lands in a window.
	log 'browser: preparing Playwright (Chromium)'
	browser_ok=1
	if [[ ! -x node_modules/.bin/playwright ]]; then
		npm ci --no-audit --no-fund >"$raw/npm-ci.log" 2>&1 || { browser_ok=0; err 'npm ci failed (browser phases skipped)'; }
	fi
	if ((browser_ok)); then
		npx playwright install --with-deps chromium >"$raw/playwright-install.log" 2>&1 ||
			{ browser_ok=0; err 'playwright install failed (browser phases skipped)'; }
	fi
fi
# browser_hold NAME : starts a visible page; returns once it polls (or fails)
bpid=''
browser_hold() {
	local i
	rm -f "$ctl/$1.ready" "$ctl/$1.stop"
	node scripts/perf/browser.mjs hold --out "$raw/browser-$1.json" --ready "$ctl/$1.ready" --stop "$ctl/$1.stop" \
		>"$raw/browser-$1.log" 2>&1 &
	bpid=$!
	for ((i = 0; i < 400; i++)); do
		[[ -e "$ctl/$1.ready" ]] && break
		kill -0 "$bpid" 2>/dev/null || break
		sleep 1
	done
	[[ -e "$ctl/$1.ready" && "$(cat "$ctl/$1.ready")" != failed ]] ||
		{ err "browser $1 never became ready: $(tail -c 300 "$raw/browser-$1.log")"; return 1; }
}
browser_release() { # NAME
	touch "$ctl/$1.stop"
	wait "$bpid" || err "browser $1 exited non-zero: $(tail -c 300 "$raw/browser-$1.log")"
}

log "output $out (accel ${GUEST_ACCEL_USED:-?}, repeats $repeats, load ${load_s}s, hidden ${hidden_s}s, rates $rates, browser $browser_ok)"
push_tools || { err 'cannot copy the probe into the guest'; exit 1; }

# --- meta -----------------------------------------------------------------
gsh "cat /etc/openwrt_release; uname -a; grep -c ^processor /proc/cpuinfo; free; apk info -v 2>/dev/null | grep -E '^(adblock-fast|dnsmasq|ucode|rpcd|logd|ubox|procd|uhttpd|luci-base)-[0-9]'; echo log_size=\$(uci -q get system.@system[0].log_size)" \
	>"$raw/meta-guest.txt" 2>&1
cat >"$raw/meta-host.json" <<-EOF
	{"started_at":"$started_at","accel":"${GUEST_ACCEL_USED:-unknown}","guest_boot_seconds":${GUEST_BOOT_SECONDS:-null},
	 "host_uname":"$(uname -srm)","guest_cpus":${GUEST_CPUS:-2},"guest_memory_mib":${GUEST_MEMORY:-256},
	 "package_sha256":"${PACKAGE_SHA256:-}","package_file":"$(basename "${PACKAGE_APK:-unknown}")",
	 "repeats":$repeats,"load_seconds":$load_s,"hidden_seconds":$hidden_s,"rates":[${rates// /,}],
	 "guest":"${ABFM_PERF_GUEST:-x86}","guest_target":"${GUEST_TARGET:-x86-64}","settle_age_s":$settle_age,
	 "browser":$( ((browser_ok)) && echo true || echo false),"page":"${ABFM_PERF_PAGE:-/cgi-bin/luci/admin/services/adblock-fast-monitor/overview}",
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

# --- P1: stock, then installed with query logging off and on ---------------
log 'P1: stock snapshots'
for i in 1 2 3; do probe "p1-stock-$i" snapshot; sleep 5; done
log 'P1: installing the package'
gsh ". $G/lib.sh; perf_install /tmp/abfm-test/package.apk" >"$raw/install.json" 2>"$raw/install.log" ||
	err "package installation failed: $(tail -c 300 "$raw/install.log")"
push_tools
gsh 'uci show adblock-fast-monitor; /etc/init.d/adblock-fast-monitor enabled && echo init-enabled || echo init-disabled' \
	>"$raw/p1-config.txt" 2>&1
set_logging p1-ensure-off 0
probe p1-installed-off-watch watch 15
for i in 1 2 3; do probe "p1-installed-off-$i" snapshot; sleep 5; done
set_logging toggle-on-r0 1
gsh ". $G/lib.sh; perf_capture_dropin" >"$raw/dropin-captured.json" 2>&1 || err 'cannot capture the package drop-in'
probe p1-installed-on-watch watch 15
for i in 1 2 3; do probe "p1-installed-on-$i" snapshot; sleep 5; done
gsh ". $G/lib.sh; perf_state" >"$raw/p1-state.json" 2>&1

# --- calibration: ubus round-trip floor -------------------------------------
probe calib-rpc-system-board rpc system board '{}' 20
probe calib-rpc-session-list rpc session list '{}' 20

# --- alternation: off / manual / on (no page) / on + one visible page -------
# P5/P6 compare on with off and with manual (query logging off, the package's
# drop-in written by hand: dnsmasq's own logging without the package); P3
# compares page with on under the same load. Every state starts with a
# dnsmasq restart and waits until dnsmasq is the same age (settle_age) before
# its first window, and the order rotates every repeat, so neither restart
# age nor host drift favours a state.
logging_now=1
# set_state STATE R : query logging and the manual drop-in for STATE, then
# the equal-age restart.
set_state() {
	local want=0 manual=0
	[[ $1 == on || $1 == page ]] && want=1
	[[ $1 == manual ]] && manual=1
	# The hand-written copy goes before any switch: with both drop-ins in a
	# confdir dnsmasq refuses the repeated options and does not start.
	gsh ". $G/lib.sh; perf_manual 0" || err "state $1 r$2: cannot remove the manual drop-in"
	if [[ "$logging_now" != "$want" ]]; then
		set_logging "toggle-$([[ $want == 1 ]] && echo on || echo off)-r$2" "$want"
		logging_now=$want
	fi
	gsh ". $G/lib.sh; perf_manual $manual && perf_restart $settle_age" >"$raw/restart-$1-r$2.json" 2>"$raw/restart-$1-r$2.err" ||
		err "state $1 r$2: restart failed: $(head -c 300 "$raw/restart-$1-r$2.err")"
	[[ -s "$raw/restart-$1-r$2.err" ]] || rm -f "$raw/restart-$1-r$2.err"
}
logbench() { # r : log read latency under load (query logging on)
	local q wpid
	for q in $rates; do
		dnsload "warm-lr-$q-$1" "$q" 3 '' >/dev/null 2>&1 || true
		guest_exec "$P logbench 20 250" >"$raw/logbench-$q-r$1.json" 2>"$raw/logbench-$q-r$1.err" &
		wpid=$!
		dnsload "lr-$q-$1" "$q" 16 '' >/dev/null 2>&1 || err "log read load $q r$1 failed"
		wait "$wpid" || err "logbench $q r$1 failed"
		[[ -s "$raw/logbench-$q-r$1.err" ]] || rm -f "$raw/logbench-$q-r$1.err"
	done
}
states=(off manual on)
((browser_ok)) && states+=(page)
for ((r = 1; r <= repeats; r++)); do
	n=${#states[@]}
	for ((k = 0; k < n; k++)); do
		state=${states[$(((k + r - 1) % n))]}
		log "repeat $r: state $state"
		set_state "$state" "$r"
		if [[ $state == page ]]; then
			if browser_hold "page-r$r"; then
				for q in $rates; do load_window page "$q" "$r"; done
			fi
			browser_release "page-r$r"
		else
			for q in $rates; do load_window "$state" "$q" "$r"; done
			[[ $state == on ]] && logbench "$r"
		fi
	done
done
# The page phases and P7/P8 run with query logging on and no manual drop-in.
set_state on $((repeats + 1))

# --- P2: hidden and closed page --------------------------------------------
if ((browser_ok)); then
	log "P2: hidden page ${hidden_s}s, closed page ${hidden_s}s"
	node scripts/perf/browser.mjs p2 --out "$raw/browser-p2.json" --hidden-s "$hidden_s" --closed-s "$hidden_s" \
		>"$raw/browser-p2.log" 2>&1 || err "browser p2 failed: $(tail -c 300 "$raw/browser-p2.log")"
fi

# --- P10 settings save, P7 info, P8 apply ----------------------------------
log 'P10: a settings save that leaves query logging alone'
gsh ". $G/lib.sh; perf_save perf_save_probe 1" >"$raw/p10-save.json" 2>"$raw/p10-save.err" || err 'settings save failed'
[[ -s "$raw/p10-save.err" ]] || rm -f "$raw/p10-save.err"
gsh ". $G/lib.sh; perf_unsave perf_save_probe" >"$raw/p10-unsave.json" 2>&1 || err 'settings unsave failed'
log 'P7/P8: info, apply'
probe rpc-info rpc luci.adblock-fast-monitor info '{}' 20
guest_exec "$P rpcprobe 12 20" >"$raw/p8-rpcd-probe.json" 2>"$raw/p8-rpcd-probe.err" &
ppid=$!
sleep 2
probe p8-apply-dry rpc luci.adblock-fast-monitor apply '{"ops":[{"op":"allow","domain":"perf-apply-1.example.com"}],"dry_run":true}' 10
probe p8-apply rpc luci.adblock-fast-monitor apply '{"ops":[{"op":"allow","domain":"perf-apply-1.example.com"}]}' 1
wait "$ppid" || err 'rpcd probe failed'
[[ -s "$raw/p8-rpcd-probe.err" ]] || rm -f "$raw/p8-rpcd-probe.err"
gsh ". $G/lib.sh; perf_wait_job 120" >"$raw/p8-job.json" 2>&1 || true

# --- P10 boot with query logging on and off; P1 after each boot -------------
# Each boot is a power cycle: poweroff, then a fresh QEMU on the same overlay.
# (A second warm `reboot` of one TCG QEMU process can stall for >10 min after
# GRUB on arm64 hosts; cold starts are what every guest run already does.)
cold_boot() { # n
	guest_exec 'sync; poweroff' >/dev/null 2>&1 || true
	local i
	for ((i = 0; i < 180; i++)); do kill -0 "$GUEST_QEMU_PID" 2>/dev/null || break; sleep 1; done
	kill "$GUEST_QEMU_PID" 2>/dev/null || true
	((own_guest)) && kill "$GUEST_PROXY_PID" 2>/dev/null || true
	cp "$GUEST_RUN_DIR/serial.log" "$raw/serial-before-boot-$1.log" 2>/dev/null || true
	rm -f "$GUEST_RUN_DIR/serial.sock"
	GUEST_DISK="$GUEST_RUN_DIR/disk.qcow2" guest_start >"$raw/boot-$1.log" 2>&1 && own_guest=1
}
own_guest=0
if [[ "${ABFM_PERF_SKIP_BOOT:-0}" != 1 ]]; then
	# shellcheck source=scripts/guest/lib.sh
	source "$root/$guest_lib"
	n=0
	for state in on off; do
		value=$([[ $state == on ]] && echo 1 || echo 0)
		n=$((n + 1))
		log "P10: boot with query logging $state"
		push_tools
		set_logging "p10-preboot-$state" "$value"
		# Boot window (transient init invocations, §11 P1): a 60 s watch at
		# 100 ms started during boot by a one-shot /etc/rc.d/S11 script
		# (before dnsmasq, S19), because with hvf the trigger has fired long
		# before the first SSH login. Removed again after the boot.
		gsh "cp $G/probe.uc /root/abfm-perf-probe.uc && rm -f /root/abfm-boot-watch.json &&
			printf '#!/bin/sh\nucode /root/abfm-perf-probe.uc watch 60 100 >/root/abfm-boot-watch.json 2>/dev/null </dev/null &\n' >/etc/rc.d/S11abfm-perf-watch &&
			chmod 755 /etc/rc.d/S11abfm-perf-watch" || err "cannot arm the boot watch ($state)"
		if cold_boot "$n"; then
			push_tools
			# shellcheck disable=SC2016 # expanded by the guest shell
			gsh 'i=0; until [ -s /root/abfm-boot-watch.json ]; do i=$((i + 1)); [ $i -lt 120 ] || exit 1; sleep 1; done
				cat /root/abfm-boot-watch.json; rm -f /root/abfm-boot-watch.json /root/abfm-perf-probe.uc /etc/rc.d/S11abfm-perf-watch' >"$raw/p1-after-boot-$state-watch.json" 2>"$raw/p1-after-boot-$state-watch.err" ||
				err "boot watch ($state) missing"
			[[ -s "$raw/p1-after-boot-$state-watch.err" ]] || rm -f "$raw/p1-after-boot-$state-watch.err"
			# Then 60 s idle once boot has settled.
			gsh ". $G/lib.sh; perf_boot_report" >"$raw/p10-boot-$state.json" 2>&1 || err "boot report $state failed"
			for i in 1 2 3; do probe "p1-after-boot-$state-$i" snapshot; sleep 5; done
			probe "p1-idle-after-boot-$state-watch" watch 60 100
		else
			err "boot ($state) failed: $(tail -c 300 "$raw/boot-$n.log")"
			break
		fi
	done
	((own_guest)) && guest_stop
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
