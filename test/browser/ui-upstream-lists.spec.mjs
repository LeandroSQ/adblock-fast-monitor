// SPDX-License-Identifier: Apache-2.0
// T24 (docs/CONTRACT.md §8.4): "Apply and save" uses adblock-fast's own
// lists, so what it applies shows in luci-app-adblock-fast's "Allowed
// Domains" and "Blocked Domains" (a form.DynamicList each). The upstream
// LuCI app is installed for this file and removed afterwards: the exact
// OpenWrt 25.12.6 package, fetched through the harness's package cache and
// checked against the SHA-256 below before `apk add` (OpenWrt rebuilds the
// release's luci index, so a cached index may not list today's file).
import { expect, test } from '@playwright/test';
import {
  admin, ensureHealthy, guest, jobState, login, resultRow, stageFromRow, waitAdblockFast
} from './lib/guest.mjs';

test.describe.configure({ mode: 'serial' });

const STORAGE = 'adblock-fast-monitor.pending.v2';
const UPSTREAM_PAGE = '/cgi-bin/luci/admin/services/adblock-fast';
const UPSTREAM_APK = {
  path: 'releases/25.12.6/packages/x86_64/luci/luci-app-adblock-fast-1.2.4-r4.apk',
  sha256: '327d80add703c5603a45c16b6301f0b79ec07dacb53051ba7b6ba3de2cc57ddf'
};

const resetRules = () => {
  guest('uci -q delete adblock-fast.config.allowed_domain; uci -q delete adblock-fast.config.blocked_domain; uci commit adblock-fast; /etc/init.d/adblock-fast restart >/dev/null 2>&1 || :');
  waitAdblockFast();
};

test.beforeAll(() => {
  ensureHealthy();
  resetRules();
  const host = process.env.GUEST_HOST_URL;
  if (!host) throw new Error('Browser test prerequisite blocked: GUEST_HOST_URL is unset');
  guest([
    'set -e', 'f=/tmp/abfm-luci-app-adblock-fast.apk',
    `wget -q -O "$f" '${host}/${UPSTREAM_APK.path}'`,
    `echo '${UPSTREAM_APK.sha256}  '"$f" | sha256sum -c - >/dev/null`,
    'apk add --allow-untrusted "$f" >/dev/null', 'rm -f "$f"'
  ].join('\n'));
});

test.afterAll(() => {
  guest('apk del luci-app-adblock-fast >/dev/null 2>&1 || :; rm -f /tmp/luci-indexcache.*; rm -rf /tmp/luci-modulecache/');
  resetRules();
});

/* The values of one DynamicList of luci-app-adblock-fast's page (§6.3 lists). */
const listed = (page, option) => page.locator(`[id="cbid.adblock-fast.config.${option}"] .item input[type="hidden"]`)
  .evaluateAll((inputs) => inputs.map((i) => i.value));

test('T24: domains applied from this page appear in luci-app-adblock-fast\'s Allowed and Blocked Domains', async ({ page }) => {
  const block = 'upstream-list.up.example.test', allow = 'telemetry.example.test';
  await login(page, admin);
  await page.evaluate((k) => localStorage.removeItem(k), STORAGE);
  await page.reload();
  await stageFromRow(page, 'block', block);
  await stageFromRow(page, 'allow', allow);
  await page.getByRole('button', { name: 'Apply and save' }).click();
  await page.locator('.modal').getByRole('button', { name: 'Apply and save' }).click();
  await expect(jobState(page)).toHaveAttribute('data-state', 'applied', { timeout: 480_000 });
  for (const d of [block, allow]) await expect(resultRow(page, d)).toHaveAttribute('data-result', 'ok');

  await page.goto(UPSTREAM_PAGE);
  await expect(page.locator('[id="cbid.adblock-fast.config.blocked_domain"]')).toBeAttached({ timeout: 60_000 });
  expect(await listed(page, 'blocked_domain')).toEqual([block]);
  expect(await listed(page, 'allowed_domain')).toEqual([allow]);
});
