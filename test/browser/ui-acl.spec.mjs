// SPDX-License-Identifier: Apache-2.0
// T25 (docs/CONTRACT.md §8.4, §8.5, §9): a read-only principal sees the
// statistics and the queries but no write control; an admin turns query
// logging off and on from the page.
import { expect, test } from '@playwright/test';
import { admin, ensureHealthy, guest, guestWait, login, queries, readonly, seeQuery } from './lib/guest.mjs';

test.describe.configure({ mode: 'serial' });

// The harness login (scripts/guest/lib.sh) holds the stock `unauthenticated`
// and `luci-base` read grants every LuCI login needs, plus only the read grant
// of this package.
test.beforeAll(() => {
  ensureHealthy();
  guestWait('ubus list luci.adblock-fast-monitor >/dev/null 2>&1', 30);
});
test.afterAll(() => ensureHealthy());

test('read-only user: statistics and queries without write controls', async ({ page }) => {
  await login(page, readonly);
  await expect(page.locator('#abfm-disclaimer')).toBeVisible();
  const row = await seeQuery(page, 'ads.example.test', { decision: 'blocked' });
  await expect(page.locator('#abfm-state')).toHaveAttribute('data-state', 'healthy');
  await expect(page.locator('#abfm-read-error')).toHaveCount(0);
  await expect(page.locator('[data-stat="blocked_pct"]').getByRole('img', { name: /^\d+ % of recent queries blocked$/ })).toBeVisible();
  await expect(page.locator('#abfm-changes-section')).toHaveCount(0);
  await expect(page.getByRole('button', { name: /Apply|Discard|Allow|Block|Undo|query logging/ })).toHaveCount(0);
  await expect(row.getByRole('button')).toHaveCount(0);
  await expect(queries(page).getByRole('columnheader')).toHaveText(['Time', 'Domain', 'Client', 'Result']);
  await expect(page.locator('#abfm-logging')).toContainText('Query logging is on');
  await expect(page.getByText('Session expired')).toHaveCount(0);
});

test('admin: Turn off and Turn on query logging from the page; a read-only user cannot', async ({ page, browser }) => {
  try {
    await login(page, admin);
    await page.locator('#abfm-logging').getByRole('button', { name: 'Turn off query logging' }).click();
    await expect.poll(() => guest('uci -q get adblock-fast-monitor.config.query_logging').trim(), { timeout: 120_000 }).toBe('0');
    expect(guest('uci -q changes adblock-fast-monitor').trim()).toBe('');
    // the drop-in follows the option (reload trigger)
    guestWait('! grep -qs "^log-queries" /tmp/dnsmasq.*.d/*', 60);
    await page.goto(page.url());
    await expect(page.locator('#abfm-state')).toHaveAttribute('data-state', 'logging-off', { timeout: 60_000 });
    await expect(page.locator('#abfm-logging')).toBeEmpty();

    const ro = await browser.newPage();
    await login(ro, readonly);
    await expect(ro.locator('#abfm-state')).toHaveAttribute('data-state', 'logging-off', { timeout: 60_000 });
    await expect(ro.locator('#abfm-state')).toContainText('An administrator can turn it on on this page.');
    await expect(ro.locator('#abfm-overview').getByRole('button')).toHaveCount(0);
    await ro.close();

    await page.locator('#abfm-state').getByRole('button', { name: 'Turn on query logging' }).click();
    await expect.poll(() => guest('uci -q get adblock-fast-monitor.config.query_logging').trim(), { timeout: 120_000 }).toBe('1');
    expect(guest('uci -q changes adblock-fast-monitor').trim()).toBe('');
    guestWait('grep -qs "^log-queries" /tmp/dnsmasq.*.d/*', 60);
    await page.goto(page.url());
    await expect(page.locator('#abfm-state')).toHaveAttribute('data-state', 'healthy', { timeout: 60_000 });
    await seeQuery(page, 'logging-back.up.example.test');
  } finally {
    guest('uci set adblock-fast-monitor.config.query_logging=1; uci commit adblock-fast-monitor');
  }
});
