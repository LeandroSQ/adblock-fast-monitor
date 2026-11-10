// T25 (docs/CONTRACT.md §8.2, §9): a read-only principal sees no write
// controls; Settings loads and saves for an admin.
import { expect, test } from '@playwright/test';
import { admin, ensureHealthy, expectState, guest, guestWait, login, readonly, seeDomain, SETTINGS } from './lib/guest.mjs';

test.describe.configure({ mode: 'serial' });

// LuCI itself needs the stock `unauthenticated` (session access) and
// `luci-base` (uci get luci, preload listing) read grants for any login;
// without them the core shows "Session expired". The principal still has only
// read access to this package.
const RO = 'rpcd.monitor_readonly.read';
test.beforeAll(() => {
  ensureHealthy();
  guest(`for g in unauthenticated luci-base; do uci -q del_list ${RO}=$g; uci add_list ${RO}=$g; done; uci commit rpcd; /etc/init.d/rpcd reload`);
  guestWait('ubus list luci.adblock-fast-monitor >/dev/null 2>&1', 30);
});
test.afterAll(() => {
  guest(`for g in unauthenticated luci-base; do uci -q del_list ${RO}=$g; done; uci commit rpcd; /etc/init.d/rpcd reload`);
  ensureHealthy();
});

test('read-only user: dashboard without write controls', async ({ page }) => {
  await login(page, readonly);
  await seeDomain(page, 'ads.example.test');
  await page.reload();
  await expectState(page, 'healthy');
  const row = page.getByRole('table', { name: 'Last domains' }).locator('tr[data-domain="ads.example.test"]');
  await expect(row).toBeVisible({ timeout: 30_000 });
  await expect(page.getByRole('table', { name: 'Statistics' })).toBeVisible();
  await expect(page.locator('#abfm-pending-section')).toHaveCount(0);
  await expect(page.getByRole('button', { name: /Apply|Reset statistics|Add to pending|Discard/ })).toHaveCount(0);
  await expect(row.getByRole('button')).toHaveCount(0);
  await expect(page.getByRole('table', { name: 'Last domains' }).getByRole('columnheader', { name: 'Actions' })).toHaveCount(0);
  // the session never got a session-expired modal from a denied write call
  await expect(page.getByText('Session expired')).toHaveCount(0);
});

test('read-only user: settings are shown read-only', async ({ page }) => {
  await login(page, readonly, SETTINGS);
  await expect(page.locator('[data-name="enabled"] input[type="checkbox"]')).toBeDisabled();
  await expect(page.locator('.cbi-page-actions button.cbi-button-save')).toBeDisabled();
});

test('admin: settings load, render §3 options only, validate and save', async ({ page }) => {
  await login(page, admin, SETTINGS);
  await expect(page.locator('[data-name="enabled"] input[type="checkbox"]')).toBeChecked();
  for (const legacy of ['max_events', 'own_logqueries']) {
    await expect(page.locator(`[data-name="${legacy}"]`)).toHaveCount(0);
  }
  const poll = page.locator('[data-name="poll_interval"] input');
  await expect(poll).toHaveValue('2');
  await poll.fill('61');
  await poll.blur();
  await expect(page.locator('[data-name="poll_interval"] .cbi-input-invalid, [data-name="poll_interval"] input.cbi-input-invalid')).toHaveCount(1);
  await poll.fill('3');
  await poll.blur();
  await page.getByRole('link', { name: 'Advanced', exact: true }).click();
  await page.locator('[data-name="recent_size"] input').fill('300');
  await page.locator('.cbi-page-actions').getByText('Save & Apply', { exact: true }).click();
  await expect.poll(() => guest('uci -q get adblock-fast-monitor.config.poll_interval').trim(), { timeout: 120_000 }).toBe('3');
  expect(guest('uci -q get adblock-fast-monitor.config.recent_size').trim()).toBe('300');
  expect(guest('uci -q changes adblock-fast-monitor').trim()).toBe('');
  guest('uci set adblock-fast-monitor.config.poll_interval=2; uci -q delete adblock-fast-monitor.config.recent_size; uci commit adblock-fast-monitor');
});
