// T23 (docs/CONTRACT.md §8): the last-queries list is built in the browser
// from real dnsmasq log lines read with `log read`: decisions, the % blocked
// stat, text-only rendering of hostile log data, gaps, and no polling while
// the page is hidden (P2).
import { expect, test } from '@playwright/test';
import {
  admin, dnsQuery, ensureHealthy, fakeDnsmasq, guest, guestWait, login, queries, queryRow, seeQuery,
  setVisibility, trackLogReads, trackLogReplies
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

  // P4 hook: one `abfm-poll` measure per poll with the reply size and kept rows; no marks left behind
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
  }
  expect(perf.measures.at(-1).rows).toBeGreaterThan(0);

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

test('hostile log data is shown as text, never as HTML', async ({ page }) => {
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

test('a burst larger than the log window shows the exact number of missed entries', async ({ page }) => {
  const replies = trackLogReplies(page);
  await login(page, admin);
  await expect.poll(() => replies.length, { timeout: 30_000 }).toBeGreaterThan(1);
  await expect(page.locator('#abfm-missed')).toHaveAttribute('data-missed', '0');
  // ~5000 lines of 200 bytes: far more than the ring (and 900 lines) holds
  guest(`awk 'BEGIN { s = sprintf("%180s", ""); gsub(/ /, "x", s); for (i = 0; i < 5000; i++) print "abfm-burst " i " " s }' | logger -t abfm-burst`);
  await expect.poll(async () => Number(await page.locator('#abfm-missed').getAttribute('data-missed')), { timeout: 60_000 })
    .toBeGreaterThan(0);
  // let the page settle on the new head, then compare with the ids it never received
  await page.waitForTimeout(5_000);
  const seen = new Set(replies.flat());
  const ids = [...seen].sort((a, b) => a - b);
  let gap = 0;
  for (let id = ids[0]; id <= ids[ids.length - 1]; id++) if (!seen.has(id)) gap++;
  expect(gap).toBeGreaterThan(0);
  await expect(page.locator('#abfm-missed')).toHaveAttribute('data-missed', String(gap));
  await expect(page.locator('#abfm-missed')).toContainText(`${gap} log entries missed`);
});

test('P2: a hidden page sends no log reads for 60 s and resumes when visible', async ({ page }) => {
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
