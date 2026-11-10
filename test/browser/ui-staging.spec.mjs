// T24 (docs/CONTRACT.md §8.2): Allow/Block row buttons stage changes that
// persist across reloads; one `apply` per batch after a dry run and a
// confirmation; job progress to per-domain results; the DNS answer really
// flips; failed items return to pending. Runs against the real guest backends.
import { expect, test } from '@playwright/test';
import {
  admin, dnsQuery, ensureHealthy, guest, guestWait, login, pending, pendingRow, queries, queryRow, seeQuery,
  ubusCalls, waitAdblockFast
} from './lib/guest.mjs';

test.describe.configure({ mode: 'serial' });

const STORAGE = 'adblock-fast-monitor.pending.v1';

function trackApply(page) {
  const calls = [];
  page.on('request', (r) => {
    for (const [object, method, args] of ubusCalls(r)) {
      if (object === 'luci.adblock-fast-monitor' && method === 'apply') calls.push(args);
    }
  });
  return calls;
}

async function stageManual(page, op, domain) {
  await page.getByLabel('Domain', { exact: true }).fill(domain);
  await page.getByLabel('Change', { exact: true }).selectOption(op);
  await page.getByRole('button', { name: 'Add to pending' }).click();
}

/* Apply the pending batch, confirm the rebuild and wait for a terminal job. */
async function applyAndWait(page) {
  await page.getByRole('button', { name: 'Apply changes' }).click();
  const modal = page.locator('.modal');
  await expect(modal).toContainText('all lists are downloaded again over the WAN, DNS is restarted, and it may take minutes');
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
  return seen;
}

const resetRules = () => {
  guest('uci -q delete adblock-fast.config.allowed_domain; uci -q delete adblock-fast.config.blocked_domain; uci commit adblock-fast; /etc/init.d/adblock-fast restart >/dev/null 2>&1 || :');
  waitAdblockFast();
};

test.beforeAll(() => {
  ensureHealthy();
  resetRules();
});

test.afterAll(() => {
  guest('rm -f /tmp/dnsmasq.*.d/zz-abfm-broken.conf; uci -q revert adblock-fast || :');
  resetRules();
});

test('row buttons stage changes that survive a reload; manual add, replace and discard', async ({ page }) => {
  await login(page, admin);
  await page.evaluate((k) => localStorage.removeItem(k), STORAGE);
  await page.reload();

  const blocked = await seeQuery(page, 'ads.example.test', { decision: 'blocked' });
  await expect(blocked.getByRole('button', { name: 'Allow ads.example.test' })).toBeVisible();
  await expect(blocked.getByRole('button', { name: 'Block ads.example.test' })).toHaveCount(0);
  const allowed = await seeQuery(page, 'www.up.example.test', { decision: 'allowed' });
  await expect(allowed.getByRole('button', { name: 'Block www.up.example.test' })).toBeVisible();
  await expect(allowed.getByRole('button', { name: 'Allow www.up.example.test' })).toHaveCount(0);

  await blocked.getByRole('button', { name: 'Allow ads.example.test' }).click();
  await expect(pendingRow(page, 'ads.example.test')).toHaveAttribute('data-op', 'allow');
  await expect(queryRow(page, 'ads.example.test')).toContainText('Pending: Allow');

  await page.reload();
  await expect(pendingRow(page, 'ads.example.test')).toHaveAttribute('data-op', 'allow');
  await expect(queryRow(page, 'ads.example.test')).toContainText('Pending: Allow', { timeout: 30_000 });

  // only allow and block can be staged; a different op for the same domain replaces
  await expect(page.getByLabel('Change', { exact: true }).locator('option')).toHaveText(['Allow', 'Block']);
  await stageManual(page, 'block', 'ADS.example.test.');
  await expect(pending(page).locator('tr[data-domain]')).toHaveCount(1);
  await expect(pendingRow(page, 'ads.example.test')).toHaveAttribute('data-op', 'block');

  // invalid input is refused before it is stored
  await stageManual(page, 'block', 'not a domain');
  await expect(page.locator('.alert-message').filter({ hasText: 'Invalid domain name' })).toBeVisible();
  await expect(pending(page).locator('tr[data-domain]')).toHaveCount(1);

  // per-row cancel, remove, and discard all
  await queryRow(page, 'ads.example.test').getByRole('button', { name: 'Cancel pending change for ads.example.test' }).click();
  await expect(pending(page).locator('tr[data-domain]')).toHaveCount(0);
  await stageManual(page, 'allow', 'ads.example.test');
  await stageManual(page, 'block', 'tracker2.example.test');
  await pending(page).getByRole('button', { name: 'Remove pending change for tracker2.example.test' }).click();
  await expect(pending(page).locator('tr[data-domain]')).toHaveCount(1);
  await page.getByRole('button', { name: 'Discard all' }).click();
  await expect(pending(page).locator('tr[data-domain]')).toHaveCount(0);
  await page.reload();
  await expect(pending(page)).toContainText('No pending changes.');
});

