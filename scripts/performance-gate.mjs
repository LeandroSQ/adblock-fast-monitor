#!/usr/bin/env node
// P0 performance gate for design B-min (docs/CONTRACT.md §11, T26; method in
// docs/performance.md). Reduces the raw JSON of one scripts/perf/run.sh run to
// P1–P8 and P10, compares them with scripts/perf/budgets.json, writes
// summary.json and verdict.json next to the raw data and exits non-zero
// unless every budget passes. A metric that could not be measured fails.
//
//   node scripts/performance-gate.mjs [RUN_DIR]
//
// Without RUN_DIR (or ABFM_PERF_RUN) the gate evaluates the newest run under
// .local-validation/perf/ only when PERFORMANCE_REQUIRE_MEASURED=1; otherwise
// it reports SKIP and exits 0 (the CI host job has no guest).
import { existsSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { join, relative, resolve } from 'node:path';

const root = resolve(import.meta.dirname, '..');
const perfRoot = join(root, '.local-validation', 'perf');
const budgets = JSON.parse(readFileSync(join(root, 'scripts/perf/budgets.json'), 'utf8'));
const CLK_TCK = 100; // USER_HZ on OpenWrt x86/64
const PKG = 'adblock-fast-monitor';
const requireMeasured = process.env.PERFORMANCE_REQUIRE_MEASURED === '1';

function latestRun() {
  if (!existsSync(perfRoot)) return null;
  const runs = readdirSync(perfRoot)
    .map(name => join(perfRoot, name))
    .filter(dir => existsSync(join(dir, 'run.json')))
    .filter(dir => JSON.parse(readFileSync(join(dir, 'run.json'), 'utf8')).design === 'B-min')
    .sort((a, b) => statSync(join(b, 'run.json')).mtimeMs - statSync(join(a, 'run.json')).mtimeMs);
  return runs[0] ?? null;
}

// An .apk argument (npm appends the measure script's arguments here) is ignored.
let runDir = process.argv.slice(2).find(arg => !arg.endsWith('.apk')) ?? process.env.ABFM_PERF_RUN ?? null;
if (!runDir) {
  if (!requireMeasured) {
    const latest = latestRun();
    console.log('SKIP (P0 not measured here): no guest run given. Measure with ' +
      '`npm run test:performance:measure -- PACKAGE.apk`' +
      (latest ? `; newest run: ${relative(root, latest)}` : '') + '.');
    process.exit(0);
  }
  runDir = latestRun();
  if (!runDir) {
    console.error('Performance gate: PERFORMANCE_REQUIRE_MEASURED=1 but no B-min run exists under .local-validation/perf/.');
    process.exit(1);
  }
}
runDir = resolve(runDir);
const rawDir = join(runDir, 'raw');
if (!existsSync(join(runDir, 'run.json'))) {
  console.error(`Performance gate: ${runDir} has no run.json (incomplete run).`);
  process.exit(1);
}
const run = JSON.parse(readFileSync(join(runDir, 'run.json'), 'utf8'));
if (run.design !== 'B-min') {
  console.error(`Performance gate: ${runDir} was measured by the design A harness; re-measure with this harness.`);
  process.exit(1);
}

// ---------------------------------------------------------------- helpers
function load(name) {
  const path = join(rawDir, `${name}.json`);
  if (!existsSync(path)) return null;
  try {
    const text = readFileSync(path, 'utf8').trim();
    return text ? JSON.parse(text) : null;
  } catch {
    return null;
  }
}
const rawFiles = () => (existsSync(rawDir) ? readdirSync(rawDir) : []);
const loadMatching = re => rawFiles().filter(f => re.test(f)).sort().map(f => [f, load(f.replace(/\.json$/, ''))]).filter(([, v]) => v);
const finite = values => values.filter(Number.isFinite);
const median = values => {
  const v = finite(values).sort((a, b) => a - b);
  if (!v.length) return null;
  return v.length % 2 ? v[(v.length - 1) / 2] : (v[v.length / 2 - 1] + v[v.length / 2]) / 2;
};
const percentile = (values, q) => {
  const v = finite(values).sort((a, b) => a - b);
  return v.length ? v[Math.max(0, Math.min(v.length - 1, Math.ceil(q * v.length) - 1))] : null;
};
const spread = values => { const v = finite(values); return v.length >= 2 ? Math.max(...v) - Math.min(...v) : null; };
const round = (value, digits = 2) => (Number.isFinite(value) ? Math.round(value * 10 ** digits) / 10 ** digits : null);
const roundAll = (values, digits = 2) => values.map(v => round(v, digits));
const isResponder = p => p.comm === 'dnsmasq' && p.cmdline.includes('--port=5300');
// Processes created by the measurement itself (ssh sessions, the probe, shells).
const TRANSIENT = [/^\/usr\/sbin\/dropbear .* -2 /, /^ash -c /, /^sh -c /, /^-ash/, /probe\.uc/, /^sleep /,
  /^logread$/, /^ps /, /^ubus /, /^\/bin\/login/, /^\/sbin\/askfirst/];

function packageProcs(procs) {
  const set = new Set(procs.filter(p => p.cmdline.includes(PKG) && !p.cmdline.includes('probe.uc')).map(p => p.pid));
  let grew = true;
  while (grew) {
    grew = false;
    for (const p of procs) if (!set.has(p.pid) && set.has(p.ppid)) { set.add(p.pid); grew = true; }
  }
  return procs.filter(p => set.has(p.pid));
}
const named = (procs, comm) => procs.filter(p => p.comm === comm && !isResponder(p));
const sum = (procs, key) => procs.reduce((total, p) => total + (p[key] ?? 0), 0);
const userland = procs => procs.filter(p => !TRANSIENT.some(re => re.test(p.cmdline)));
const key = p => `${p.pid}:${p.starttime}`;
const replyOk = c => {
  if (typeof c?.reply_ok === 'boolean') return c.reply_ok;
  if (typeof c?.reply === 'string') return /^\{\s*"api":\s*\d+,\s*"ok":\s*true\b/.test(c.reply);
  return c?.reply?.ok === true;
};

// CPU % of one CPU used by the selected processes between two snapshots.
function cpuPct(win, select) {
  if (!win?.t0 || !win?.t1) return null;
  const wall = (win.t1.wall_ms - win.t0.wall_ms) / 1000;
  const before = new Map(select(win.t0.procs).map(p => [key(p), p]));
  let ticks = 0;
  for (const p of select(win.t1.procs)) {
    const b = before.get(key(p));
    ticks += p.utime + p.stime - (b ? b.utime + b.stime : 0);
  }
  return (ticks / CLK_TCK / wall) * 100;
}
const ofComms = comms => procs => procs.filter(p => comms.includes(p.comm) && !isResponder(p));

const metrics = {};
const notMeasured = (id, reason, extra = {}) => { metrics[id] = { verdict: 'NOT_MEASURED', reason, ...extra }; };
const judge = (id, pass, values) => { metrics[id] = { verdict: pass ? 'PASS' : 'FAIL', ...values }; };
const meta = load('meta-host') ?? {};
const rates = (meta.rates?.length ? meta.rates : [50, 200]).map(String);
const repeats = meta.repeats ?? 3;
const loads = {};
for (const state of ['off', 'on', 'page']) for (const q of rates) for (let r = 1; r <= repeats; r++) {
  (loads[`${state}-${q}`] ??= []).push({ r, win: load(`win-${state}-${q}-r${r}`), dns: load(`load-${state}-${q}-r${r}`) });
}
const toggles = state => [...Array(repeats + 1).keys()].map(r => load(`toggle-${state}-r${r}`)).filter(Boolean);
// Query logging really was on (a drop-in exists) in every on toggle.
const loggingOn = toggles('on').length > 0 && toggles('on').every(t => (t.dropins ?? '') !== '');
const pages = [...Array(repeats).keys()].map(i => load(`browser-page-r${i + 1}`));

// ---------------------------------------------------------------- P1
{
  const stock = [1, 2, 3].map(i => load(`p1-stock-${i}`)).filter(Boolean);
  const instOff = [1, 2, 3].map(i => load(`p1-installed-off-${i}`)).filter(Boolean);
  const instOn = [1, 2, 3].map(i => load(`p1-installed-on-${i}`)).filter(Boolean);
  if (!stock.length || !instOff.length || !instOn.length) {
    notMeasured('P1', 'stock or installed (logging off/on) snapshots missing');
  } else {
    const stockSigs = new Set(stock.flatMap(s => userland(s.procs).map(p => p.cmdline)));
    const found = new Set();
    const add = (where, cmdline) => found.add(`${where}: ${cmdline}`);
    // New userland processes vs stock, in the installed steady states.
    for (const [where, snaps] of [['installed, logging off', instOff], ['installed, logging on', instOn]]) {
      for (const s of snaps) for (const p of userland(s.procs)) if (!stockSigs.has(p.cmdline)) add(where, p.cmdline);
    }
    // Package processes in every snapshot of every state (P1: none, ever).
    const snapshotFiles = loadMatching(/^(p1-(installed|after-boot)-.*-\d|p1-installed-(off|on)-\d)\.json$/);
    for (const [f, s] of snapshotFiles) for (const p of packageProcs(s.procs ?? [])) add(f, p.cmdline);
    for (const [f, w] of loadMatching(/^win-.*\.json$/)) {
      for (const snap of [w.t0, w.t1]) for (const p of packageProcs(snap?.procs ?? [])) add(f, p.cmdline);
    }
    for (const [f, w] of loadMatching(/^p1-.*-watch\.json$/)) for (const c of Object.keys(w.seen ?? {})) add(`${f} (250 ms watch)`, c);
    for (const [f, t] of loadMatching(/^(toggle-.*|p1-ensure-off|p10-.*)\.json$/)) {
      for (const line of String(t.package_procs ?? '').split('\n').filter(Boolean)) add(f, line.replace(/^\d+\s+\S+\s+\d+\s+\S+\s+/, ''));
      for (const line of String(t.logread_procs ?? '').split('\n').filter(Boolean)) add(f, line.replace(/^\d+\s+\S+\s+\d+\s+\S+\s+/, ''));
      if (t.monitor_object) add(f, 'ubus object adblock-fast-monitor');
    }
    const rpcdAnon = snaps => median(snaps.map(s => sum(named(s.procs, 'rpcd'), 'rss_anon_kb')));
    const afterBoot = ['on', 'off'].flatMap(st => [1, 2, 3].map(i => load(`p1-after-boot-${st}-${i}`))).filter(Boolean);
    const rpcdDelta = Math.max(rpcdAnon(instOff) - rpcdAnon(stock), rpcdAnon(instOn) - rpcdAnon(stock));
    const byComm = snaps => {
      const out = {};
      for (const s of snaps) for (const p of userland(s.procs)) if (stockSigs.has(p.cmdline)) (out[p.comm] ??= []).push(p.rss_anon_kb);
      return Object.fromEntries(Object.entries(out).map(([k, v]) => [k, median(v)]));
    };
    const stockByComm = byComm(stock), instByComm = byComm(instOff);
    const bootsChecked = afterBoot.length > 0;
    judge('P1', found.size <= budgets.P1.package_processes && rpcdDelta <= budgets.P1.rpcd_rss_anon_delta_kib && bootsChecked, {
      package_processes: found.size, found: [...found].slice(0, 40),
      rpcd_rss_anon_kib: { stock: rpcdAnon(stock), installed_off: rpcdAnon(instOff), installed_on: rpcdAnon(instOn),
        after_boot: afterBoot.length ? rpcdAnon(afterBoot) : null },
      rpcd_rss_anon_delta_kib: rpcdDelta,
      rss_anon_delta_by_process_kib: Object.fromEntries(Object.keys(instByComm).map(k => [k, instByComm[k] - (stockByComm[k] ?? 0)])),
      mem_available_delta_kib: median(instOff.map(s => s.meminfo.MemAvailable)) - median(stock.map(s => s.meminfo.MemAvailable)),
      snapshots_checked: snapshotFiles.length + 2 * loadMatching(/^win-.*\.json$/).length,
      after_boot_checked: bootsChecked, ...(bootsChecked ? {} : { missing: 'no snapshot after a boot (ABFM_PERF_SKIP_BOOT?)' }),
      budget: budgets.P1,
      raw: ['p1-*.json', 'win-*.json', 'toggle-*.json', 'p10-*.json', 'install.json']
    });
  }
}

// ---------------------------------------------------------------- P2
{
  const b = load('browser-p2');
  const ph = b?.phases;
  if (!ph?.hidden || !ph?.closed) {
    notMeasured('P2', b ? `browser p2 incomplete: ${(b.errors ?? []).join('; ').slice(0, 300)}` : 'no browser p2 run');
  } else {
    // The counter must be shown to work: the visible page polls.
    const works = ph.visible_control.requests > 0;
    const info = { hide_method: ph.hidden.method, visible_control_requests: ph.visible_control.requests,
      visible_control_s: round((ph.visible_control.to_ms - ph.visible_control.from_ms) / 1000, 1),
      hidden_requests: ph.hidden.requests, hidden_s: round((ph.hidden.to_ms - ph.hidden.from_ms) / 1000, 1),
      hidden_urls: ph.hidden.urls, hidden_router_ticks: ph.hidden.router_ticks,
      resumed_after_ms: ph.resumed?.first_request_after_ms ?? null,
      closed_requests: ph.closed.requests, closed_s: round((ph.closed.to_ms - ph.closed.from_ms) / 1000, 1),
      closed_router_ticks: ph.closed.router_ticks, errors: b.errors, budget: budgets.P2, raw: ['browser-p2.json'] };
    const long = info.hidden_s >= budgets.P2.window_s && info.closed_s >= budgets.P2.window_s;
    if (!works || !long) notMeasured('P2', works ? 'hidden/closed windows shorter than budgeted' : 'the visible page made no request (counter unproven)', info);
    else judge('P2', ph.hidden.requests <= budgets.P2.hidden_requests && ph.closed.requests <= budgets.P2.closed_requests &&
      info.resumed_after_ms != null, info);
  }
}

// ---------------------------------------------------------------- P3
const pollStats = b => {
  if (!b?.requests) return null;
  const from = b.ready_ms ?? 0, to = b.stopped_ms ?? Infinity;
  const polls = b.requests.filter(r => r.path.startsWith('/ubus') && r.t_ms >= from && r.t_ms < to);
  const logReads = polls.filter(r => r.calls.some(c => c[0] === 'log' && c[1] === 'read'));
  const seconds = (Math.min(to, b.requests.at(-1)?.t_ms ?? to) - from) / 1000;
  // One poll may issue several requests back to back: a gap > 700 ms starts a new poll.
  let ticks = 0, last = -Infinity;
  for (const r of polls) { if (r.t_ms - last > 700) ticks += 1; last = r.t_ms; }
  return { seconds: round(seconds, 1), requests: polls.length, polls: ticks, interval_s: ticks > 1 ? round(seconds / ticks, 2) : null,
    log_read_requests: logReads.length, log_read_lines: [...new Set(logReads.flatMap(r => r.calls.filter(c => c[0] === 'log').map(c => c[2])))].slice(0, 20),
    http_log_read_p95_ms: round(percentile(logReads.map(r => r.duration_ms), 0.95), 1),
    http_p95_ms: round(percentile(polls.map(r => r.duration_ms), 0.95), 1) };
};
{
  const sel = ofComms(budgets.P3.processes);
  const out = {}; let pass = true; let measured = true; const reasons = [];
  const polling = pages.map(pollStats);
  for (const q of rates) {
    const page = loads[`page-${q}`].map(x => cpuPct(x.win, sel));
    const nopage = loads[`on-${q}`].map(x => cpuPct(x.win, sel));
    const delta = median(page) != null && median(nopage) != null ? median(page) - median(nopage) : null;
    const per = Object.fromEntries(budgets.P3.processes.map(c => [c, round(
      median(loads[`page-${q}`].map(x => cpuPct(x.win, ofComms([c])))) - median(loads[`on-${q}`].map(x => cpuPct(x.win, ofComms([c])))))]));
    const bench = [...Array(repeats).keys()].map(i => load(`logbench-${q}-r${i + 1}`));
    const incr = bench.map(b => b?.incremental?.stats?.p95 ?? null), full = bench.map(b => b?.full?.stats?.p95 ?? null);
    const nIncr = bench.map(b => b?.n_incremental ?? null);
    const incrBudget = median(nIncr) >= budgets.P3.full_lines ? budgets.P3.log_read_full_p95_ms : budgets.P3.log_read_incremental_p95_ms;
    out[q] = { cpu_page_pct_runs: roundAll(page), cpu_nopage_pct_runs: roundAll(nopage), cpu_delta_pp: round(delta),
      cpu_delta_by_process_pp: per, budget_pp: budgets.P3.cpu_delta_pp[q],
      log_read: { n_incremental_runs: nIncr, lines_per_2s_runs: bench.map(b => b?.lines_per_2s ?? null),
        incremental_p95_ms_runs: roundAll(incr), incremental_p95_ms: round(median(incr)), incremental_budget_ms: incrBudget,
        full_p95_ms_runs: roundAll(full), full_p95_ms: round(median(full)), full_budget_ms: budgets.P3.log_read_full_p95_ms,
        full_entries: bench.map(b => median(b?.full?.entries ?? [])), errors: bench.map(b => b?.errors ?? null) } };
    if (finite(page).length < 3 || finite(nopage).length < 3) { measured = false; reasons.push(`fewer than 3 page/no-page windows at ${q} qps`); }
    else if (delta > budgets.P3.cpu_delta_pp[q]) pass = false;
    if (finite(incr).length < 3 || finite(full).length < 3) { measured = false; reasons.push(`log read bench missing at ${q} qps`); }
    else if (median(incr) > incrBudget || median(full) > budgets.P3.log_read_full_p95_ms) pass = false;
  }
  const expected = budgets.P3.poll_interval_s / budgets.P3.min_poll_ratio;
  const slow = polling.filter(p => !p || p.interval_s == null || p.interval_s > expected);
  if (slow.length) { measured = false; reasons.push(`the page did not poll at least every ${expected} s (${polling.map(p => p?.interval_s).join(', ')} s)`); }
  const info = { rates: out, page_polling: polling, logging_on: loggingOn, budget: budgets.P3,
    note: 'page = real LuCI page in headless Chromium (logged in as root); CPU = uhttpd+ubusd+logd+rpcd; log read timed by the guest probe over ubus',
    raw: ['win-page-*.json', 'win-on-*.json', 'logbench-*.json', 'browser-page-*.json'] };
  if (!loggingOn) notMeasured('P3', 'query logging was not on during the page runs', info);
  else if (!measured) notMeasured('P3', reasons.join('; '), info);
  else judge('P3', pass, info);
}

// ---------------------------------------------------------------- P4
{
  const marks = pages.flatMap(b => b?.measures ?? []);
  const big = marks.filter(m => (m.entries ?? 0) >= budgets.P4.min_entries);
  const bench = pages.map(b => b?.module_bench).filter(m => m?.available);
  const info = { mark: budgets.P4.mark, marks_total: marks.length, marks_at_900: big.length,
    marks_p95_ms: round(percentile(big.map(m => m.duration_ms), 0.95), 3), marks_max_ms: round(Math.max(...big.map(m => m.duration_ms)), 3),
    marks_rows_max: Math.max(0, ...marks.map(m => m.rows ?? 0)),
    module_bench: bench.length ? { entries: bench.map(m => m.entries), p95_ms_runs: bench.map(m => round(percentile(m.times_ms, 0.95), 3)),
      p95_ms: round(percentile(bench.flatMap(m => m.times_ms), 0.95), 3), rows: bench.map(m => m.rows), kept: bench.map(m => m.kept) } : null,
    module_unavailable: pages.map(b => (b?.module_bench?.available ? null : b?.module_bench?.reason ?? null)).filter(Boolean).slice(0, 3),
    budget: budgets.P4, raw: ['browser-page-*.json'] };
  const rowsOk = rows => rows.every(n => n == null || n <= budgets.P4.max_rows);
  if (big.length) {
    judge('P4', info.marks_p95_ms <= budgets.P4.poll_p95_ms && info.marks_rows_max <= budgets.P4.max_rows,
      { ...info, scope: 'page marks: parse + classify + render per poll' });
  } else if (bench.length && bench.every(m => m.entries >= budgets.P4.min_entries)) {
    judge('P4', info.module_bench.p95_ms <= budgets.P4.poll_p95_ms && rowsOk(info.module_bench.rows) && rowsOk(info.module_bench.kept),
      { ...info, scope: 'querylog module only (parse + classify, no render): the page has no abfm-poll marks' });
  } else {
    notMeasured('P4', `no ${budgets.P4.mark} marks with ≥ ${budgets.P4.min_entries} entries and no querylog module in the page`, info);
  }
}

// ---------------------------------------------------------------- P5
{
  const out = {}; let pass = true; let measured = true;
  for (const q of rates) {
    const p95 = state => finite(loads[`${state}-${q}`].map(x => x.dns?.latency_ms?.p95));
    const loss = state => loads[`${state}-${q}`].map(x => (x.dns ? (100 * x.dns.lost) / Math.max(1, x.dns.sent) : null));
    const off = p95('off'), on = p95('on');
    // Run-to-run spread of p95 in either state is the noise floor.
    const noise = spread(off) == null || spread(on) == null ? null : Math.max(spread(off), spread(on));
    const delta = off.length && on.length ? median(on) - median(off) : null;
    const allowed = noise == null ? null : Math.max(budgets.P5.p95_delta_floor_ms, noise);
    const lossOn = Math.max(0, ...finite(loss('on')));
    out[q] = { p95_off_ms: off, p95_on_ms: on, delta_ms: round(delta, 3), noise_floor_ms: round(noise, 3),
      spread_off_ms: round(spread(off), 3), spread_on_ms: round(spread(on), 3), allowed_delta_ms: round(allowed, 3),
      p50_delta_ms: round(median(loads[`on-${q}`].map(x => x.dns?.latency_ms?.p50)) - median(loads[`off-${q}`].map(x => x.dns?.latency_ms?.p50)), 3),
      loss_pct_off: roundAll(loss('off'), 3), loss_pct_on: roundAll(loss('on'), 3),
      samples_off: loads[`off-${q}`].reduce((n, x) => n + (x.dns?.received ?? 0), 0),
      samples_on: loads[`on-${q}`].reduce((n, x) => n + (x.dns?.received ?? 0), 0) };
    if (off.length < budgets.P5.min_runs || on.length < budgets.P5.min_runs || delta == null) measured = false;
    else if (delta > allowed || lossOn > budgets.P5.max_loss_pct) pass = false;
  }
  const info = { rates: out, logging_on: loggingOn, budget: budgets.P5, raw: ['load-off-*.json', 'load-on-*.json'] };
  if (!measured) notMeasured('P5', `fewer than ${budgets.P5.min_runs} off and on load runs per rate`, info);
  else if (!loggingOn) notMeasured('P5', 'query logging was not on during the on runs', info);
  else judge('P5', pass, info);
}

// ---------------------------------------------------------------- P6
{
  const out = {}; let pass = true; let measured = true;
  for (const q of rates) {
    out[q] = {};
    for (const comm of budgets.P6.processes) {
      const sel = procs => named(procs, comm);
      const cpus = state => loads[`${state}-${q}`].map(x => cpuPct(x.win, sel));
      const anon = state => median(loads[`${state}-${q}`].map(x => (x.win ? sum(sel(x.win.t1.procs), 'rss_anon_kb') : null)));
      const [cOn, cOff, aOn, aOff] = [median(cpus('on')), median(cpus('off')), anon('on'), anon('off')];
      const dCpu = cOn != null && cOff != null ? cOn - cOff : null;
      const dAnon = aOn != null && aOff != null ? aOn - aOff : null;
      out[q][comm] = { cpu_off_pct_runs: roundAll(cpus('off')), cpu_on_pct_runs: roundAll(cpus('on')), cpu_delta_pp: round(dCpu),
        rss_anon_off_kib: aOff, rss_anon_on_kib: aOn, rss_anon_delta_kib: dAnon };
      if (dCpu == null) { measured = false; continue; }
      if (dCpu > budgets.P6.cpu_delta_pp[q] || (dAnon ?? 0) > budgets.P6.rss_anon_delta_kib) pass = false;
    }
    const busy = state => median(loads[`${state}-${q}`].map(x => {
      if (!x.win) return null;
      const total = c => Object.values(c).reduce((s, v) => s + v, 0) - c.idle - c.iowait;
      return ((total(x.win.t1.cpu) - total(x.win.t0.cpu)) / CLK_TCK / ((x.win.t1.wall_ms - x.win.t0.wall_ms) / 1000)) * 100;
    }));
    out[q].system_busy = { off_pct: round(busy('off')), on_pct: round(busy('on')), page_pct: round(busy('page')),
      note: 'all guest CPUs, percent of one CPU' };
  }
  const info = { rates: out, logging_on: loggingOn, budget: budgets.P6, raw: ['win-off-*.json', 'win-on-*.json'] };
  if (!measured) notMeasured('P6', 'load windows missing', info);
  else if (!loggingOn) notMeasured('P6', 'query logging was not on during the on runs', info);
  else judge('P6', pass, info);
}

// ---------------------------------------------------------------- P7
{
  const c = load('rpc-info');
  const floor = { system_board_p95_ms: round(load('calib-rpc-system-board')?.stats?.p95),
    session_list_p95_ms: round(load('calib-rpc-session-list')?.stats?.p95) };
  const info = { info: c ? { p50_ms: round(c.stats?.p50), p95_ms: round(c.stats?.p95), max_ms: round(c.stats?.max),
    n: c.stats?.n ?? 0, error: c.error ?? null, reply_bytes: c.reply_bytes ?? 0 } : null,
  ubus_floor: floor, budget: budgets.P7, raw: ['rpc-info.json', 'calib-rpc-*.json'] };
  if (!c || c.error || !c.stats?.n || !replyOk(c)) notMeasured('P7', 'luci.adblock-fast-monitor info unavailable', info);
  else judge('P7', c.stats.p95 <= budgets.P7.info_p95_ms, info);
}

// ---------------------------------------------------------------- P8
{
  const ok = c => c && !c.error && c.stats?.n > 0 && replyOk(c);
  const dry = load('p8-apply-dry'), real = load('p8-apply'), probe = load('p8-rpcd-probe');
  const info = {
    dry_run: dry ? { p95_ms: round(dry.stats?.p95), max_ms: round(dry.stats?.max), error: dry.error ?? null, reply: dry.reply } : null,
    real: real ? { max_ms: round(real.stats?.max), error: real.error ?? null, reply: real.reply } : null,
    job: load('p8-job'), rpcd_probe: probe?.stats ?? null, budget: budgets.P8, raw: ['p8-*.json'] };
  if (!ok(dry) || !ok(real) || !probe?.stats?.n) notMeasured('P8', 'apply unavailable or rejected, or rpcd probe missing', info);
  else judge('P8', Math.max(dry.stats.max, real.stats.max) <= budgets.P8.apply_max_ms &&
    probe.stats.max <= budgets.P8.rpcd_block_max_ms, info);
}

// ---------------------------------------------------------------- P10
{
  const enables = toggles('on').map(t => ({ restarts: t.dnsmasq_restarts, dropins: t.dropins }));
  const disables = toggles('off').map(t => ({ restarts: t.dnsmasq_restarts, dropins: t.dropins }));
  const save = load('p10-save'), unsave = load('p10-unsave'), bootOn = load('p10-boot-on'), bootOff = load('p10-boot-off');
  const boot = bootOn && bootOff ? bootOn.dnsmasq_starts_since_boot - bootOff.dnsmasq_starts_since_boot : null;
  const info = { boot_logging_restarts: boot, boot_on: bootOn, boot_off: bootOff, enable: enables, disable: disables,
    save: save ? { restarts: save.dnsmasq_restarts, uci_changes: save.uci_changes } : null,
    unsave: unsave ? { restarts: unsave.dnsmasq_restarts } : null, budget: budgets.P10, raw: ['toggle-*.json', 'p10-*.json'] };
  if (boot == null || !save || !enables.length) notMeasured('P10', 'boot, enable or save phase missing', info);
  else judge('P10', boot === budgets.P10.boot && enables.every(e => e.restarts === budgets.P10.enable && e.dropins) &&
    save.dnsmasq_restarts === budgets.P10.save && (unsave?.dnsmasq_restarts ?? 0) === budgets.P10.save,
  { ...info, ...(loggingOn ? {} : { reason: 'enabling query logging created no drop-in' }) });
}

// ---------------------------------------------------------------- verdict
const order = ['P1', 'P2', 'P3', 'P4', 'P5', 'P6', 'P7', 'P8', 'P10'];
const failed = order.filter(id => metrics[id]?.verdict !== 'PASS');
const summary = {
  run: relative(root, runDir), measured_at: run.finished_at, design: 'B-min',
  environment: { accel: meta.accel, guest_cpus: meta.guest_cpus, guest_memory_mib: meta.guest_memory_mib,
    host: meta.host_uname, package_file: meta.package_file, package_sha256: meta.package_sha256, page: meta.page,
    browser: meta.browser, repeats: meta.repeats, load_seconds: meta.load_seconds, hidden_seconds: meta.hidden_seconds, rates: meta.rates },
  harness_errors: run.errors ?? [], metrics
};
// Measurement noise in this environment (TCG unless accel says otherwise):
// run-to-run spread (max − min over the ≥ 3 repeats) of every repeated number.
const noise = Object.fromEntries(rates.map(q => {
  const p3 = metrics.P3?.rates?.[q], p5 = metrics.P5?.rates?.[q], p6 = metrics.P6?.rates?.[q] ?? {};
  return [q, {
    p3_cpu_page_spread_pp: round(spread(p3?.cpu_page_pct_runs ?? [])), p3_cpu_nopage_spread_pp: round(spread(p3?.cpu_nopage_pct_runs ?? [])),
    p3_log_read_incremental_p95_spread_ms: round(spread(p3?.log_read?.incremental_p95_ms_runs ?? [])),
    p3_log_read_full_p95_spread_ms: round(spread(p3?.log_read?.full_p95_ms_runs ?? [])),
    p5_p95_spread_off_ms: p5?.spread_off_ms ?? null, p5_p95_spread_on_ms: p5?.spread_on_ms ?? null,
    p6_cpu_spread_pp: Object.fromEntries(budgets.P6.processes.map(c => [c, round(Math.max(spread(p6[c]?.cpu_off_pct_runs ?? []) ?? -1,
      spread(p6[c]?.cpu_on_pct_runs ?? []) ?? -1))]).filter(([, v]) => v != null && v >= 0))
  }];
}));
summary.noise = noise;
const verdict = { verdict: failed.length ? 'FAIL' : 'PASS', failed, run: summary.run, accel: meta.accel ?? null, repeats,
  per_metric: Object.fromEntries(order.map(id => [id, metrics[id]?.verdict ?? 'NOT_MEASURED'])),
  p4_scope: metrics.P4?.scope ?? null, noise };
writeFileSync(join(runDir, 'summary.json'), `${JSON.stringify(summary, null, 1)}\n`);
writeFileSync(join(runDir, 'verdict.json'), `${JSON.stringify(verdict, null, 1)}\n`);

// One line of the numbers behind a verdict, for the console table.
function brief(id, m) {
  const b = budgets[id];
  try {
    switch (id) {
      case 'P1': return `package processes ${m.package_processes}${m.found.length ? ` (${m.found[0]}${m.found.length > 1 ? ', …' : ''})` : ''}, rpcd RssAnon +${m.rpcd_rss_anon_delta_kib} KiB (≤ ${b.rpcd_rss_anon_delta_kib})${m.missing ? `; ${m.missing}` : ''}`;
      case 'P2': return `hidden ${m.hidden_requests} req/${m.hidden_s} s (${m.hide_method}), closed ${m.closed_requests} req/${m.closed_s} s, visible control ${m.visible_control_requests} req/${m.visible_control_s} s`;
      case 'P3': return rates.map(q => `@${q}: Δ ${m.rates[q].cpu_delta_pp} pp (≤ ${b.cpu_delta_pp[q]}), log read p95 N=${m.rates[q].log_read.n_incremental_runs[0]} ${m.rates[q].log_read.incremental_p95_ms} ms (≤ ${m.rates[q].log_read.incremental_budget_ms}) N=900 ${m.rates[q].log_read.full_p95_ms} ms (≤ ${b.log_read_full_p95_ms})`).join('; ');
      case 'P4': return m.marks_at_900 ? `page marks p95 ${m.marks_p95_ms} ms over ${m.marks_at_900} polls (≤ ${b.poll_p95_ms})` : `querylog module p95 ${m.module_bench?.p95_ms} ms at ${m.module_bench?.entries?.[0]} entries (≤ ${b.poll_p95_ms}; no render)`;
      case 'P5': return rates.map(q => `@${q}: Δp95 ${m.rates[q].delta_ms} ms (≤ ${m.rates[q].allowed_delta_ms})`).join(', ');
      case 'P6': return rates.map(q => `@${q}: max Δ ${Math.max(...b.processes.map(c => m.rates[q][c].cpu_delta_pp ?? 0))} pp (≤ ${b.cpu_delta_pp[q]})`).join(', ');
      case 'P7': return `info p95 ${m.info?.p95_ms} ms (≤ ${b.info_p95_ms})`;
      case 'P8': return `dry max ${m.dry_run.max_ms} ms, real ${m.real.max_ms} ms (≤ ${b.apply_max_ms}), rpcd probe max ${round(m.rpcd_probe?.max)} ms (≤ ${b.rpcd_block_max_ms})`;
      case 'P10': return `boot ${m.boot_logging_restarts}, enable ${JSON.stringify(m.enable.map(e => e.restarts))}, save ${m.save.restarts}`;
      default: return '';
    }
  } catch { return ''; }
}
console.log(`P0 performance gate (B-min): ${summary.run} (accel ${meta.accel ?? '?'}, ${repeats} repeats)`);
for (const id of order) {
  const m = metrics[id] ?? { verdict: 'NOT_MEASURED' };
  console.log(`  ${id.padEnd(4)} ${m.verdict.padEnd(12)} ${m.reason ?? brief(id, m)}`);
}
for (const [q, n] of Object.entries(noise)) {
  console.log(`  noise @${q} qps (${meta.accel ?? '?'}, spread over ${repeats} repeats): P3 CPU page ${n.p3_cpu_page_spread_pp} / no page ${n.p3_cpu_nopage_spread_pp} pp,` +
    ` log read p95 ${n.p3_log_read_incremental_p95_spread_ms} / ${n.p3_log_read_full_p95_spread_ms} ms; P5 p95 off ${n.p5_p95_spread_off_ms} / on ${n.p5_p95_spread_on_ms} ms;` +
    ` P6 ${Object.entries(n.p6_cpu_spread_pp).map(([c, v]) => `${c} ${v}`).join(' ')} pp`);
}
if (summary.harness_errors.length) console.log(`  harness errors: ${summary.harness_errors.join('; ')}`);
console.log(`${verdict.verdict}: ${failed.length ? `${failed.join(', ')} not within budget or not measured` : 'all P0 budgets met'}` +
  ` (details: ${relative(root, join(runDir, 'summary.json'))})`);
process.exit(failed.length ? 1 : 0);
