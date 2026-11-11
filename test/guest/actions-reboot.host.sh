#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# shellcheck disable=SC2016 # single-quoted commands are expanded by the guest shell
# T17 reboot persistence (docs/CONTRACT.md §7.4): a rebuild job's UCI change
# survives a guest reboot while job.json (tmpfs) does not, so `job` is null.
# Host side because it reboots the guest; restores the harness files after.
set -u
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/guest/lib.sh
source "$root/scripts/guest/lib.sh"

n=0 failed=0
result() { # status description [diagnostic]
	n=$((n + 1))
	if [[ "$1" == 0 ]]; then echo "ok $n - $2"; else echo "not ok $n - $2"; [[ -n "${3:-}" ]] && echo "#   $3"; failed=1; fi
}
check_eq() { if [[ "$2" == "$3" ]]; then result 0 "$1"; else result 1 "$1" "expected <$2> actual <$3>"; fi; }
g() {
	guest_exec "cd /tmp/abfm-test || exit 1; export ABFM_TESTLIB=/tmp/abfm-test/lib ABFM_FIXTURES=/tmp/abfm-test/fixtures" \
		"ABFM_FIXTURE_URL=$GUEST_FIXTURE_URL; . \$ABFM_TESTLIB/sh/testlib.sh; . \$ABFM_FIXTURES/actions/guest-lib.sh; $1"
}

g 'actions_setup >/dev/null 2>&1'
check_eq "fixture list built by real adblock-fast" statusSuccess "$(g af_status)"
state=$(g "watch '{\"ops\":[{\"op\":\"block\",\"domain\":\"keep.example.com\"}],\"confirm_rebuild\":true}' | jsonfilter -e @.job.state")
check_eq "block job applied before the reboot" applied "$state"
check_eq "job is reported before the reboot" 1 "$(g 'call job | jsonfilter -e @.job.id | grep -c .')"

# The fake upstream does not survive the reboot: without it adblock-fast's
# boot-time heartbeat probe (and so the boot sequence) would stall for
# minutes. UCI persistence is what is under test, so skip the boot start.
g '$AF disable; cp "$BK/dhcp" /etc/config/dhcp'
if guest_reboot; then result 0 "guest rebooted"; else result 1 "guest rebooted"; fi
# /tmp is tmpfs: put the harness files back for the tests that follow.
guest_exec 'mkdir -p /tmp/abfm-test/tests'
guest_copy_dir "$root/test/lib" /tmp/abfm-test/lib
guest_copy_dir "$root/test/fixtures" /tmp/abfm-test/fixtures
[[ -f "${PACKAGE_APK:-}" ]] && guest_copy "$PACKAGE_APK" /tmp/abfm-test/package.apk

check_eq "plugin is loaded after boot" 0 "$(guest_exec 'ubus -t 30 wait_for luci.adblock-fast-monitor; echo $?')"
check_eq "UCI change persisted across the reboot" 1 \
	"$(guest_exec "uci -q get adblock-fast.config.blocked_domain | tr ' ' '\n' | grep -cxF keep.example.com")"
check_eq "job is null after the reboot" "2 true" \
	"$(guest_exec "r=\$(ubus call luci.adblock-fast-monitor job '{}'); echo \$(echo \"\$r\" | jsonfilter -e @.api -e @.ok) \$(echo \"\$r\" | jsonfilter -e @.job)")"
check_eq "no job state file after the reboot" missing "$(guest_exec 'test -e /var/run/adblock-fast-monitor/job.json && echo present || echo missing')"

g 'actions_teardown'
echo "1..$n"
exit "$failed"
