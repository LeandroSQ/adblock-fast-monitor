// SPDX-License-Identifier: Apache-2.0
// T23 (docs/CONTRACT.md §8): the last-queries list is built in the browser
// from real dnsmasq log lines read with `log read`: decisions, the % blocked
// stat, text-only rendering of hostile log data, gaps, dnsmasq's lost lines,
// one read in flight, back-off, idle pause, and no polling while the page is
// hidden (P2).
import { expect, test } from '@playwright/test';
import {
  admin, dnsQuery, ensureHealthy, fakeDnsmasq, guest, guestWait, holdLogReads, isUbus, login, queries, queryRow,
  seeQuery, setVisibility, trackLogReads, trackLogReplies, ubusCalls
} from './lib/guest.mjs';

test.describe.configure({ mode: 'serial' });

test.beforeAll(() => ensureHealthy());

test('real queries from a LAN client: decisions, sources, header and toggles', async ({ page }) => {
  const reads = trackLogReads(page);
  await login(page, admin);
  await expect(page.locator('#abfm-state')).toHaveAttribute('data-state', 'healthy');
  await expect(page.locator('#abfm-disclaimer')).toContainText('read the whole system log');
  await expect(page.locator('#abfm-disclaimer')).toContainText('only to administrators');
  // informational note from info.warnings, dismissible
  const note = page.locator('[data-warning="query-logging-active"]');
  await expect(note).toBeVisible();
  await note.getByRole('button', { name: 'Dismiss note' }).click();
  await expect(note).toHaveCount(0);
  await expect(page.locator('#abfm-buffer-hint')).toContainText('System log buffer size');
  await expect(page.locator('#abfm-buffer-hint')).toContainText(/\(\d+ KiB, shared by every service\)/);
  // first read fetches the most the contract allows; LuCI's call shape
  await expect.poll(() => reads.length).toBeGreaterThan(0);
  expect(reads[0].args).toEqual({ lines: 900, stream: false, oneshot: true });

  const blocked = await seeQuery(page, 'ads.example.test', { decision: 'blocked' });
  await expect(blocked).toContainText('Blocked (dnsmasq rule)');
  await expect(blocked).toContainText('NXDOMAIN');
  await expect(blocked.locator('td').nth(2)).toHaveText('A');
  await expect(blocked.locator('time')).toHaveText(/^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d$/);
  const allowed = await seeQuery(page, 'www.up.example.test', { decision: 'allowed' });
  await expect(allowed).toContainText('192.0.2.10');
  await expect(allowed).toContainText(/Allowed \((upstream|cache)\)/);
  // the second identical query is answered from dnsmasq's cache
  await dnsQuery('www.up.example.test');
  await expect(queries(page).locator('tr[data-domain="www.up.example.test"]').filter({ hasText: 'Allowed (cache)' }).first())
    .toBeVisible({ timeout: 30_000 });

  // polls are incremental after the first read, within 16..900
  await expect.poll(() => reads.length, { timeout: 30_000 }).toBeGreaterThan(3);
  for (const r of reads.slice(1)) {
    expect(r.args.lines).toBeGreaterThanOrEqual(16);
    expect(r.args.lines).toBeLessThanOrEqual(900);
  }

  // P4 hook: one `abfm-poll` measure per poll with the reply size, kept rows and DOM rows changed; no marks left behind
  const perf = await page.evaluate(() => ({
    measures: performance.getEntriesByName('abfm-poll').map((e) => ({ d: e.duration, ...e.detail })),
    marks: performance.getEntriesByName('abfm-poll-start').length
  }));
  expect(perf.marks).toBe(0);
  expect(perf.measures.length).toBeGreaterThan(2);
  expect(perf.measures.length).toBeLessThanOrEqual(reads.length);
  expect(perf.measures[0].entries).toBeGreaterThan(0);
  expect(perf.measures[0].entries).toBeLessThanOrEqual(900);
  for (const mm of perf.measures) {
    expect(mm.d).toBeGreaterThanOrEqual(0);
    expect(mm.rows).toBeGreaterThanOrEqual(0);
    expect(mm.rows).toBeLessThanOrEqual(500);
    expect(mm.changed).toBeGreaterThanOrEqual(0);
  }
  expect(perf.measures.at(-1).rows).toBeGreaterThan(0);
  // polls that bring new queries create rows; a poll that brings nothing new touches no row
  expect(perf.measures.some((mm) => mm.changed > 0)).toBe(true);
  await expect.poll(() => page.evaluate(() => performance.getEntriesByName('abfm-poll').slice(-3)
    .some((e) => e.detail.changed === 0)), { timeout: 30_000 }).toBe(true);

  // an existing row keeps its DOM node across polls (no full rebuild): focus stays on its button
  const button = queryRow(page, 'ads.example.test').getByRole('button', { name: 'Allow ads.example.test' });
  await button.focus();
  await dnsQuery('focus-keeper.up.example.test');
  await expect(queryRow(page, 'focus-keeper.up.example.test')).toBeVisible({ timeout: 30_000 });
  expect(await page.evaluate(() => document.activeElement?.getAttribute('aria-label'))).toBe('Allow ads.example.test');

  // client column is off by default; router queries hidden by default
  await expect(queries(page).getByRole('columnheader', { name: 'Client' })).toHaveCount(0);
  await page.getByLabel('Show client column').check();
  await expect(queries(page).getByRole('columnheader', { name: 'Client' })).toHaveCount(1);
  await expect(queryRow(page, 'ads.example.test')).toContainText('10.0.2.2');
  await page.getByLabel('Show client column').uncheck();
  guest('nslookup router-only.up.example.test 127.0.0.1 >/dev/null 2>&1 || :');
  await page.getByLabel('Show router queries').check();
  await expect(queries(page).locator('tr[data-domain="router-only.up.example.test"][data-router="true"]').first())
    .toBeVisible({ timeout: 30_000 });
  await page.getByLabel('Show router queries').uncheck();
  await expect(queries(page).locator('tr[data-domain="router-only.up.example.test"]')).toHaveCount(0);

  // domain filter
  await page.getByLabel('Filter domains').fill('ADS.example');
  await expect(queryRow(page, 'ads.example.test')).toBeVisible();
  await expect(queries(page).locator('tr[data-domain="www.up.example.test"]')).toHaveCount(0);
  await page.getByLabel('Filter domains').fill('nomatch-zzz');
  await expect(queries(page).locator('tr.placeholder')).toContainText('No queries match the filter.');
});