test('cancelling the confirmation sends only the dry run; uncommitted CLI changes are explained', async ({ page }) => {
  await login(page, admin);
  const applies = trackApply(page);
  await stageManual(page, 'allow', 'telemetry.example.test');
  await page.getByRole('button', { name: 'Apply changes' }).click();
  const modal = page.locator('.modal');
  await expect(modal).toContainText('rebuilds the adblock-fast block lists');
  await expect(modal).toContainText('telemetry.example.test');
  await modal.getByRole('button', { name: 'Cancel' }).click();
  expect(applies.filter((a) => !a.dry_run)).toHaveLength(0);
  expect(applies.filter((a) => a.dry_run)).toHaveLength(1);
  await expect(pendingRow(page, 'telemetry.example.test')).toHaveAttribute('data-op', 'allow');

  // §5.10: the guard sees uncommitted `uci` command-line changes, not LuCI's staged ones
  guest('uci set adblock-fast.config.abfm_browser_probe=1');
  try {
    await page.getByRole('button', { name: 'Apply changes' }).click();
    const note = page.locator('[data-error="pending-uci-changes"]');
    await expect(note).toContainText('uncommitted changes made on the command line (uci) or by adblock-fast itself');
  } finally {
    guest('uci -q revert adblock-fast.config.abfm_browser_probe || uci -q revert adblock-fast');
  }
  expect(applies.filter((a) => !a.dry_run)).toHaveLength(0);
  await page.getByRole('button', { name: 'Discard all' }).click();
});

test('Block then Allow from the list: one apply per batch, job applied, DNS answer flips', async ({ page }) => {
  const name = 'flip.up.example.test';
  expect(await dnsQuery(name)).toEqual({ rcode: 0, answers: 1 });
  await login(page, admin);
  const applies = trackApply(page);

  const allowed = await seeQuery(page, name, { decision: 'allowed' });
  await allowed.getByRole('button', { name: `Block ${name}` }).click();
  let seen = await applyAndWait(page);
  expect([...seen]).toContain('applied');
  let real = applies.filter((a) => !a.dry_run);
  expect(real).toHaveLength(1);
  expect(real[0].ops).toEqual([{ op: 'block', domain: name }]);
  expect(real[0].confirm_rebuild).toBe(true);
  const results = page.getByRole('table', { name: 'Apply results' });
  await expect(results.locator(`tr[data-domain="${name}"]`)).toHaveAttribute('data-result', 'ok');
  await expect(pending(page).locator('tr[data-domain]')).toHaveCount(0);
  expect(await dnsQuery(name)).toMatchObject({ answers: 0 });
  expect(guest('uci -q get adblock-fast.config.blocked_domain')).toContain(name);

  const blocked = await seeQuery(page, name, { decision: 'blocked' });
  await blocked.getByRole('button', { name: `Allow ${name}` }).click();
  seen = await applyAndWait(page);
  expect([...seen]).toContain('applied');
  real = applies.filter((a) => !a.dry_run);
  expect(real).toHaveLength(2);
  expect(real[1].ops).toEqual([{ op: 'allow', domain: name }]);
  await expect(results.locator(`tr[data-domain="${name}"]`)).toHaveAttribute('data-result', 'ok');
  expect(await dnsQuery(name)).toEqual({ rcode: 0, answers: 1 });
  expect(guest('uci -q get adblock-fast.config.blocked_domain || :')).not.toContain(name);
  await seeQuery(page, name, { decision: 'allowed' });
});

test('a failed job returns its items to pending with the reason', async ({ page }) => {
  // a broken dnsmasq option makes the resolver restart of the rebuild fail
  waitAdblockFast();
  guestWait('[ ! -s /tmp/.uci/adblock-fast ]', 120);
  guest(`for d in /tmp/dnsmasq.*.d; do echo abfm-no-such-option > "$d/zz-abfm-broken.conf"; done`);
  await login(page, admin);
  await stageManual(page, 'block', 'fail.example.test');
  const seen = await applyAndWait(page);
  guest('rm -f /tmp/dnsmasq.*.d/zz-abfm-broken.conf; /etc/init.d/dnsmasq restart');
  expect([...seen]).toContain('failed');
  await expect(page.locator('#abfm-job [data-error]')).toBeVisible();
  const row = pendingRow(page, 'fail.example.test');
  await expect(row).toHaveAttribute('data-op', 'block');
  await expect(row).toContainText('Last attempt:');
  await page.reload();
  await expect(pendingRow(page, 'fail.example.test')).toContainText('Last attempt:');
  await expect(page.getByRole('button', { name: 'Apply changes' })).toBeEnabled();
  await page.getByRole('button', { name: 'Discard all' }).click();
});
