// SPDX-License-Identifier: Apache-2.0
// T23, T28 (docs/CONTRACT.md §8.6): the Status → Overview section shows the
// same statistics as the app's page from its own `log read` calls, makes no
// request of this app while the tab is hidden or the page is idle (P2), none
// while query logging is off, and is not shown to an account without this
// app's grant.
import { expect, test } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import {
  admin, dnsQuery, ensureHealthy, guest, guestWait, login, OVERVIEW, readonly, setVisibility, STATUS, trackAppCalls
} from './lib/guest.mjs';

test.describe.configure({ mode: 'serial' });

const section = (page) => page.locator('#abfm-status');

test.beforeAll(() => ensureHealthy());
test.afterAll(() => ensureHealthy());

test('T23: the section shows the blocked share of the recent queries and links to the page', async ({ page }) => {
  // a fresh log ring: the counted queries are exactly the ones below
  guest('/etc/init.d/log restart; /etc/init.d/dnsmasq restart');
  guestWait('pidof dnsmasq >/dev/null && nslookup a.up.example.test 127.0.0.1 >/dev/null 2>&1', 60);
  for (const name of ['ads.example.test', 'telemetry.example.test', 'metrics.example.test', 'status.up.example.test']) {
    let answered = null;
    for (let i = 0; i < 5 && !answered; i++) answered = await dnsQuery(name);
    expect(answered).not.toBeNull();
  }
  const calls = trackAppCalls(page);
  await login(page, admin, STATUS);
  await expect(section(page)).toHaveAttribute('data-state', 'healthy', { timeout: 60_000 });
  const bar = section(page).getByRole('progressbar', { name: 'Blocked queries' });
  await expect(bar).toHaveAttribute('title', '75 %', { timeout: 30_000 });
  await expect(section(page).locator('[data-stat="text"]')).toHaveText(/^3 of 4 queries blocked in the last \d+ (s|min)$/);
  await expect(section(page).getByRole('link', { name: 'Open Adblock Fast Monitor' })).toHaveAttribute('href', new RegExp(`${OVERVIEW}$`));
  // the section's own reads: 900 first, then bounded incremental reads on LuCI's status poll
  await expect.poll(() => calls.filter((c) => c.call === 'log.read').length, { timeout: 30_000 }).toBeGreaterThan(2);
  // new queries show up without a reload
  await dnsQuery('ads.example.test');
  await expect(section(page).locator('[data-stat="text"]')).toHaveText(/^4 of 5 queries blocked/, { timeout: 30_000 });
  // the info grant is used at most every 30 s
  const infos = calls.filter((c) => c.call === 'luci.adblock-fast-monitor.info');
  expect(infos.length).toBeGreaterThanOrEqual(1);
  expect(infos.length).toBeLessThanOrEqual(2);
  const r = await new AxeBuilder({ page }).include('#abfm-status').withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'])
    .disableRules(['color-contrast']).analyze();
  expect(r.violations.map((v) => v.id)).toEqual([]);
});

test('T28: P2: a hidden Status → Overview makes no request of this app for 60 s and resumes when visible', async ({ page }) => {
  const calls = trackAppCalls(page);
  await login(page, admin, STATUS);
  await expect.poll(() => calls.length, { timeout: 30_000 }).toBeGreaterThan(2);
  await setVisibility(page, 'hidden');
  // a load in flight may still complete; count from a quiet point
  await page.waitForTimeout(3_000);
  const before = calls.length;
  await dnsQuery('hidden-status.up.example.test');
  await page.waitForTimeout(60_000);
  expect(calls.length - before).toBe(0);
  await setVisibility(page, 'visible');
  await expect.poll(() => calls.length - before, { timeout: 15_000 }).toBeGreaterThan(0);
});

test('no input for 15 minutes pauses the section until the next input', async ({ page }) => {
  await page.clock.install();
  const calls = trackAppCalls(page);
  await login(page, admin, STATUS);
  await expect.poll(() => calls.length, { timeout: 30_000 }).toBeGreaterThan(1);
  await page.clock.fastForward('16:00');
  await expect(page.locator('#abfm-status-paused')).toBeVisible({ timeout: 30_000 });
  const paused = calls.length;
  await page.clock.fastForward('01:00');
  await page.clock.runFor(10_000);
  expect(calls.length).toBe(paused);
  await page.mouse.move(10, 10);
  await page.mouse.move(40, 40);
  await expect.poll(() => calls.length, { timeout: 30_000 }).toBeGreaterThan(paused);
  await expect(page.locator('#abfm-status-paused')).toHaveCount(0, { timeout: 30_000 });
});

test('logging off: the section says so and reads no log', async ({ page }) => {
  try {
    guest('uci set adblock-fast-monitor.config.query_logging=0; uci commit adblock-fast-monitor; /etc/init.d/adblock-fast-monitor restart');
    const calls = trackAppCalls(page);
    await login(page, admin, STATUS);
    await expect(section(page)).toHaveAttribute('data-state', 'logging-off', { timeout: 60_000 });
    await expect(section(page)).toContainText('DNS query logging is off.');
    await page.waitForTimeout(12_000);
    expect(calls.filter((c) => c.call === 'log.read')).toHaveLength(0);
  } finally {
    guest('uci set adblock-fast-monitor.config.query_logging=1; uci commit adblock-fast-monitor');
  }
  ensureHealthy();
});

// rpcd computes a session's grants at login. The read-only login gets the
// stock status grant (so Status → Overview lists its sections) and loses this
// app's grant for the test.
test('an account without this app\'s grant does not see the section and stops asking', async ({ page }) => {
  const login_ = 'rpcd.monitor_readonly';
  try {
    guest(`uci add_list ${login_}.read=luci-mod-status-index; uci del_list ${login_}.read=luci-app-adblock-fast-monitor; uci commit rpcd; /etc/init.d/rpcd reload`);
    guestWait('ubus list luci.adblock-fast-monitor >/dev/null 2>&1', 30);
    const calls = trackAppCalls(page);
    await login(page, readonly, STATUS);
    // LuCI's own sections render; ours stays out
    await expect(page.locator('#view .cbi-section:visible').first()).toBeVisible({ timeout: 60_000 });
    await page.waitForTimeout(12_000);
    await expect(section(page)).toHaveCount(0);
    expect(calls.filter((c) => c.call === 'luci.adblock-fast-monitor.info')).toHaveLength(1);
    expect(calls.filter((c) => c.call === 'log.read')).toHaveLength(0);
  } finally {
    guest(`uci del_list ${login_}.read=luci-mod-status-index; uci del_list ${login_}.read=luci-app-adblock-fast-monitor; uci add_list ${login_}.read=luci-app-adblock-fast-monitor; uci commit rpcd; /etc/init.d/rpcd reload`);
  }
  guestWait('ubus list luci.adblock-fast-monitor >/dev/null 2>&1', 30);
});
