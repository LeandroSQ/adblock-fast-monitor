// SPDX-License-Identifier: Apache-2.0
// T23 (docs/CONTRACT.md §8): the last-queries list is built in the browser
// from real dnsmasq log lines read with `log read`: decisions with their
// source, the blocked statistics, text-only rendering of hostile log data,
// gaps, dnsmasq's lost lines, one read in flight, back-off, idle pause, no
// polling while the page is hidden (P2), and the newest 50 rows only.
import { expect, test } from '@playwright/test';
import {
  admin, dnsQuery, ensureHealthy, fakeDnsmasq, guest, guestWait, holdLogReads, isUbus, login, queries, queryRow,
  seeQuery, setVisibility, trackLogReads, trackLogReplies, ubusCalls
} from './lib/guest.mjs';

test.describe.configure({ mode: 'serial' });

test.beforeAll(() => ensureHealthy());

test('real queries from a LAN client: decisions, sources, the statistics and the query-logging line', async ({ page }) => {
  const reads = trackLogReads(page);
  await login(page, admin);
  // healthy: no state notice, one admin-only line, the query-logging line at the bottom
  await expect(page.locator('#abfm-state')).toHaveAttribute('data-state', 'healthy');
  await expect(page.locator('#abfm-state')).toBeEmpty();
  await expect(page.locator('#abfm-disclaimer')).toHaveText('For administrators only: this page can read the whole system log.');
  await expect(page.locator('#abfm-logging')).toContainText('Query logging is on');
  await expect(page.locator('#abfm-logging').getByRole('button', { name: 'Turn off query logging' })).toBeVisible();
  // the informational warning is not repeated as a note
  await expect(page.locator('[data-warning="query-logging-active"]')).toHaveCount(0);
  await expect(page.locator('#abfm-notes')).toBeEmpty();
  // first read fetches the most the contract allows; LuCI's call shape
  await expect.poll(() => reads.length).toBeGreaterThan(0);
  expect(reads[0].args).toEqual({ lines: 900, stream: false, oneshot: true });

  // three columns and the action, nothing else
  await expect(queries(page).getByRole('columnheader')).toHaveText(['Time', 'Domain', 'Result', 'Action']);
  const blocked = await seeQuery(page, 'ads.example.test', { decision: 'blocked' });
  await expect(blocked.locator('td').nth(2)).toHaveText('Blocked (dnsmasq rule)');
  await expect(blocked.locator('time')).toHaveText(/^\d\d:\d\d:\d\d$/);
  const allowed = await seeQuery(page, 'www.up.example.test', { decision: 'allowed' });
  await expect(allowed.locator('td').nth(2)).toHaveText(/^Allowed \((upstream|cache)\)$/);
  // the second identical query is answered from dnsmasq's cache
  await dnsQuery('www.up.example.test');
  await expect(queries(page).locator('tr[data-domain="www.up.example.test"]').filter({ hasText: 'Allowed (cache)' }).first())
    .toBeVisible({ timeout: 30_000 });
  // no answers and no client addresses on the page
  await expect(page.locator('#abfm-overview')).not.toContainText('192.0.2.10');
  await expect(page.locator('#abfm-overview')).not.toContainText('10.0.2.2');

  // the statistics: LuCI's progress bar and one sentence
  const stat = page.locator('[data-stat="blocked_pct"]');
  await expect(stat.getByRole('progressbar', { name: 'Blocked queries' })).toHaveAttribute('title', /^\d+ %$/);
  await expect(stat).toContainText(/^Blocked|\d+ of \d+ queries blocked in the last \d+ (s|min)/);

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

  // router queries (127.0.0.1) are never listed: a LAN query sent after one shows, the router's does not
  guest('nslookup router-only.up.example.test 127.0.0.1 >/dev/null 2>&1 || :');
  await seeQuery(page, 'after-router.up.example.test');
  await expect(queries(page).locator('tr[data-domain="router-only.up.example.test"]')).toHaveCount(0);
});

