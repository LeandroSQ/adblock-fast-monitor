// T23 (docs/CONTRACT.md §8.1): every dashboard state is rendered from a real
// guest condition, created over SSH on the running guest.
import { expect, test } from '@playwright/test';
import { admin, banner, dnsQuery, ensureHealthy, expectState, guest, guestWait, isUbus, login, POLL, seeDomain }
  from './lib/guest.mjs';

test.describe.configure({ mode: 'serial' });

const STATUS_CALL = /"adblock-fast-monitor","status"/;

test.beforeEach(() => ensureHealthy());
test.afterAll(() => ensureHealthy());

test('healthy: statistics, last domains and dismissible warnings', async ({ page }) => {
  await login(page, admin);
  await seeDomain(page, 'ads.example.test');
  await expectState(page, 'healthy');
  await expect(banner(page)).toHaveClass(/alert-message/);
  await expect(banner(page)).toHaveAttribute('role', 'status');

  const stats = page.getByRole('table', { name: 'Statistics' });
  await expect(stats.locator('[data-stat="queries"] td')).not.toHaveText('0', { timeout: 30_000 });
  await expect(stats.locator('[data-stat="blocked"] td')).not.toHaveText('0');
  await expect(stats.locator('[data-stat="block_pct"] td')).toHaveText(/%|—/);
  await expect(stats.locator('[data-stat="since"] td')).toHaveText(/^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d/);
  await expect(stats.locator('[data-stat="drops"] td')).toHaveText(/^\d/);

  const recent = page.getByRole('table', { name: 'Last domains' });
  const row = recent.locator('tr[data-domain="ads.example.test"]');
  await expect(row).toBeVisible({ timeout: 30_000 });
  await expect(row).toHaveAttribute('data-decision', 'blocked');
  await expect(row.locator('time')).toHaveText(/^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d$/);

  // query logging is active (drop-in) → informational note, dismissible
  const note = page.locator('[data-warning="query-logging-active"]');
  await expect(note).toBeVisible({ timeout: 60_000 });
  await note.getByRole('button', { name: 'Dismiss note' }).click();
  await expect(note).toHaveCount(0);

  // filter and search refetch immediately
  await page.getByLabel('Show').selectOption('allowed');
  await expect(recent.locator('tr[data-domain="ads.example.test"]')).toHaveCount(0);
  await page.getByLabel('Show').selectOption('');
  await page.getByLabel('Search').fill('ads.example');
  await expect(recent.locator('tr[data-domain="ads.example.test"]')).toBeVisible();
  await page.getByLabel('Search').fill('nomatch-zzz');
  await expect(recent.locator('tr.placeholder')).toContainText('No domains match the filter.');
  await page.getByLabel('Search').fill('bad value!');
  await expect(page.locator('#abfm-search-hint')).toContainText('letters, digits');
});

test('disabled: "Monitoring is off" with a link to Settings, actions still available', async ({ page }) => {
  guest('uci set adblock-fast-monitor.config.enabled=0 && uci commit adblock-fast-monitor && /etc/init.d/adblock-fast-monitor stop; /etc/init.d/adblock-fast-monitor start');
  guestWait('! ubus list adblock-fast-monitor >/dev/null 2>&1', 30);
  await login(page, admin);
  await expectState(page, 'disabled');
  await expect(banner(page)).toContainText('Monitoring is off');
  await expect(banner(page).getByRole('link', { name: 'Open settings' })).toHaveAttribute('href', /adblock-fast-monitor\/settings$/);
  await expect(page.getByRole('button', { name: 'Add to pending' })).toBeVisible();
  // no process, so no status polling: only info is refreshed (every 30 s)
  const calls = [];
  page.on('request', (r) => { if (isUbus(new URL(r.url())) && STATUS_CALL.test(r.postData() || '')) calls.push(r); });
  await page.waitForTimeout(POLL * 3 * 1000);
  expect(calls).toHaveLength(0);
});

test('not-running: enabled but the service is stopped', async ({ page }) => {
  guest('/etc/init.d/adblock-fast-monitor stop');
  guestWait('! ubus list adblock-fast-monitor >/dev/null 2>&1', 30);
  await login(page, admin);
  await expectState(page, 'not-running');
  await expect(banner(page)).toContainText('logread -e adblock-fast-monitor');
  guest('/etc/init.d/adblock-fast-monitor start');
  await expectState(page, 'healthy', { timeout: 90_000 });
});

