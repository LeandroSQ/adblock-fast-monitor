#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Regenerates the README screenshots (docs/images/*.png) from a QEMU guest's
# LuCI, with test traffic only (*.example.test names, TEST-NET answers).
#
#   npm run docs:screenshots -- PACKAGE.apk
#
# Boots a fresh guest (scripts/verify-guest.sh: in Docker on non-Linux
# hosts), installs the APK, runs no guest tests and then
# scripts/docs/screenshots-host.sh, which drives Playwright
# (scripts/docs/screenshots.spec.mjs) and checks each PNG stays under
# 300 KB. The APK must be inside the worktree or .local-validation/.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
apk="${1:?usage: npm run docs:screenshots -- PACKAGE.apk}"
exec scripts/verify-guest.sh --no-tests --host-cmd scripts/docs/screenshots-host.sh "$apk"
