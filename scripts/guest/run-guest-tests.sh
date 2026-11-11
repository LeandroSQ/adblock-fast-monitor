#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Guest test entrypoint: boots a fresh COW overlay of the OpenWrt 25.12.6
# baseline, installs an APK, runs test/guest/*.sh inside the guest and
# test/guest/*.host.sh on the host, then discards the guest.
#
#   scripts/guest/run-guest-tests.sh [options] PACKAGE.apk [TEST...]
#
# Options:
#   --no-install       copy the APK to the guest but do not install it
#   --isolate          a fresh guest for every test file (default: one guest)
#   --host-cmd CMD     run CMD on the host after the tests, with the guest
#                      still up and GUEST_* exported (e.g. Playwright)
#   --no-tests         run no guest tests (e.g. only --host-cmd)
#   --keep             keep the guest running until Enter is pressed (debug)
#
# Inside the guest each test runs as `sh FILE` from /tmp/abfm-test with:
#   ABFM_TESTLIB=/tmp/abfm-test/lib (test/lib copied; `. "$ABFM_TESTLIB/sh/testlib.sh"`)
#   ABFM_APK=/tmp/abfm-test/package.apk  ABFM_FIXTURES=/tmp/abfm-test/fixtures
#   ABFM_FIXTURE_URL / ABFM_HOST_URL  (host HTTP server as seen from the guest)
# A test passes when it exits 0, prints a TAP plan `1..N` with N > 0 and
# exactly N result lines, and none of them is "not ok"; per-file limit
# ABFM_GUEST_TEST_TIMEOUT seconds (default 900). *.host.sh tests run with bash
# on the host with guest_exec/guest_copy/guest_fetch and GUEST_* available.
# On a shared guest, the state every file must leave behind (configs and no
# uncommitted UCI changes, flushed reload_config, query logging, drop-ins,
# enabled services, the plugin loaded, the job lock free, only the service's
# dnsmasq) is recorded before each file and compared after it; a difference
# fails that file. results/state.install is the state after the install.
# Results: $GUEST_RUN_DIR/results/<test>.log and summary.tsv.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
# shellcheck source=scripts/guest/lib.sh
source "$root/scripts/guest/lib.sh"

install=1 isolate=0 keep=0 run_tests=1 host_cmd=''
while (($#)); do
	case "$1" in
		--no-install) install=0; shift ;;
		--isolate) isolate=1; shift ;;
		--host-cmd) host_cmd="$2"; shift 2 ;;
		--keep) keep=1; shift ;;
		--no-tests) run_tests=0; shift ;;
		-h | --help) sed -n '2,25p' "$0"; exit 0 ;;
		--) shift; break ;;
		-*) echo "unknown option: $1" >&2; exit 2 ;;
		*) break ;;
	esac
