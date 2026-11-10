// T24 (docs/CONTRACT.md §8.2): staging persists across reloads; replace and
// cancel rules; one `apply` per batch; confirmation for rebuilds; job progress;
// failed items return to pending. Runs against the real guest backends.
import { expect, test } from '@playwright/test';
import { admin, ensureHealthy, expectState, guest, guestWait, isUbus, login, seeDomain, waitAdblockFast } from './lib/guest.mjs';

test.describe.configure({ mode: 'serial' });

const pending = (page) => page.getByRole('table', { name: 'Pending changes' });
const pendingRow = (page, domain) => pending(page).locator(`tr[data-domain="${domain}"]`);

function trackApply(page) {
  const calls = [];
  page.on('request', (r) => {
    if (!isUbus(new URL(r.url()))) return;
    let body = null;
    try { body = r.postDataJSON(); } catch { return; }
    for (const c of Array.isArray(body) ? body : [body]) {
      if (c?.params?.[1] === 'luci.adblock-fast-monitor' && c?.params?.[2] === 'apply') calls.push(c.params[3]);
    }
  });
  return calls;
}

async function stageManual(page, op, domain) {
  await page.getByLabel('Domain', { exact: true }).fill(domain);
  await page.getByLabel('Change', { exact: true }).selectOption(op);
  await page.getByRole('button', { name: 'Add to pending' }).click();
}

test.beforeAll(() => {
  ensureHealthy();
  guest('uci -q delete adblock-fast.config.allowed_domain; uci -q delete adblock-fast.config.blocked_domain; uci commit adblock-fast; /etc/init.d/adblock-fast restart >/dev/null 2>&1 || :');
  waitAdblockFast();
});

test.afterAll(() => {
  guest(`rm -f /tmp/dnsmasq.*.d/zz-abfm-broken.conf; uci -q delete adblock-fast.config.allowed_domain; uci -q delete adblock-fast.config.blocked_domain; uci commit adblock-fast; /etc/init.d/adblock-fast restart >/dev/null 2>&1 || :`);
  waitAdblockFast();
});

test('row actions stage changes that survive a reload; replace and cancel rules', async ({ page }) => {
  await login(page, admin);
  await page.evaluate(() => localStorage.removeItem('adblock-fast-monitor.pending.v1'));
  await seeDomain(page, 'ads.example.test');
  await page.reload();
  await expectState(page, 'healthy');

  const row = page.getByRole('table', { name: 'Last domains' }).locator('tr[data-domain="ads.example.test"]');
  await expect(row).toBeVisible({ timeout: 30_000 });
  // listed by the fixture list: rules offers Allow, not Block
  await expect(row.getByRole('button', { name: 'Allow ads.example.test' })).toBeVisible({ timeout: 30_000 });
  await expect(row.getByRole('button', { name: 'Block ads.example.test' })).toHaveCount(0);
  await row.getByRole('button', { name: 'Allow ads.example.test' }).click();
  await expect(pendingRow(page, 'ads.example.test')).toHaveAttribute('data-op', 'allow');
  await expect(row).toContainText('Pending: Allow');

  await page.reload();
  await expect(pendingRow(page, 'ads.example.test')).toHaveAttribute('data-op', 'allow');

  // replace: a different op for the same domain replaces the pending one
  await stageManual(page, 'block', 'ADS.example.test.');
  await expect(pending(page).locator('tr[data-domain]')).toHaveCount(1);
  await expect(pendingRow(page, 'ads.example.test')).toHaveAttribute('data-op', 'block');
  // cancel: the inverse removes it
  await stageManual(page, 'unblock', 'ads.example.test');
  await expect(pending(page).locator('tr[data-domain]')).toHaveCount(0);
  await expect(pending(page)).toContainText('No pending changes.');

  // invalid input is refused before it is stored
  await stageManual(page, 'block', 'not a domain');
  await expect(page.locator('.alert-message').filter({ hasText: 'Invalid domain name' })).toBeVisible();
  await expect(pending(page).locator('tr[data-domain]')).toHaveCount(0);

  // per-row cancel and discard all
  await stageManual(page, 'allow', 'ads.example.test');
  await row.getByRole('button', { name: 'Cancel pending change for ads.example.test' }).click();
  await expect(pending(page).locator('tr[data-domain]')).toHaveCount(0);
  await stageManual(page, 'allow', 'ads.example.test');
  await stageManual(page, 'block', 'tracker2.example.test');
  await page.getByRole('button', { name: 'Discard all' }).click();
  await expect(pending(page).locator('tr[data-domain]')).toHaveCount(0);
  await page.reload();
  await expect(pending(page).locator('tr[data-domain]')).toHaveCount(0);
});