test('the blocked share is computed over the answered queries the list keeps', async ({ page }) => {
  // a fresh log ring: the kept rows are exactly the queries below
  guest('/etc/init.d/log restart; /etc/init.d/dnsmasq restart');
  guestWait('pidof dnsmasq >/dev/null && nslookup a.up.example.test 127.0.0.1 >/dev/null 2>&1', 60);
  const reads = trackLogReads(page);
  await login(page, admin);
  // the first read (the page's starting point) has completed once a second one is sent
  await expect.poll(() => reads.length, { timeout: 30_000 }).toBeGreaterThan(1);
  const stat = page.locator('[data-stat="blocked_pct"]');
  const bar = stat.getByRole('progressbar', { name: 'Blocked queries' });
  await seeQuery(page, 'ads.example.test', { decision: 'blocked' });
  await expect(stat).toContainText(/1 of 1 queries blocked in the last \d+ s/);
  await expect(bar).toHaveAttribute('title', '100 %');
  for (const name of ['telemetry.example.test', 'metrics.example.test']) await seeQuery(page, name, { decision: 'blocked' });
  await seeQuery(page, 'pct.up.example.test', { decision: 'allowed' });
  await expect(stat).toContainText(/3 of 4 queries blocked in the last \d+ (s|min)/);
  await expect(bar).toHaveAttribute('title', '75 %');
  await expect(bar).toHaveAttribute('aria-valuenow', '75');
});

