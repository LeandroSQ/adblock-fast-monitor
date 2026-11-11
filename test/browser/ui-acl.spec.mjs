// T25 (docs/CONTRACT.md §8.2, §9): a read-only principal sees the queries but
// no write controls; Settings loads and saves for an admin.
import { expect, test } from '@playwright/test';
import { admin, ensureHealthy, guest, guestWait, login, OVERVIEW, pending, queries, readonly, seeQuery, SETTINGS } from './lib/guest.mjs';

test.describe.configure({ mode: 'serial' });

// The harness login (scripts/guest/lib.sh) holds the stock `unauthenticated`
// and `luci-base` read grants every LuCI login needs, plus only the read grant
// of this package.
test.beforeAll(() => {
  ensureHealthy();
  guestWait('ubus list luci.adblock-fast-monitor >/dev/null 2>&1', 30);
});
test.afterAll(() => ensureHealthy());

test('read-only user: queries without write controls', async ({ page }) => {
  await login(page, readonly);
  await expect(page.locator('#abfm-disclaimer')).toBeVisible();
  const row = await seeQuery(page, 'ads.example.test', { decision: 'blocked' });
  await expect(page.locator('#abfm-state')).toHaveAttribute('data-state', 'healthy');
  await expect(page.locator('#abfm-read-error')).toHaveCount(0);
  await expect(page.getByRole('table', { name: 'Statistics' })).toBeVisible();
  await expect(page.locator('#abfm-pending-section')).toHaveCount(0);
  await expect(pending(page)).toHaveCount(0);
  await expect(page.getByRole('button', { name: /Apply|Add to pending|Discard|Allow|Block/ })).toHaveCount(0);
  await expect(row.getByRole('button')).toHaveCount(0);
  await expect(queries(page).getByRole('columnheader', { name: 'Actions' })).toHaveCount(0);
  await expect(page.getByText('Session expired')).toHaveCount(0);
});

test('read-only user: settings are shown read-only', async ({ page }) => {
  await login(page, readonly, SETTINGS);
  await expect(page.locator('[data-name="query_logging"] input[type="checkbox"]')).toBeDisabled();
  await expect(page.locator('.cbi-page-actions button.cbi-button-save')).toBeDisabled();
});

test('admin: settings show only query logging, explain the other toggle, and save', async ({ page }) => {
  await login(page, admin, SETTINGS);
  const flag = page.locator('[data-name="query_logging"] input[type="checkbox"]');
  await expect(flag).toBeChecked();
  await expect(page.locator('[data-name="query_logging"]')).toContainText('luci-app-adblock-fast has its own query-logging toggle');
  for (const legacy of ['enabled', 'manage_logging', 'poll_interval', 'record_clients', 'recent_size', 'top_size', 'pending_size', 'pending_ttl']) {
    await expect(page.locator(`[data-name="${legacy}"]`)).toHaveCount(0);
  }
  try {
    await flag.uncheck();
    await page.locator('.cbi-page-actions').getByText('Save & Apply', { exact: true }).click();
    await expect.poll(() => guest('uci -q get adblock-fast-monitor.config.query_logging').trim(), { timeout: 120_000 }).toBe('0');
    expect(guest('uci -q changes adblock-fast-monitor').trim()).toBe('');
    // the drop-in follows the option (reload trigger)
    guestWait('! grep -qs "^log-queries" /tmp/dnsmasq.*.d/*', 60);
    await page.reload();
    await expect(flag).not.toBeChecked();
    // the dashboard says so and links to Settings
    await page.goto(OVERVIEW);
    await expect(page.locator('#abfm-state')).toHaveAttribute('data-state', 'logging-off');
    await expect(page.locator('#abfm-state').getByRole('link', { name: 'Open settings' })).toHaveAttribute('href', /settings$/);
  } finally {
    guest('uci set adblock-fast-monitor.config.query_logging=1; uci commit adblock-fast-monitor');
  }
});
