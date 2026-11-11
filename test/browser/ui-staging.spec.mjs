// SPDX-License-Identifier: Apache-2.0
// T24 (docs/CONTRACT.md §8.4): Allow/Block row buttons stage changes that
// persist across reloads; one `apply` per batch after a dry run and a
// confirmation; job progress to per-domain results; the DNS answer really
// flips; failed items return to pending; busy, resumed, unknown and
// persist-only jobs; no-op and rejected batches; two tabs. Every reply of the
// plugin is checked against the api-2 schemas (S3) once the backend has the
// api-2 trims. Runs against the real guest backends.
import { expect, test } from '@playwright/test';
import {
  admin, checkReplies, dnsQuery, ensureHealthy, guest, guestWait, login, pending, pendingRow, queryRow,
  seeQuery, setVisibility, trackCalls, ubusCalls, waitAdblockFast
} from './lib/guest.mjs';
import { validate } from './lib/schemas.mjs';

test.describe.configure({ mode: 'serial' });

const STORAGE = 'adblock-fast-monitor.pending.v2';

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
  const state = page.locator('#abfm-job-state');
  const previous = (await state.count()) ? await state.getAttribute('data-job') : null;
  await page.getByRole('button', { name: 'Apply changes' }).click();
  const modal = page.locator('.modal');
  await expect(modal).toContainText('all lists are downloaded again over the WAN, DNS is restarted, and it may take minutes');
  await modal.getByRole('button', { name: 'Apply' }).click();
  // the previous job stays on screen until `apply` returns the new one
  await expect(state).toHaveAttribute('data-job', /^j\d{10}-[0-9a-f]{4}$/);
  await expect(state).not.toHaveAttribute('data-job', previous ?? '');
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

// The api-2 trims (info.protected_suffixes, no removed fields) come with
// the backend of unit C; an older backend is reported, not validated.
let strictSchemas = false;
const replies = new WeakMap();

test.beforeAll(() => {
  ensureHealthy();
  resetRules();
  strictSchemas = guest(`ubus call luci.adblock-fast-monitor info`).includes('"protected_suffixes"');
});

test.beforeEach(({ page }) => {
  replies.set(page, checkReplies(page, validate));
});

test.afterEach(async ({ page }, testInfo) => {
  if (!strictSchemas) {
    testInfo.annotations.push({ type: 'schema', description: 'backend without the api-2 trims: replies not validated' });
    return;
  }
  expect(replies.get(page).errors).toEqual([]);
});

/* A process whose command line names adblock-fast's CLI holds a rebuild job in `applying` (job.uc waits for it). */
function holdJobs() {
  guest(`sh -c 'sleep 900; :' /lib/adblock-fast/cli.uc >/dev/null 2>&1 & echo $! >/tmp/abfm-holder.pid`);
}
function releaseJobs() {
  guest('[ ! -s /tmp/abfm-holder.pid ] || kill "$(cat /tmp/abfm-holder.pid)" 2>/dev/null; rm -f /tmp/abfm-holder.pid; :');
}
const jobState = (page) => page.locator('#abfm-job-state');
async function waitTerminal(page, timeout = 480_000) {
  await expect(jobState(page)).toHaveAttribute('data-state', /^(applied|partial|failed)$/, { timeout });
  return jobState(page).getAttribute('data-state');
}