test('T27: hostile log data never becomes HTML', async ({ page }) => {
  await login(page, admin);
  await page.evaluate(() => { delete window.__x; delete window.__y; delete window.__z; });
  fakeDnsmasq([
    '900001 192.0.2.66/40001 query[PTR] 5.113.0.203.in-addr.arpa from 192.0.2.66',
    '900001 192.0.2.66/40001 reply 5.113.0.203.in-addr.arpa is <img/src=x/onerror=window.__x=1>',
    '900002 192.0.2.66/40002 query[A] xss.example.test from 192.0.2.66',
    '900002 192.0.2.66/40002 reply xss.example.test is "><svg/onload=window.__y=1>.example.test',
    '900003 192.0.2.66/40003 query[A] <b/onclick=window.__z=1>bold</b>.example.test from 192.0.2.66'
  ]);
  // the rows are listed (answers are not shown on the page at all) ...
  await expect(queryRow(page, '5.113.0.203.in-addr.arpa')).toBeVisible({ timeout: 30_000 });
  await expect(queryRow(page, 'xss.example.test')).toHaveText(/xss\.example\.test\s*Allowed \(upstream\)/);
  // ... and nothing of the hostile strings became markup
  await expect(page.locator('#abfm-overview img, #abfm-overview svg, #abfm-overview b')).toHaveCount(0);
  await expect(page.locator('img[src="x"]')).toHaveCount(0);
  await expect(page.locator('#abfm-overview')).not.toContainText('onerror');
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
  await expect(page.locator('#abfm-missed')).toContainText(`${gap} log entries were missed`);
  await expect(page.locator('#abfm-missed')).toContainText(/\(\d+ KiB, shared by every service\)/);
  await expect(page.locator('#abfm-missed')).toContainText('System log buffer size');
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
  await expect(page.locator('#abfm-missed')).toContainText(`${missed + 12} log entries were missed`);
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

/* `count` fake dnsmasq queries (query + answer lines) named <prefix>-NNN, oldest first. */
function fakeQueries(prefix, from, count, serial) {
  const c = '192.0.2.68';
  const lines = [];
  for (let i = from; i < from + count; i++) {
    const n = `${prefix}-${String(i).padStart(3, '0')}.example.test`;
    lines.push(`${serial + i} ${c}/${2000 + i} query[A] ${n} from ${c}`, `${serial + i} ${c}/${2000 + i} reply ${n} is 192.0.2.10`);
  }
  fakeDnsmasq(lines);
}
const domains = (page) => queries(page).locator('tr[data-domain]').evaluateAll((trs) => trs.map((t) => t.getAttribute('data-domain')));
const name = (prefix, i) => `${prefix}-${String(i).padStart(3, '0')}.example.test`;

test('the list shows the newest 50 queries, newest first, and shifts as queries arrive', async ({ page }) => {
  await login(page, admin);
  fakeQueries('newest', 0, 120, 940000);
  await expect.poll(async () => (await domains(page))[0], { timeout: 30_000 }).toBe(name('newest', 119));
  expect(await domains(page)).toEqual(Array.from({ length: 50 }, (_, i) => name('newest', 119 - i)));
  fakeQueries('newest', 120, 3, 940000);
  await expect.poll(async () => (await domains(page))[0], { timeout: 30_000 }).toBe(name('newest', 122));
  expect((await domains(page)).slice(0, 4)).toEqual([122, 121, 120, 119].map((i) => name('newest', i)));
  // the list stays bounded in the DOM; there is no paging, filter or client column
  await expect(queries(page).locator('tr[data-domain]')).toHaveCount(50);
  await expect(page.locator('#abfm-overview input')).toHaveCount(0);
});

test('keyboard focus follows its row while the list shifts, and leaves the table with it', async ({ page }) => {
  await login(page, admin);
  fakeQueries('fshift', 0, 10, 960000);
  await expect.poll(async () => (await domains(page))[0], { timeout: 30_000 }).toBe(name('fshift', 9));
  const label = `Block ${name('fshift', 5)}`;
  await queryRow(page, name('fshift', 5)).getByRole('button', { name: label }).focus();
  const focused = () => page.evaluate(() => ({
    label: document.activeElement?.getAttribute('aria-label') ?? null,
    inTable: !!document.querySelector('#abfm-queries table')?.contains(document.activeElement)
  }));
  fakeQueries('fshift', 10, 3, 960000);
  await expect.poll(async () => (await domains(page))[0], { timeout: 30_000 }).toBe(name('fshift', 12));
  expect((await domains(page)).indexOf(name('fshift', 5))).toBe(7);
  expect(await focused()).toEqual({ label, inTable: true });
  // 50 newer queries push the row out of the list: focus does not land on another domain's button
  fakeQueries('fshift', 13, 50, 960000);
  await expect.poll(async () => (await domains(page))[0], { timeout: 30_000 }).toBe(name('fshift', 62));
  expect((await focused()).inTable).toBe(false);
});

// P4 regression guard (docs/performance.md): synthetic dnsmasq lines written
// with `logger` in the guest at ~50 and then ~200 queries/s, so every poll
// brings more than a page of new queries and the whole 50-row page shifts
// (≈ 300- and 900-entry replies, like the gate's two load rates). Chromium
// runs under the gate's 4x CPU throttle, and every `abfm-poll` measure since
// the page opened counts (first render, both rates, the polls in between).
// Each measure spans the reply's arrival to the next rendered frame.
// This Chromium runs in the Linux container, not on the macOS host of the
// run of record (docs/performance.md → P4): its median poll is about 20 %
// faster there, but its tail is noisier, because it shares the container's
// CPUs with the TCG guest that also writes the load. So the p95 is held to
// the budget and the median to a tighter bound, which a page that rebuilds
// or restyles its rows, or a poll frame that waits for the frame clock, fails.
const P4_P95_MS = 20;
const P4_P50_MS = 12;
test(`P4 guard: abfm-poll p95 <= ${P4_P95_MS} ms and median <= ${P4_P50_MS} ms over every poll while the page shifts at ~50 and ~200 qps, 4x CPU throttle`, async ({ page }, testInfo) => {
  const load = (rate, serial) => [
    `rm -f /tmp/abfm-load-*; touch /tmp/abfm-load-${rate}`,
    `( s=${serial}; while [ -f /tmp/abfm-load-${rate} ]; do awk -v s=$s 'BEGIN { for (k = 0; k < ${rate}; k++) { n = s + k; h = n " 192.0.2.50/" (1024 + k % 60000) " "; print h "query[A] q" n ".load.example.test from 192.0.2.50"; if (k % 4 == 0) print h "config q" n ".load.example.test is NXDOMAIN"; else print h "reply q" n ".load.example.test is 192.0.2.10" } }' | logger -t 'dnsmasq[1]'; s=$((s + ${rate})); sleep 1; done ) </dev/null >/dev/null 2>&1 &`
  ].join('\n');
  const polls = () => page.evaluate(() => performance.getEntriesByName('abfm-poll')
    .map((e) => ({ d: e.duration, ...e.detail })));
  const pct = (xs, p) => xs[Math.ceil(p * xs.length) - 1];
  try {
    const cdp = await page.context().newCDPSession(page);
    await cdp.send('Emulation.setCPUThrottlingRate', { rate: 4 });
    guest(load(50, 3000000));
    await login(page, admin);
    // the list fills (500 rows) and the page holds 50 rows: from here on a poll must create nothing
    await expect.poll(async () => (await polls()).filter((m) => m.rows >= 500 && m.shown === 50).length,
      { timeout: 60_000 }).toBeGreaterThan(0);
    await page.evaluate(() => {
      window.abfmRows = [...document.querySelectorAll('#abfm-queries tr[data-domain]')];
      window.abfmStats = [...document.querySelectorAll('#abfm-stats .cbi-progressbar, #abfm-stats [data-stat] p')];
    });
    const filled = (await polls()).length;
    await expect.poll(async () => (await polls()).length, { timeout: 120_000 }).toBeGreaterThanOrEqual(filled + 20);
    guest(load(200, 4000000));
    await expect.poll(async () => (await polls()).filter((m) => m.entries >= 810).length,
      { timeout: 120_000 }).toBeGreaterThanOrEqual(20);
    guest('rm -f /tmp/abfm-load-*');

    const m = await polls();
    const d = m.map((x) => x.d).sort((a, b) => a - b);
    const loaded = m.slice(filled);
    const summary = (xs) => {
      const v = xs.map((x) => x.d).sort((a, b) => a - b);
      return `n ${v.length} p50 ${pct(v, 0.5).toFixed(1)} p95 ${pct(v, 0.95).toFixed(1)} max ${v.at(-1).toFixed(1)} ms`;
    };
    const text = `abfm-poll, every poll: ${summary(m)}; first render ${m[0].d.toFixed(1)} ms; ` +
      `~50 qps: ${summary(loaded.filter((x) => x.entries < 810))}; ~200 qps (>= 810 entries): ${summary(loaded.filter((x) => x.entries >= 810))}`;
    console.log(`P4 guard: ${text}`);
    console.log(`P4 guard polls [ms entries changed]: ${m.map((x) => `${x.d.toFixed(1)} ${x.entries} ${x.changed}`).join(', ')}`);
    testInfo.annotations.push({ type: 'P4', description: text });

    // one page in the DOM; every loaded poll rewrote it in place, creating nothing
    for (const x of m) {
      expect(x.shown).toBeLessThanOrEqual(50);
      expect(x.changed).toBeLessThanOrEqual(50);
    }
    for (const x of loaded)
      expect(x.created).toBe(0);
    expect(loaded.filter((x) => x.changed === 50).length).toBeGreaterThanOrEqual(0.8 * loaded.length);
    expect(await page.evaluate(() => {
      const now = [...document.querySelectorAll('#abfm-queries tr[data-domain]')];
      const stats = [...document.querySelectorAll('#abfm-stats .cbi-progressbar, #abfm-stats [data-stat] p')];
      return now.length === 50 && now.every((tr, i) => tr === window.abfmRows[i]) &&
        stats.length === 2 && stats.every((n, i) => n === window.abfmStats[i]);
    })).toBe(true);
    expect(pct(d, 0.95)).toBeLessThanOrEqual(P4_P95_MS);
    expect(pct(d, 0.5)).toBeLessThanOrEqual(P4_P50_MS);
  } finally {
    guest('rm -f /tmp/abfm-load-*');
  }
});