test('% blocked over the kept rows and since-page-opened counters', async ({ page }) => {
  // a fresh log ring: the kept rows are exactly the queries below
  guest('/etc/init.d/log restart; /etc/init.d/dnsmasq restart');
  guestWait('pidof dnsmasq >/dev/null && nslookup a.up.example.test 127.0.0.1 >/dev/null 2>&1', 60);
  const reads = trackLogReads(page);
  await login(page, admin);
  // the first read (the page's starting point) has completed once a second one is sent
  await expect.poll(() => reads.length, { timeout: 30_000 }).toBeGreaterThan(1);
  await seeQuery(page, 'ads.example.test', { decision: 'blocked' });
  const stat = page.locator('[data-stat="blocked_pct"]');
  const since = page.locator('[data-stat="since_open"]');
  await expect(since).toContainText(/^Since page opened\s*1 queries, 1 blocked, 0 allowed$/);
  for (const name of ['telemetry.example.test', 'metrics.example.test']) await seeQuery(page, name, { decision: 'blocked' });
  await seeQuery(page, 'pct.up.example.test', { decision: 'allowed' });
  await expect(stat).toContainText('75.0 %');
  await expect(stat).toContainText(/4 queries over \d+ (s|min)/);
  await expect(since).toContainText('4 queries, 3 blocked, 1 allowed');
});

test('T27: hostile log data is shown as text, never as HTML', async ({ page }) => {
  await login(page, admin);
  await page.evaluate(() => { delete window.__x; delete window.__y; delete window.__z; });
  fakeDnsmasq([
    '900001 192.0.2.66/40001 query[PTR] 5.113.0.203.in-addr.arpa from 192.0.2.66',
    '900001 192.0.2.66/40001 reply 5.113.0.203.in-addr.arpa is <img/src=x/onerror=window.__x=1>',
    '900002 192.0.2.66/40002 query[A] xss.example.test from 192.0.2.66',
    '900002 192.0.2.66/40002 reply xss.example.test is "><svg/onload=window.__y=1>.example.test',
    '900003 192.0.2.66/40003 query[A] <b/onclick=window.__z=1>bold</b>.example.test from 192.0.2.66'
  ]);
  const ptr = queryRow(page, '5.113.0.203.in-addr.arpa');
  await expect(ptr).toBeVisible({ timeout: 30_000 });
  await expect(ptr.locator('td.abfm-answer')).toHaveText('<img/src=x/onerror=window.__x=1>');
  const xss = queryRow(page, 'xss.example.test');
  await expect(xss.locator('td.abfm-answer')).toHaveText('"><svg/onload=window.__y=1>.example.test');
  await expect(page.locator('#abfm-overview img, #abfm-overview svg, #abfm-overview b')).toHaveCount(0);
  await expect(page.locator('img[src="x"]')).toHaveCount(0);
  // the malformed name never becomes a row
  await expect(queries(page).locator('tr[data-domain*="<"]')).toHaveCount(0);
  await expect(queries(page)).not.toContainText('bold</b>');
  // give an injected handler every chance to run
  await page.waitForTimeout(2_000);
  expect(await page.evaluate(() => [typeof window.__x, typeof window.__y, typeof window.__z]))
    .toEqual(['undefined', 'undefined', 'undefined']);
});