test('allow-only batch asks before a possible rebuild; cancel sends nothing', async ({ page }) => {
  await login(page, admin);
  const applies = trackApply(page);
  await stageManual(page, 'allow', 'telemetry.example.test');
  await page.getByRole('button', { name: 'Apply changes' }).click();
  const modal = page.locator('.modal');
  await expect(modal).toContainText('removed from the active block list right away');
  await expect(modal).toContainText('over the WAN');
  await modal.getByRole('button', { name: 'Cancel' }).click();
  expect(applies.filter((a) => !a.dry_run)).toHaveLength(0);
  expect(applies.filter((a) => a.dry_run)).toHaveLength(1);
  await expect(pendingRow(page, 'telemetry.example.test')).toHaveAttribute('data-op', 'allow');
  await page.getByRole('button', { name: 'Discard all' }).click();
});

test('one apply per batch, rebuild confirmation, job progress to applied', async ({ page }) => {
  await login(page, admin);
  await expectState(page, 'healthy');
  const applies = trackApply(page);
  await stageManual(page, 'allow', 'ads.example.test');
  await stageManual(page, 'block', 'tracker2.example.test');
  await page.getByRole('button', { name: 'Apply changes' }).click();
  const modal = page.locator('.modal');
  await expect(modal).toContainText('all lists are downloaded again over the WAN, DNS is restarted, and it may take minutes');
  await expect(modal).toContainText('tracker2.example.test');
  await modal.getByRole('button', { name: 'Apply' }).click();

  const state = page.locator('#abfm-job-state');
  await expect(state).toBeVisible();
  const seen = new Set();
  const deadline = Date.now() + 480_000;
  while (Date.now() < deadline) {
    const s = await state.getAttribute('data-state').catch(() => null);
    if (s) seen.add(s);
    if (['applied', 'partial', 'failed'].includes(s)) break;
    await page.waitForTimeout(500);
  }
  expect([...seen]).toContain('applied');
  expect(seen.has('applying') || seen.has('verifying') || seen.has('queued')).toBeTruthy();

  const real = applies.filter((a) => !a.dry_run);
  expect(real).toHaveLength(1);
  expect(real[0].ops).toEqual([{ op: 'allow', domain: 'ads.example.test' }, { op: 'block', domain: 'tracker2.example.test' }]);
  expect(real[0].confirm_rebuild).toBe(true);

  const results = page.getByRole('table', { name: 'Apply results' });
  await expect(results.locator('tr[data-domain="tracker2.example.test"]')).toHaveAttribute('data-result', 'ok');
  await expect(results.locator('tr[data-domain="ads.example.test"]')).toHaveAttribute('data-result', 'ok');
  await expect(pending(page).locator('tr[data-domain]')).toHaveCount(0);

  // the router really changed
  expect(guest('uci -q get adblock-fast.config.allowed_domain')).toContain('ads.example.test');
  expect(guest('uci -q get adblock-fast.config.blocked_domain')).toContain('tracker2.example.test');
  // rules were refreshed: the allowed row now offers Block/Unallow
  await seeDomain(page, 'ads.example.test');
  const row = page.getByRole('table', { name: 'Last domains' }).locator('tr[data-domain="ads.example.test"]');
  await expect(row.getByRole('button', { name: 'Unallow ads.example.test' })).toBeVisible({ timeout: 30_000 });
  await expect(row).toContainText('Manual allow');
});

test('a failed job returns its items to pending with the reason', async ({ page }) => {
  // a broken dnsmasq option makes the resolver restart of the rebuild fail
  waitAdblockFast();
  guestWait('[ ! -s /tmp/.uci/adblock-fast ]', 120);
  guest(`for d in /tmp/dnsmasq.*.d; do echo abfm-no-such-option > "$d/zz-abfm-broken.conf"; done`);
  await login(page, admin);
  await stageManual(page, 'block', 'fail.example.test');
  await page.getByRole('button', { name: 'Apply changes' }).click();
  await page.locator('.modal').getByRole('button', { name: 'Apply' }).click();
  await expect(page.locator('#abfm-job-state')).toHaveAttribute('data-state', 'failed', { timeout: 480_000 });
  await expect(page.locator('#abfm-job [data-error]')).toBeVisible();
  guest('rm -f /tmp/dnsmasq.*.d/zz-abfm-broken.conf; /etc/init.d/dnsmasq restart');
  const row = pendingRow(page, 'fail.example.test');
  await expect(row).toHaveAttribute('data-op', 'block');
  await expect(row).toContainText('Last attempt:');
  // still there after a reload, and Apply is available again
  await page.reload();
  await expect(pendingRow(page, 'fail.example.test')).toContainText('Last attempt:');
  await expect(page.getByRole('button', { name: 'Apply changes' })).toBeEnabled();
  await page.getByRole('button', { name: 'Discard all' }).click();
});
