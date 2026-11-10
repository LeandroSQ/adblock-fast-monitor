#!/usr/bin/env bash
# Host command for run-guest-tests.sh --host-cmd: runs the Playwright suite in
# test/browser against the running guest's LuCI with the per-run credentials.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
: "${GUEST_HTTP_URL:?run this from scripts/guest/run-guest-tests.sh --host-cmd}"
[[ -x node_modules/.bin/playwright ]] || npm ci --no-audit --no-fund
npx playwright install --with-deps chromium >/dev/null
MONITOR_BASE_URL="$GUEST_HTTP_URL" \
MONITOR_LUCI_USERNAME="$GUEST_READONLY_USER" MONITOR_LUCI_PASSWORD="$GUEST_READONLY_PASSWORD" \
	npm run test:browser:required
