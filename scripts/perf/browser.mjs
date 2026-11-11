#!/usr/bin/env node
// SPDX-License-Identifier: Apache-2.0
// Headless-browser side of the P0 harness (docs/performance.md, CONTRACT §11
// P2/P3/P4). Drives the real LuCI page of the guest with Playwright (Chromium),
// logged in as the admin, and records every request the page makes.
//
//   node scripts/perf/browser.mjs hold --out FILE --ready FILE --stop FILE [--max-s 900]
//     Opens the page and keeps it visible until FILE --stop exists (P3/P4).
//     --ready is created once the page has rendered and made ≥ 2 /ubus
//     requests after its initial load (or after 30 s without any). Before exiting it reads the
//     page's `abfm-poll` performance measures and times the querylog module
//     on a real `log read {lines:900}` reply fetched by the page (P4).
//   node scripts/perf/browser.mjs p2 --out FILE [--hidden-s 60] [--closed-s 60]
//     Visible control (12 s), hidden (--hidden-s), visible again (resume
//     check), page closed (--closed-s); counts requests in each phase (P2).
//
// Environment (exported by scripts/guest/run-guest-tests.sh): GUEST_HTTP_URL,
// GUEST_ROOT_PASSWORD; optional ABFM_PERF_PAGE (default the overview path)
// and, for router-side tick deltas in p2, GUEST_SSH_KEY/GUEST_SSH_PORT/GUEST_RUN_DIR.
//
// UI hook (coordinated with the UI unit, docs/performance.md → P4): the page
// wraps each poll's parse + classify + render in a performance measure named
// `abfm-poll`, e.g. performance.measure('abfm-poll', {start: t0, detail:
// {entries: reply.log.length, rows: shownRows}}). Without it, P4 falls back to
// the querylog module timed in the page (parse + classify only).
import { execFileSync } from 'node:child_process';
import { existsSync, writeFileSync } from 'node:fs';
import { chromium } from '@playwright/test';

const [mode, ...rest] = process.argv.slice(2);
const opt = {};
for (let i = 0; i < rest.length; i += 2) opt[rest[i].replace(/^--/, '')] = rest[i + 1];
const base = process.env.GUEST_HTTP_URL;
const password = process.env.GUEST_ROOT_PASSWORD;
const path = process.env.ABFM_PERF_PAGE || '/cgi-bin/luci/admin/services/adblock-fast-monitor/overview';
const MARK = 'abfm-poll';
if (!['hold', 'p2'].includes(mode) || !opt.out || !base || !password) {
  console.error('usage: browser.mjs hold|p2 --out FILE ... (GUEST_HTTP_URL and GUEST_ROOT_PASSWORD required)');
  process.exit(2);
}
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const t0 = Date.now();
const rel = () => Date.now() - t0;
const result = { mode, page: path, started_at: new Date(t0).toISOString(), errors: [] };

// One record per request of the monitored context. JSON-RPC bodies (single or
// batched) are reduced to [object, method, lines] so the poll schedule and the
// `log read` N are visible in the raw data.
const requests = [];
const records = new WeakMap();
function track(context) {
  context.on('request', req => {
    const url = new URL(req.url());
    const rec = { t_ms: rel(), method: req.method(), path: url.pathname, calls: [] };
    try {
      const body = req.postData() ? JSON.parse(req.postData()) : null;
      for (const c of Array.isArray(body) ? body : body ? [body] : []) {
        const p = c?.params ?? [];
        if (c?.method === 'call') rec.calls.push([p[1], p[2], p[3]?.lines ?? null]);
      }
    } catch { /* not JSON */ }
    requests.push(rec);
    records.set(req, rec);
  });
  const done = req => {
    const rec = records.get(req);
    if (!rec) return;
    const timing = req.timing();
    rec.duration_ms = timing.responseEnd >= 0 ? Math.round(timing.responseEnd * 10) / 10 : null;
    rec.failed = req.failure()?.errorText ?? null;
  };
  context.on('requestfinished', done);
  context.on('requestfailed', done);
}
const count = (from, to = Infinity) => requests.filter(r => r.t_ms >= from && r.t_ms < to);
const ubusCount = (from, to) => count(from, to).filter(r => r.path.startsWith('/ubus')).length;

