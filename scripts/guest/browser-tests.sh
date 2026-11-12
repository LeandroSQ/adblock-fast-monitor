#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Host command for run-guest-tests.sh --host-cmd: runs the Playwright suite in
# test/browser against the running guest's LuCI with the per-run credentials.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
: "${GUEST_HTTP_URL:?run this from scripts/guest/run-guest-tests.sh --host-cmd}"
# node_modules may be a long-lived volume (scripts/in-docker.sh): reinstall
# whenever package-lock.json differs from the one it was installed from.
stamp=node_modules/.abfm-lock.sha256
want="$({ sha256sum 2>/dev/null || shasum -a 256; } <package-lock.json | cut -d' ' -f1)"
if [[ ! -x node_modules/.bin/playwright || "$(cat "$stamp" 2>/dev/null)" != "$want" ]]; then
	npm ci --no-audit --no-fund
	printf '%s\n' "$want" >"$stamp"
fi
npx playwright install --with-deps chromium >/dev/null
MONITOR_BASE_URL="$GUEST_HTTP_URL" \
MONITOR_LUCI_USERNAME="$GUEST_READONLY_USER" MONITOR_LUCI_PASSWORD="$GUEST_READONLY_PASSWORD" \
	npm run test:browser:required