// The page's read is held while the burst is written, so its reply and the
// one refetch both see the ring after the burst: the ids the page never
// received are exactly the missed entries (no race with the logger).
test('T29: a burst larger than the log window shows the exact number of missed entries', async ({ page }) => {
  const replies = trackLogReplies(page);
  const reads = await holdLogReads(page);
  await login(page, admin);
  await expect.poll(() => replies.length, { timeout: 30_000 }).toBeGreaterThan(1);
  await expect(page.locator('#abfm-missed')).toHaveAttribute('data-missed', '0');
  reads.hold();
  await expect.poll(() => reads.held.length, { timeout: 30_000 }).toBeGreaterThan(0);
  const before = replies.length;
  // ~5000 lines of 200 bytes: far more than the ring (and 900 lines) holds; logger has exited when this returns
  guest(`awk 'BEGIN { s = sprintf("%180s", ""); gsub(/ /, "x", s); for (i = 0; i < 5000; i++) print "abfm-burst " i " " s }' | logger -t abfm-burst`);
  await reads.release();
  await expect.poll(() => replies.length - before, { timeout: 30_000 }).toBeGreaterThanOrEqual(1);
  await expect.poll(async () => Number(await page.locator('#abfm-missed').getAttribute('data-missed')), { timeout: 30_000 })
    .toBeGreaterThan(0);
  const seen = new Set(replies.flat());
  const ids = [...seen].sort((a, b) => a - b);
  let gap = 0;
  for (let id = ids[0]; id <= ids[ids.length - 1]; id++) if (!seen.has(id)) gap++;
  expect(gap).toBeGreaterThan(0);
  await expect(page.locator('#abfm-missed')).toHaveAttribute('data-missed', String(gap));
  await expect(page.locator('#abfm-missed')).toContainText(`${gap} log entries missed`);
  await expect(page.locator('#abfm-missed')).toHaveAttribute('data-paused', '0');
});

test('entries overwritten while the page was hidden are reported as paused, not missed', async ({ page }) => {
  const replies = trackLogReplies(page);
  const reads = trackLogReads(page);
  await login(page, admin);
  await expect.poll(() => replies.length, { timeout: 30_000 }).toBeGreaterThan(1);
  const missed = await page.locator('#abfm-missed').getAttribute('data-missed');
  await setVisibility(page, 'hidden');
  // the poll that may be in flight has answered once no read is outstanding
  await expect.poll(() => reads.length === replies.length, { timeout: 10_000 }).toBe(true);
  const quiet = replies.length;
  guest(`awk 'BEGIN { s = sprintf("%180s", ""); gsub(/ /, "x", s); for (i = 0; i < 5000; i++) print "abfm-hidden " i " " s }' | logger -t abfm-hidden`);
  expect(replies.length).toBe(quiet);
  const before = reads.length;
  await setVisibility(page, 'visible');
  await expect.poll(async () => Number(await page.locator('#abfm-missed').getAttribute('data-paused')), { timeout: 30_000 })
    .toBeGreaterThan(0);
  await expect(page.locator('#abfm-missed')).toHaveAttribute('data-missed', missed ?? '0');
  await expect(page.locator('#abfm-paused-gap')).toContainText('while updates were paused');
  // one right-sized request on return (16..900), plus at most one refetch
  const first = reads[before].args.lines;
  expect(first).toBeGreaterThanOrEqual(16);
  expect(first).toBeLessThanOrEqual(900);
});

test("dnsmasq's lost-entry reports count as missed entries (§8.3)", async ({ page }) => {
  await login(page, admin);
  await seeQuery(page, 'before-lost.up.example.test');
  const missed = Number(await page.locator('#abfm-missed').getAttribute('data-missed'));
  fakeDnsmasq(['overflow: 12 log entries lost']);
  await expect(page.locator('#abfm-missed')).toHaveAttribute('data-missed', String(missed + 12), { timeout: 30_000 });
  await expect(page.locator('#abfm-missed')).toContainText(`${missed + 12} log entries missed`);
});