test('logging-unavailable: dnsmasq stopped', async ({ page }) => {
  await login(page, admin);
  await expectState(page, 'healthy');
  guest('/etc/init.d/dnsmasq stop');
  // info refreshes every 30 s
  await expectState(page, 'logging-unavailable', { timeout: 90_000 });
  await expect(banner(page).locator('[data-reason="dnsmasq-not-running"]')).toBeVisible();
  await expect(page.locator('#abfm-stats-section')).toHaveAttribute('aria-disabled', 'true');
});

test('logging-unavailable: dnsmasq logs to a file', async ({ page }) => {
  guest("uci set dhcp.@dnsmasq[0].logfacility='/tmp/abfm-dnsmasq.log' && uci commit dhcp && /etc/init.d/dnsmasq restart");
  await login(page, admin);
  await expectState(page, 'logging-unavailable');
  await expect(banner(page).locator('[data-reason="dnsmasq-logs-to-file"]')).toBeVisible();
});

test('degraded: adblock-fast in nftset mode', async ({ page }) => {
  guest('uci set adblock-fast.config.dns=dnsmasq.nftset && uci commit adblock-fast');
  await login(page, admin);
  await expectState(page, 'degraded');
  await expect(banner(page).locator('[data-reason="dns-mode-unsupported"]')).toBeVisible();
});

test('adblock-fast-missing: no actions offered', async ({ page }) => {
  guest('mv /etc/init.d/adblock-fast /root/abfm-adblock-fast.init');
  await login(page, admin);
  await expectState(page, 'adblock-fast-missing');
  await expect(banner(page)).toHaveClass(/danger/);
});

test('stale overlay: the router stops answering, last data stays visible', async ({ page }) => {
  await login(page, admin);
  await seeDomain(page, 'telemetry.example.test');
  await expectState(page, 'healthy');
  const row = page.getByRole('table', { name: 'Last domains' }).locator('tr[data-domain="telemetry.example.test"]');
  await expect(row).toBeVisible({ timeout: 30_000 });
  await expect(banner(page)).toHaveAttribute('data-stale', 'false');
  await page.route(isUbus, (route) => route.abort('connectionrefused'));
  await expect(banner(page)).toHaveAttribute('data-stale', 'true', { timeout: POLL * 3 * 1000 + 30_000 });
  await expect(banner(page)).toContainText('stale since');
  await expect(row).toBeVisible();
  await page.unroute(isUbus);
  await expect(banner(page)).toHaveAttribute('data-stale', 'false', { timeout: 30_000 });
});

test('access-denied: info rejected with -32002', async ({ page }) => {
  // A principal without the read grant cannot reach the menu entry at all, so
  // the denied reply is injected for this one call; everything else is real.
  const isInfo = (c) => c?.params?.[1] === 'luci.adblock-fast-monitor' && c?.params?.[2] === 'info';
  const denied = (c) => ({ jsonrpc: '2.0', id: c.id, error: { code: -32002, message: 'Access denied' } });
  await page.route(isUbus, async (route) => {
    const body = route.request().postDataJSON();
    const calls = Array.isArray(body) ? body : [body];
    if (!calls.some(isInfo)) return route.continue();
    const response = await route.fetch();
    let json = await response.json();
    json = Array.isArray(body) ? json.map((r, i) => (isInfo(body[i]) ? denied(body[i]) : r)) : denied(body);
    return route.fulfill({ response, json });
  });
  await login(page, admin);
  await expectState(page, 'access-denied');
  await expect(page.locator('#abfm-pending-section')).toBeVisible();
});

test('dnsQuery helper reaches the guest resolver', async () => {
  const reply = await dnsQuery('ads.example.test');
  expect(reply).not.toBeNull();
});

test(`overview route uses poll_interval=${POLL} for refreshes while visible`, async ({ page }) => {
  await login(page, admin);
  await expectState(page, 'healthy');
  const stamps = [];
  page.on('request', (r) => {
    if (isUbus(new URL(r.url())) && STATUS_CALL.test(r.postData() || '')) stamps.push(Date.now());
  });
  await page.waitForTimeout(POLL * 4 * 1000 + 500);
  expect(stamps.length).toBeGreaterThanOrEqual(3);
  expect(stamps.length).toBeLessThanOrEqual(6);
  // hidden page: polling stops
  await page.evaluate(() => {
    Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => 'hidden' });
    document.dispatchEvent(new Event('visibilitychange'));
  });
  const before = stamps.length;
  await page.waitForTimeout(POLL * 3 * 1000);
  expect(stamps.length - before).toBeLessThanOrEqual(1);
});