async function open(browser) {
  const context = await browser.newContext({ baseURL: base });
  track(context);
  const page = await context.newPage();
  page.on('pageerror', e => result.errors.push(`pageerror: ${e.message}`));
  await page.goto(path, { timeout: 180_000 });
  const field = page.locator('input[name="luci_username"]');
  await page.locator('input[name="luci_username"]:visible, #view > *:not(.spinning)').first().waitFor({ timeout: 180_000 });
  if (await field.isVisible()) {
    await field.fill('root');
    await page.locator('input[name="luci_password"]').fill(password);
    await page.getByRole('button', { name: 'Log in' }).click();
    await page.waitForURL(u => new URL(u).pathname.endsWith(path) || new URL(u).pathname.startsWith('/cgi-bin/luci'), { timeout: 180_000 });
    if (!new URL(page.url()).pathname.endsWith(path)) await page.goto(path, { timeout: 180_000 });
  }
  // LuCI renders the view into #view and removes its "Loading view…" spinner.
  await page.waitForFunction(() => {
    const v = document.getElementById('view');
    return v && v.children.length > 0 && !v.querySelector(':scope > .spinning') &&
      !document.querySelector('input[name="luci_password"]');
  }, null, { timeout: 180_000 });
  result.rendered_ms = rel();
  return { context, page };
}

async function measures(page) {
  return page.evaluate(name => performance.getEntriesByName(name).map(e => ({
    start_ms: Math.round(e.startTime * 100) / 100, duration_ms: Math.round(e.duration * 1000) / 1000,
    entries: e.detail?.entries ?? null, rows: e.detail?.rows ?? null
  })), MARK).catch(e => { result.errors.push(`measures: ${e.message}`); return []; });
}

// P4 fallback: the querylog module (shared interface, pivot brief) timed in
// the page on a real 900-line reply, fetched with the page's own session.
async function moduleBench(page, iterations = 20) {
  return page.evaluate(async n => {
    const out = { available: false };
    try {
      const rpc = await L.require('rpc');
      let ql = await L.require('adblock-fast-monitor.querylog');
      if (typeof ql === 'function') ql = new ql();
      if (typeof ql?.create !== 'function' || typeof ql?.ingest !== 'function') return { available: false, reason: 'querylog module lacks create/ingest' };
      const read = rpc.declare({ object: 'log', method: 'read', params: ['lines', 'stream', 'oneshot'], expect: { '': {} } });
      const reply = await read(900, false, true);
      out.entries = reply?.log?.length ?? 0;
      const opts = { max_rows: 500, pending_ttl_s: 10, local_domains: [], hide_router: true };
      const times = [];
      let kept = null, rows = null;
      for (let i = 0; i < n; i++) {
        const t = performance.now();
        const state = ql.create(opts);
        ql.ingest(state, reply);
        const r = ql.rows(state, { show_router: false });
        const s = ql.stats(state);
        times.push(performance.now() - t);
        rows = r.length; kept = s?.kept ?? null;
      }
      return { available: true, entries: out.entries, iterations: n, times_ms: times.map(v => Math.round(v * 1000) / 1000), rows, kept };
    } catch (e) {
      return { available: false, reason: String(e?.message ?? e) };
    }
  }, iterations);
}

// Hides the page: a real background tab when headless Chromium reports one
// as hidden, otherwise Page Visibility emulation (document.visibilityState /
// document.hidden overridden and a visibilitychange event dispatched).
async function setHidden(context, page, hidden, state) {
  if (hidden) {
    const bg = await context.newPage();
    await bg.goto('about:blank');
    await bg.bringToFront();
    await sleep(300);
    if (await page.evaluate(() => document.visibilityState) === 'hidden') {
      state.method = 'background-tab'; state.bg = bg; return;
    }
    await bg.close();
    state.method = 'visibility-emulation';
    await page.evaluate(() => {
      Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => 'hidden' });
      Object.defineProperty(document, 'hidden', { configurable: true, get: () => true });
      document.dispatchEvent(new Event('visibilitychange'));
    });
  } else if (state.method === 'background-tab') {
    await state.bg.close();
    await page.bringToFront();
  } else {
    await page.evaluate(() => {
      delete document.visibilityState; delete document.hidden;
      document.dispatchEvent(new Event('visibilitychange'));
    });
  }
}

