#!/usr/bin/env bash
# Local guest verification entrypoint (npm run verify:guest -- ...).
#
#   npm run verify:guest -- [--browser] [run-guest-tests options] PACKAGE.apk [TEST...]
#
# Runs scripts/guest/run-guest-tests.sh directly on Linux hosts with QEMU,
# otherwise inside a fresh container via scripts/in-docker.sh. --browser also
# runs the Playwright suite (test/browser) against the guest's LuCI.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
args=()
for arg in "$@"; do
	if [[ "$arg" == --browser ]]; then
		args+=(--host-cmd scripts/guest/browser-tests.sh)
	else
		args+=("$arg")
	fi
done
# The APK path must be visible inside the container: make it worktree-relative
# or under the shared cache (both are mounted at the same paths).
if [[ "$(uname -s)" == Linux ]] && command -v qemu-system-x86_64 >/dev/null; then
	exec "$root/scripts/guest/run-guest-tests.sh" "${args[@]}"
fi
exec "$root/scripts/in-docker.sh" -- scripts/guest/run-guest-tests.sh "${args[@]}"