test.afterAll(() => {
  releaseJobs();
  guest('rm -f /tmp/dnsmasq.*.d/zz-abfm-broken.conf; uci -q revert adblock-fast || :; uci set adblock-fast.config.enabled=1; uci commit adblock-fast');
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
  // the same op again removes it (§8.4)
  await stageManual(page, 'allow', 'ads.example.test');
  await stageManual(page, 'allow', 'ads.example.test');
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

test('two tabs: staging syncs; an item staged while the dialog is open is not sent and stays pending', async ({ page, context }) => {
  const A = 'tab-a.up.example.test', B = 'tab-b.up.example.test', C = 'tab-c.up.example.test';
  await login(page, admin);
  await page.evaluate((k) => localStorage.removeItem(k), STORAGE);
  await page.reload();
  const applies = trackApply(page);
  const other = await context.newPage();
  await login(other, admin);
  await stageManual(page, 'block', A);
  await stageManual(page, 'block', B);
  // cross-tab sync through localStorage
  await expect(pendingRow(other, A)).toHaveAttribute('data-op', 'block');
  await expect(pendingRow(other, B)).toHaveAttribute('data-op', 'block');
  await page.getByRole('button', { name: 'Apply changes' }).click();
  const modal = page.locator('.modal');
  await expect(modal).toContainText(A);
  await stageManual(other, 'block', C);
  await expect(pendingRow(page, C)).toHaveCount(1);
  await modal.getByRole('button', { name: 'Apply' }).click();
  expect(await waitTerminal(page)).toBe('applied');
  const real = applies.filter((a) => !a.dry_run);
  expect(real).toHaveLength(1);
  expect(real[0].ops).toEqual([{ op: 'block', domain: A }, { op: 'block', domain: B }]);
  const results = page.getByRole('table', { name: 'Apply results' });
  for (const d of [A, B]) await expect(results.locator(`tr[data-domain="${d}"]`)).toHaveAttribute('data-result', 'ok');
  await expect(results.locator(`tr[data-domain="${C}"]`)).toHaveCount(0);
  for (const p of [page, other]) {
    await expect(pendingRow(p, C)).toHaveAttribute('data-op', 'block');
    await expect(pending(p).locator('tr[data-domain]')).toHaveCount(1);
  }
  // the other tab followed the job too
  await expect(jobState(other)).toHaveAttribute('data-state', 'applied', { timeout: 60_000 });
  await other.close();
  await page.getByRole('button', { name: 'Discard all' }).click();
});

test('a running job: shown when the page opens, polled only while visible, busy on Apply, resumed after reload', async ({ page }) => {
  holdJobs();
  try {
    const started = JSON.parse(guest(`ubus call luci.adblock-fast-monitor apply '{"ops":[{"op":"block","domain":"held.up.example.test"}],"confirm_rebuild":true}'`));
    expect(started.ok).toBe(true);
    const id = started.job_id;
    guestWait(`ubus call luci.adblock-fast-monitor job | grep -q '"state": "applying"'`, 60);
    const jobs = trackCalls(page, 'luci.adblock-fast-monitor', 'job');
    await login(page, admin);
    await page.evaluate((k) => localStorage.removeItem(k), STORAGE);
    await page.reload();
    // open the page while a job runs: the latest job is shown
    await expect(jobState(page)).toHaveAttribute('data-job', id);
    await expect(jobState(page)).toHaveAttribute('data-state', 'applying');
    await expect.poll(() => jobs.length, { timeout: 30_000 }).toBeGreaterThan(2);
    // hidden: no job polls
    await setVisibility(page, 'hidden');
    await page.waitForTimeout(3_000);
    const hidden = jobs.length;
    await page.waitForTimeout(10_000);
    expect(jobs.length).toBe(hidden);
    await setVisibility(page, 'visible');
    await expect.poll(() => jobs.length, { timeout: 10_000 }).toBeGreaterThan(hidden);
    // Apply while it runs: busy, the running job stays on screen, nothing staged is lost
    await stageManual(page, 'block', 'busy.up.example.test');
    await page.getByRole('button', { name: 'Apply changes' }).click();
    await page.locator('.modal').getByRole('button', { name: 'Apply' }).click();
    await expect(page.locator('.alert-message').filter({ hasText: 'Another change is being applied' })).toBeVisible();
    await expect(jobState(page)).toHaveAttribute('data-job', id);
    await expect(pendingRow(page, 'busy.up.example.test')).toHaveAttribute('data-op', 'block');
    await page.getByRole('button', { name: 'Discard all' }).click();

    // a batch applied from this page and reloaded while its job runs resumes
    releaseJobs();
    expect(await waitTerminal(page)).toBe('applied');
    holdJobs();
    await stageManual(page, 'block', 'resume.up.example.test');
    await page.getByRole('button', { name: 'Apply changes' }).click();
    await page.locator('.modal').getByRole('button', { name: 'Apply' }).click();
    await expect(jobState(page)).not.toHaveAttribute('data-job', id);
    await expect(jobState(page)).toHaveAttribute('data-state', /^(queued|applying)$/);
    const mine = await jobState(page).getAttribute('data-job');
    await page.reload();
    await expect(jobState(page)).toHaveAttribute('data-job', mine);
    expect(await page.evaluate((k) => JSON.parse(localStorage.getItem(k)).inflight.job_id, STORAGE)).toBe(mine);
    releaseJobs();
    expect(await waitTerminal(page)).toBe('applied');
    await expect(page.getByRole('table', { name: 'Apply results' }).locator('tr[data-domain="resume.up.example.test"]'))
      .toHaveAttribute('data-result', 'ok');
    await expect(pending(page).locator('tr[data-domain]')).toHaveCount(0);
    expect(await page.evaluate((k) => JSON.parse(localStorage.getItem(k)).inflight ?? null, STORAGE)).toBeNull();
  } finally {
    releaseJobs();
  }
  resetRules();
});

test('a job the router no longer knows returns its items with the reason', async ({ page }) => {
  await login(page, admin);
  await page.evaluate((k) => localStorage.setItem(k, JSON.stringify({ v: 2, items: [],
    inflight: { job_id: 'j0000000001-abcd', items: [{ op: 'block', domain: 'lost-job.example.test', ts: 1 }] } })), STORAGE);
  await page.reload();
  const row = pendingRow(page, 'lost-job.example.test');
  await expect(row).toHaveAttribute('data-op', 'block');
  await expect(row).toContainText('Last attempt: The job is no longer known');
  await page.getByRole('button', { name: 'Discard all' }).click();
});

test('no-op batch: one dry run, "Nothing to change", the item leaves', async ({ page }) => {
  guest('uci add_list adblock-fast.config.allowed_domain=noop.example.test; uci commit adblock-fast');
  try {
    await login(page, admin);
    const applies = trackApply(page);
    await stageManual(page, 'allow', 'noop.example.test');
    await page.getByRole('button', { name: 'Apply changes' }).click();
    await expect(page.locator('.alert-message').filter({ hasText: 'Nothing to change' })).toBeVisible();
    await expect(page.locator('.modal')).toBeHidden();
    expect(applies).toHaveLength(1);
    expect(applies[0].dry_run).toBe(true);
    await expect(pending(page).locator('tr[data-domain]')).toHaveCount(0);
  } finally {
    guest('uci -q del_list adblock-fast.config.allowed_domain=noop.example.test; uci commit adblock-fast');
  }
});

test('a rejected batch marks the item the server names (public suffix)', async ({ page }) => {
  await login(page, admin);
  const applies = trackApply(page);
  await stageManual(page, 'block', 'co.uk');
  await stageManual(page, 'block', 'fine.example.test');
  await page.getByRole('button', { name: 'Apply changes' }).click();
  await expect(page.locator('[data-error="public-suffix"]')).toContainText('co.uk');
  await expect(pendingRow(page, 'co.uk')).toContainText('Last attempt: Public suffix: rule would be too broad');
  await expect(pendingRow(page, 'fine.example.test')).not.toContainText('Last attempt');
  expect(applies.filter((a) => !a.dry_run)).toHaveLength(0);
  await page.getByRole('button', { name: 'Discard all' }).click();
});

test('save-only apply while adblock-fast is disabled: no confirmation, items skipped', async ({ page }) => {
  guest('uci set adblock-fast.config.enabled=0; uci commit adblock-fast');
  try {
    await login(page, admin);
    const applies = trackApply(page);
    await stageManual(page, 'block', 'saved.example.test');
    await page.getByRole('button', { name: 'Apply changes' }).click();
    expect(await waitTerminal(page, 60_000)).toBe('applied');
    await expect(page.locator('.modal')).toBeHidden();
    await expect(jobState(page)).toContainText('saved only (adblock-fast is disabled)');
    await expect(page.getByRole('table', { name: 'Apply results' }).locator('tr[data-domain="saved.example.test"]'))
      .toHaveAttribute('data-result', 'skipped');
    expect(applies.filter((a) => !a.dry_run)).toHaveLength(1);
    expect(applies.filter((a) => !a.dry_run)[0].confirm_rebuild).toBe(false);
    await expect(pending(page).locator('tr[data-domain]')).toHaveCount(0);
    expect(guest('uci -q get adblock-fast.config.blocked_domain')).toContain('saved.example.test');
  } finally {
    guest('uci set adblock-fast.config.enabled=1; uci commit adblock-fast');
  }
  resetRules();
});
