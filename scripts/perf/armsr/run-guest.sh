#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Runs a perf host command against a fresh overlay of the armsr-armv8 baseline
# (scripts/perf/armsr/lib.sh: hvf on Apple silicon, natively, no Docker). The
# counterpart of `scripts/verify-guest.sh --no-install --no-tests --host-cmd
# CMD PACKAGE.apk` for the measurement guest: the APK is copied to
# /tmp/abfm-test/package.apk but not installed, so the stock system can be
# measured first.
#
#   scripts/perf/armsr/run-guest.sh CMD PACKAGE.apk
#   (CMD: scripts/perf/run.sh or scripts/perf/ab-dnsmasq.sh)
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$root"
(($# == 2)) || { echo "usage: $0 CMD PACKAGE.apk" >&2; exit 2; }
host_cmd="$1" apk="$2"
[[ -f "$apk" ]] || { echo "no such APK: $apk" >&2; exit 2; }
# shellcheck source=scripts/perf/armsr/lib.sh
source "$root/scripts/perf/armsr/lib.sh"
apk="$(cd "$(dirname "$apk")" && pwd)/$(basename "$apk")"
PACKAGE_SHA256="$(armsr__sha256 "$apk")"
export PACKAGE_APK="$apk" PACKAGE_SHA256 ABFM_PERF_GUEST=armsr-hvf
# Host browsers live in the shared cache, as in the container runs. (With
# Node 26, Playwright 1.55's `install` can hang while extracting; the
# archives can be unpacked there by hand, see docs/performance.md.)
export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-$root/.local-validation/playwright-$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m)}"

guest_up=0
cleanup() { ((guest_up)) && guest_stop; guest_up=0; }
trap cleanup EXIT
guest_start
guest_up=1
guest_exec 'rm -rf /tmp/abfm-test && mkdir -p /tmp/abfm-test'
guest_copy "$apk" /tmp/abfm-test/package.apk
guest_exec "printf '%s  %s\n' $PACKAGE_SHA256 /tmp/abfm-test/package.apk | sha256sum -c -s"
printf '=== host command: %s (armsr-armv8, %s)\n' "$host_cmd" "$GUEST_ACCEL_USED"
set +e
bash -c "$host_cmd"
rc=$?
set -e
printf 'Guest run %s: host command exit %d\n' "$GUEST_RUN_DIR" "$rc"
exit "$rc"