// Router-side CPU ticks of uhttpd/rpcd/ubusd/logd (guest probe over SSH), so
// a hidden page is checked from the router too. Skipped without SSH env.
function guestTicks() {
  const { GUEST_SSH_KEY: key, GUEST_SSH_PORT: port, GUEST_RUN_DIR: dir } = process.env;
  if (!key || !port || !dir) return null;
  try {
    const snap = JSON.parse(execFileSync('ssh', ['-i', key, '-p', port, '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no',
      '-o', `UserKnownHostsFile=${dir}/known_hosts`, '-o', 'LogLevel=ERROR', 'root@127.0.0.1',
      'ucode /tmp/abfm-perf/probe.uc snapshot'], { encoding: 'utf8', timeout: 60_000 }));
    const out = {};
    for (const p of snap.procs) if (['uhttpd', 'rpcd', 'ubusd', 'logd'].includes(p.comm)) out[p.comm] = (out[p.comm] ?? 0) + p.utime + p.stime;
    return out;
  } catch (e) {
    result.errors.push(`guest ticks: ${e.message.split('\n')[0]}`);
    return null;
  }
}
const tickDelta = (a, b) => (a && b ? Object.fromEntries(Object.keys(b).map(k => [k, b[k] - (a[k] ?? 0)])) : null);

const browser = await chromium.launch();
let exitCode = 0;
try {
  const { context, page } = await open(browser);
  if (mode === 'hold') {
    // Ready once the page polls: two /ubus requests after the initial load
    // burst (≥ 1 s after render), or 30 s without any.
    const readyAt = Date.now() + 30_000, after = result.rendered_ms + 1000;
    while (ubusCount(after) < 2 && Date.now() < readyAt) await sleep(250);
    result.ready_ms = rel();
    result.polling_at_ready = ubusCount(after) >= 2;
    if (opt.ready) writeFileSync(opt.ready, `${result.ready_ms}\n`);
    const deadline = Date.now() + Number(opt['max-s'] ?? 900) * 1000;
    while (!(opt.stop && existsSync(opt.stop)) && Date.now() < deadline) await sleep(250);
    result.stopped_ms = rel();
    result.visibility = await page.evaluate(() => document.visibilityState);
    result.measures = await measures(page);
    result.module_bench = await moduleBench(page);
  } else {
    const control = Number(opt['control-s'] ?? 12) * 1000;
    const hiddenMs = Number(opt['hidden-s'] ?? 60) * 1000;
    const closedMs = Number(opt['closed-s'] ?? 60) * 1000;
    const phases = {};
    let a = rel();
    await sleep(control);
    phases.visible_control = { from_ms: a, to_ms: rel(), requests: count(a, rel()).length };
    const hide = {};
    await setHidden(context, page, true, hide);
    const h0 = rel(); const ticks0 = guestTicks();
    await sleep(hiddenMs);
    const h1 = rel(); const ticks1 = guestTicks();
    phases.hidden = { method: hide.method, from_ms: h0, to_ms: h1, requests: count(h0, h1).length,
      urls: count(h0, h1).map(r => `${r.t_ms} ${r.path} ${JSON.stringify(r.calls)}`).slice(0, 50),
      visibility_seen_by_page: await page.evaluate(() => document.visibilityState), router_ticks: tickDelta(ticks0, ticks1) };
    await setHidden(context, page, false, hide);
    const v0 = rel();
    const resumeBy = Date.now() + 15_000;
    while (!ubusCount(v0) && Date.now() < resumeBy) await sleep(100);
    const first = count(v0).find(r => r.path.startsWith('/ubus'));
    phases.resumed = { first_request_after_ms: first ? first.t_ms - v0 : null };
    await page.close();
    const c0 = rel(); const ticks2 = guestTicks();
    await sleep(closedMs);
    const c1 = rel(); const ticks3 = guestTicks();
    phases.closed = { from_ms: c0, to_ms: c1, requests: count(c0, c1).length, router_ticks: tickDelta(ticks2, ticks3) };
    result.phases = phases;
    await context.close();
  }
} catch (e) {
  result.errors.push(`fatal: ${e.message}`);
  exitCode = 1;
} finally {
  await browser.close().catch(() => {});
}
result.requests = requests;
result.finished_at = new Date().toISOString();
writeFileSync(opt.out, `${JSON.stringify(result)}\n`);
if (opt.ready && !existsSync(opt.ready)) writeFileSync(opt.ready, 'failed\n');
process.exit(exitCode);