test('never two log reads in flight, even when the page is hidden and shown again during a slow read', async ({ page }) => {
  let inFlight = 0, maxInFlight = 0, slow = false;
  await page.route((url) => isUbus(url), async (route) => {
    if (!ubusCalls(route.request()).some(([o, m]) => o === 'log' && m === 'read')) return route.continue();
    inFlight++;
    maxInFlight = Math.max(maxInFlight, inFlight);
    try {
      if (slow) await new Promise((resolve) => setTimeout(resolve, 6_000));
      const response = await route.fetch();
      await route.fulfill({ response });
    } finally {
      inFlight--;
    }
  });
  const reads = trackLogReads(page);
  await login(page, admin);
  await expect.poll(() => reads.length, { timeout: 30_000 }).toBeGreaterThan(1);
  slow = true;
  await expect.poll(() => inFlight, { timeout: 10_000 }).toBe(1);
  for (let i = 0; i < 2; i++) {
    await setVisibility(page, 'hidden');
    await setVisibility(page, 'visible');
  }
  // LuCI's poll loop ticks every second: give the re-added poll several chances to start a second read
  await expect.poll(() => reads.length, { timeout: 15_000 }).toBeGreaterThan(3);
  slow = false;
  expect(maxInFlight).toBe(1);
  await expect(page.locator('#abfm-state')).toHaveAttribute('data-state', 'healthy');
  await expect(page.locator('#abfm-log-stalled')).toHaveCount(0);
  await page.unrouteAll({ behavior: 'wait' });
});

test('failed log reads back off, then recover', async ({ page }) => {
  const reads = trackLogReads(page);
  await login(page, admin);
  await seeQuery(page, 'before-backoff.up.example.test');
  try {
    guest('/etc/init.d/log stop');
    guestWait('! ubus list log >/dev/null 2>&1', 30);
    const start = reads.length;
    // a read in flight when logd stopped may only fail at uhttpd's ubus timeout
    await expect(page.locator('#abfm-retrying')).toBeVisible({ timeout: 90_000 });
    const failed = reads.length;
    // without back-off a 2 s poll makes 15 reads in 30 s; with it, at most 5
    await page.waitForTimeout(30_000);
    expect(failed - start).toBeLessThanOrEqual(3);
    expect(reads.length - failed).toBeLessThanOrEqual(5);
    expect(reads.length - failed).toBeGreaterThanOrEqual(1);
    // the rows already shown stay
    await expect(queryRow(page, 'before-backoff.up.example.test')).toBeVisible();
  } finally {
    guest('/etc/init.d/log start');
  }
  guestWait('ubus list log >/dev/null 2>&1', 30);
  ensureHealthy();
  await expect(page.locator('#abfm-retrying')).toHaveCount(0, { timeout: 60_000 });
  await seeQuery(page, 'after-backoff.up.example.test');
});

test('no input for 15 minutes pauses polling until the next input', async ({ page }) => {
  await page.clock.install();
  const reads = trackLogReads(page);
  await login(page, admin);
  await expect.poll(() => reads.length, { timeout: 30_000 }).toBeGreaterThan(1);
  await page.clock.fastForward('16:00');
  await expect(page.locator('#abfm-paused')).toBeVisible({ timeout: 30_000 });
  const paused = reads.length;
  await page.clock.fastForward('01:00');
  await page.clock.runFor(5_000);
  expect(reads.length).toBe(paused);
  await page.mouse.move(10, 10);
  await page.mouse.move(40, 40);
  await expect(page.locator('#abfm-paused')).toHaveCount(0, { timeout: 30_000 });
  await expect.poll(() => reads.length, { timeout: 30_000 }).toBeGreaterThan(paused);
});

test('T28: P2: a hidden page sends no log reads for 60 s and resumes when visible', async ({ page }) => {
  const reads = trackLogReads(page);
  await login(page, admin);
  await expect.poll(() => reads.length, { timeout: 30_000 }).toBeGreaterThan(2);
  await setVisibility(page, 'hidden');
  // an in-flight poll may still complete; count from a quiet point
  await page.waitForTimeout(3_000);
  const before = reads.length;
  await dnsQuery('hidden.up.example.test');
  await page.waitForTimeout(60_000);
  expect(reads.length - before).toBe(0);
  await setVisibility(page, 'visible');
  await expect.poll(() => reads.length - before, { timeout: 10_000 }).toBeGreaterThan(0);
  await expect(queryRow(page, 'hidden.up.example.test')).toBeVisible({ timeout: 30_000 });
});
