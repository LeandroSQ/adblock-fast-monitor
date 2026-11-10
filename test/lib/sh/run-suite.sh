#!/bin/ash
# Runs test files inside the userland container (or an OpenWrt guest) and
# prints a combined report. Usage: run-suite.sh ucode|shell FILE...
# A file passes when it exits 0 and prints no "not ok" line.
kind=$1
shift
. "${ABFM_TESTLIB:-/src/test/lib}/sh/testlib.sh"
timeout_s=${ABFM_TEST_TIMEOUT:-120}
passed=0
failed=0
failed_files=''
log=$(mktemp)

for file in "$@"; do
	case "$kind" in
		ucode) set -- ucode -L "${ABFM_TESTLIB:-/src/test/lib}/ucode/*.uc" "$file" ;;
		shell) set -- /bin/ash "$file" ;;
	esac
	printf '# %s\n' "$file"
	start=$(date +%s)
	abfm_timeout "$timeout_s" "$@" >"$log" 2>&1
	rc=$?
	sed 's/^/    /' "$log"
	if [ "$rc" -eq 0 ] && ! grep -q '^not ok' "$log"; then
		passed=$((passed + 1))
		printf 'PASS %s (%ss)\n' "$file" "$(( $(date +%s) - start ))"
	else
		failed=$((failed + 1))
		failed_files="$failed_files $file"
		[ "$rc" -eq 124 ] && printf '    # timed out after %ss\n' "$timeout_s"
		printf 'FAIL %s (exit %s)\n' "$file" "$rc"
	fi
done
rm -f "$log"
printf '%s suite: %d passed, %d failed\n' "$kind" "$passed" "$failed"
[ "$failed" -eq 0 ] || { printf 'failed:%s\n' "$failed_files"; exit 1; }