done
apk="${1:-${PACKAGE_APK:-${PACKAGE_IPK:-}}}"
[[ -n "$apk" && -f "$apk" ]] || { echo "usage: $0 [options] PACKAGE.apk [TEST...]" >&2; exit 2; }
apk="$(cd "$(dirname "$apk")" && pwd)/$(basename "$apk")"
shift || true
tests=("$@")
if ((run_tests && ${#tests[@]} == 0)); then
	while IFS= read -r file; do tests+=("$file"); done < <(
		find test/guest -maxdepth 1 -type f -name '*.sh' 2>/dev/null | LC_ALL=C sort)
fi
PACKAGE_SHA256="$(sha256sum "$apk" | awk '{print $1}')"
export PACKAGE_APK="$apk" PACKAGE_IPK="$apk" PACKAGE_SHA256

# Prints the guest state a test file must restore (see the header).
# shellcheck disable=SC2016 # a script for the guest's shell
GUEST_STATE='
for c in dhcp adblock-fast adblock-fast-monitor system rpcd network; do
	echo "config $c $(uci -q -t /tmp/abfm-state.nosave show $c | md5sum | cut -c1-32)"
done
for f in /tmp/.uci/*; do [ -s "$f" ] && echo "uncommitted ${f##*/}: $(tr "\n" " " <"$f")"; done
if [ -f /var/run/config.md5 ]; then
	sed -n "s#^\([0-9a-f]*\)  /var/run/config.check/\(.*\)#\1 \2#p" /var/run/config.md5 | while read -r sum c; do
		[ "$(uci show "$c" 2>/dev/null | md5sum | cut -c1-32)" = "$sum" ] || echo "unflushed $c (reload_config was not run after a change)"
	done
fi
for s in adblock-fast adblock-fast-monitor dnsmasq uhttpd rpcd log; do
	echo "enabled $s $(/etc/init.d/$s enabled && echo 1 || echo 0)"
done
echo "query_logging $(uci -q get adblock-fast-monitor.config.query_logging)"
echo "dropins $(ls /tmp/dnsmasq*.d/adblock-fast-monitor.conf 2>/dev/null | wc -l)"
echo "plugin $(ubus list luci.adblock-fast-monitor >/dev/null 2>&1 && echo 1 || echo 0)"
l=/var/lock/adblock-fast-monitor.lock
echo "job-lock-free $({ [ ! -e $l ] || flock -n $l true; } && echo 1 || echo 0)"
echo "dnsmasq-processes $(pidof dnsmasq | wc -w)"
'
summary=''
failures=0
guest_up=0
cleanup() { ((guest_up)) && guest_stop; guest_up=0; }
trap cleanup EXIT

boot() {
	guest_start
	guest_up=1
	mkdir -p "$GUEST_RUN_DIR/results"
	guest_exec 'rm -rf /tmp/abfm-test && mkdir -p /tmp/abfm-test/tests'
	guest_copy_dir test/lib /tmp/abfm-test/lib
	guest_copy_dir test/fixtures /tmp/abfm-test/fixtures
	guest_copy "$apk" /tmp/abfm-test/package.apk
	guest_exec "printf '%s  %s\n' $PACKAGE_SHA256 /tmp/abfm-test/package.apk | sha256sum -c -s"
	if ((install)); then
		guest_exec 'apk update -q >/dev/null 2>&1 || :; apk add --allow-untrusted /tmp/abfm-test/package.apk' \
			>"$GUEST_RUN_DIR/results/install.log" 2>&1 ||
			{ cat "$GUEST_RUN_DIR/results/install.log" >&2; echo 'APK installation failed' >&2; return 1; }
	fi
	guest_exec "$GUEST_STATE" >"$GUEST_RUN_DIR/results/state.install"
	printf '%s\t%s\t%s\n' boot "$GUEST_BOOT_SECONDS" "$GUEST_ACCEL_USED" >>"$GUEST_RUN_DIR/results/summary.tsv"
}

run_one() {
	local file="$1" name log rc start
	name="$(basename "$file")"
	log="$GUEST_RUN_DIR/results/$name.log"
	start=$(date +%s)
	printf '=== %s\n' "$file"
	local before='' check=0
	if ((guest_up && ! isolate && install)); then
		check=1
		before="$(guest_exec "$GUEST_STATE" 2>&1)"
	fi
	set +e
	if [[ "$name" == *.host.sh ]]; then
		bash "$file" 2>&1 | tee "$log"
		rc=${PIPESTATUS[0]}
	else
		guest_copy "$file" "/tmp/abfm-test/tests/$name"
		guest_exec "cd /tmp/abfm-test || exit 1;" \
			"export ABFM_TESTLIB=/tmp/abfm-test/lib ABFM_APK=/tmp/abfm-test/package.apk" \
			"ABFM_FIXTURES=/tmp/abfm-test/fixtures ABFM_HOST_URL=$GUEST_HOST_URL" \
			"ABFM_FIXTURE_URL=$GUEST_FIXTURE_URL PACKAGE_SHA256=$PACKAGE_SHA256;" \
			". /tmp/abfm-test/lib/sh/testlib.sh; abfm_timeout ${ABFM_GUEST_TEST_TIMEOUT:-900} sh tests/$name" 2>&1 | tee "$log"
		rc=${PIPESTATUS[0]}
	fi
	local verdict=PASS plan
	plan="$(sed -n 's/^1\.\.\([0-9][0-9]*\)\( .*\)\{0,1\}$/\1/p' "$log" | tail -n 1)"
	if [[ -z "$plan" || "$plan" == 0 ]]; then
		echo "# no TAP plan with at least one test" | tee -a "$log"
		rc=${rc/#0/1}
	elif (($(grep -cE '^(not )?ok [0-9]+' "$log" || true) != plan)); then
		echo "# plan 1..$plan but $(grep -cE '^(not )?ok [0-9]+' "$log" || true) result lines" | tee -a "$log"
		rc=${rc/#0/1}
	fi
	if ((check)); then
		local state
		state="$(guest_exec "$GUEST_STATE" 2>&1)"
		if [[ "$state" != "$before" ]]; then
			{ echo "# guest state left behind differs from the state before this file:"
				diff <(printf '%s\n' "$before") <(printf '%s\n' "$state") | sed 's/^/#   /' || true; } | tee -a "$log"
			rc=${rc/#0/1}
		fi
	fi
	set -e
	if ((rc != 0)) || grep -q '^not ok' "$log"; then verdict=FAIL; failures=$((failures + 1)); fi
	printf '%s %s (exit %s, %ss)\n' "$verdict" "$file" "$rc" "$(($(date +%s) - start))"
	printf '%s\t%s\t%s\t%s\n' "$file" "$verdict" "$rc" "$(($(date +%s) - start))" >>"$GUEST_RUN_DIR/results/summary.tsv"
	summary+="$verdict $file"$'\n'
}

if ((isolate)); then
	for file in "${tests[@]}"; do
		boot
		run_one "$file"
		cleanup
	done
else
	boot
	for file in "${tests[@]}"; do run_one "$file"; done
fi

if [[ -n "$host_cmd" ]]; then
	((guest_up)) || boot
	printf '=== host command: %s\n' "$host_cmd"
	set +e
	bash -c "$host_cmd"
	rc=$?
	set -e
	if ((rc != 0)); then failures=$((failures + 1)); summary+="FAIL host-cmd"$'\n'; else summary+="PASS host-cmd"$'\n'; fi
fi

if ((keep && guest_up)); then
	echo "guest kept: ssh -i $GUEST_SSH_KEY -p $GUEST_SSH_PORT root@127.0.0.1 ; LuCI $GUEST_HTTP_URL (root / $GUEST_ROOT_PASSWORD). Press Enter to stop."
	read -r _
fi

printf '\nGuest run %s\n%s' "${GUEST_RUN_DIR:-}" "$summary"
printf '%d test file(s), %d failure(s)\n' "${#tests[@]}" "$failures"
((failures == 0))
