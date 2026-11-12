#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Host command for run-guest-tests.sh --host-cmd (see scripts/docs/screenshots.sh):
# captures the README screenshots from the running guest's LuCI into
# docs/images/ and fails when one is 300 KB or larger.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
: "${GUEST_HTTP_URL:?run this from scripts/docs/screenshots.sh}"
# Same dependency handling as scripts/guest/browser-tests.sh.
stamp=node_modules/.abfm-lock.sha256
want="$({ sha256sum 2>/dev/null || shasum -a 256; } <package-lock.json | cut -d' ' -f1)"
if [[ ! -x node_modules/.bin/playwright || "$(cat "$stamp" 2>/dev/null)" != "$want" ]]; then
	npm ci --no-audit --no-fund
	printf '%s\n' "$want" >"$stamp"
fi
npx playwright install --with-deps chromium >/dev/null
MONITOR_BASE_URL="$GUEST_HTTP_URL" \
	npx playwright test --config scripts/docs/playwright.config.mjs
status=0
for png in docs/images/overview.png docs/images/apply.png; do
	size="$(wc -c <"$png" | tr -d ' ')"
	printf '%s: %s bytes\n' "$png" "$size"
	((size < 300 * 1024)) || { echo "$png is over 300 KB" >&2; status=1; }
done
exit "$status"
