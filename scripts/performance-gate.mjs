#!/usr/bin/env node
// P0 performance gate (docs/CONTRACT.md §11, T26; method in docs/performance.md).
// Reduces the raw JSON of one scripts/perf/run.sh run to the P1–P10 metrics,
// compares them with scripts/perf/budgets.json, writes summary.json and
// verdict.json next to the raw data and exits non-zero unless every budget
// passes. A metric that could not be measured fails.
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
    .sort((a, b) => statSync(join(b, 'run.json')).mtimeMs - statSync(join(a, 'run.json')).mtimeMs);
  return runs[0] ?? null;
}

// An .apk argument (npm appends the measure script's arguments here) is ignored.
let runDir = process.argv.slice(2).find(arg => !arg.endsWith('.apk')) ?? process.env.ABFM_PERF_RUN ?? null;
if (!runDir) {
  if (!requireMeasured) {
    const latest = latestRun();
    console.log('SKIP (P0 not measured here): no guest run given. Measure with ' +
      '`node scripts/integration/measure-performance.mjs PACKAGE.apk`' +
      (latest ? `; newest run: ${relative(root, latest)}` : '') + '.');
    process.exit(0);
  }
  runDir = latestRun();
  if (!runDir) {
    console.error('Performance gate: PERFORMANCE_REQUIRE_MEASURED=1 but no run exists under .local-validation/perf/.');
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
const median = values => {
  const v = values.filter(Number.isFinite).sort((a, b) => a - b);
  if (!v.length) return null;
  return v.length % 2 ? v[(v.length - 1) / 2] : (v[v.length / 2 - 1] + v[v.length / 2]) / 2;
};
const round = (value, digits = 2) => (Number.isFinite(value) ? Math.round(value * 10 ** digits) / 10 ** digits : null);
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
const daemonProcs = procs => packageProcs(procs).filter(p => p.cmdline.includes(PKG));
const childProcs = procs => packageProcs(procs).filter(p => !p.cmdline.includes(PKG));
const named = (procs, comm) => procs.filter(p => p.comm === comm && !isResponder(p));
const sum = (procs, key) => procs.reduce((total, p) => total + (p[key] ?? 0), 0);
const userland = procs => procs.filter(p => !TRANSIENT.some(re => re.test(p.cmdline)));
const key = p => `${p.pid}:${p.starttime}`;

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
function wakeups(win, select) {
  if (!win?.t0 || !win?.t1) return null;
  const before = new Map(select(win.t0.procs).map(p => [key(p), p]));
  let voluntary = 0, involuntary = 0, procs = 0;
  for (const p of select(win.t1.procs)) {
    const b = before.get(key(p));
    if (!b) continue;
    procs += 1;
    voluntary += p.vctx - b.vctx;
    involuntary += p.nvctx - b.nvctx;
  }
  return { procs, voluntary, involuntary, total: voluntary + involuntary };
}
// /proc/<pid>/syscall is "nr a1 a2 a3 a4 a5 a6 sp pc" (x86_64) while blocked.
// A wait with an infinite timeout means no timer is armed.
const WAIT_TIMEOUT_ARG = { 232: 4, 281: 4, 7: 3 }; // epoll_wait, epoll_pwait: a4; poll: a3 (ms)
function classifySyscall(line) {
  if (!line || line === 'gone') return 'gone';
  if (line === 'running') return 'running';
  const f = line.split(' ');
  const nr = Number(f[0]);
  if (nr in WAIT_TIMEOUT_ARG) {
    const timeout = BigInt.asIntN(32, BigInt(f[WAIT_TIMEOUT_ARG[nr]]) & 0xffffffffn);
    return timeout < 0n ? 'wait-infinite' : `wait-timed:${timeout}ms`;
  }
  // ppoll (271) / epoll_pwait2 (441): a NULL timespec pointer is an infinite wait
  if (nr === 271 || nr === 441) return BigInt(f[nr === 271 ? 3 : 4]) === 0n ? 'wait-infinite' : 'wait-timed';
  return `syscall-${nr}`;
}

const metrics = {};
const notMeasured = (id, reason, extra = {}) => { metrics[id] = { verdict: 'NOT_MEASURED', reason, ...extra }; };
const judge = (id, pass, values) => { metrics[id] = { verdict: pass ? 'PASS' : 'FAIL', ...values }; };
const meta = load('meta-host') ?? {};
const rates = (meta.rates?.length ? meta.rates : [50, 200]).map(String);
const repeats = meta.repeats ?? 3;

// ---------------------------------------------------------------- P1
{
  const stock = [1, 2, 3].map(i => load(`p1-stock-${i}`)).filter(Boolean);
  const inst = [1, 2, 3].map(i => load(`p1-installed-${i}`)).filter(Boolean);
  const afterBoot = [1, 2, 3].map(i => load(`p1-after-boot-${i}`)).filter(Boolean);
  const bootOff = load('p10-boot-off');
  if (!stock.length || !inst.length) {
    notMeasured('P1', 'stock or installed snapshots missing');
  } else {
    const stockSigs = new Set(stock.flatMap(s => userland(s.procs).map(p => p.cmdline)));
    const extra = new Set();
    for (const s of inst) for (const p of userland(s.procs)) if (!stockSigs.has(p.cmdline)) extra.add(p.cmdline);
    for (const s of inst) for (const p of packageProcs(s.procs)) extra.add(p.cmdline);
    for (const s of afterBoot) for (const p of packageProcs(s.procs)) extra.add(`after a disabled boot: ${p.cmdline}`);
    for (const [name, file] of [['after install', 'p1-installed-watch'], ['after a disabled boot', 'p1-after-boot-watch']]) {
      for (const cmdline of Object.keys(load(file)?.seen ?? {})) extra.add(`${name} (250 ms watch): ${cmdline}`);
    }
    for (const line of (bootOff?.package_procs ?? '').split('\n').filter(Boolean)) {
      extra.add(`after a disabled boot: ${line.replace(/^\d+\s+\S+\s+\d+\s+\S+\s+/, '')}`);
    }
    const byComm = snaps => {
      const out = {};
      for (const s of snaps) for (const p of userland(s.procs)) if (stockSigs.has(p.cmdline)) (out[p.comm] ??= []).push(p.rss_anon_kb);
      return Object.fromEntries(Object.entries(out).map(([k, v]) => [k, median(v)]));
    };
    const stockByComm = byComm(stock), instByComm = byComm(inst);
    const deltas = Object.fromEntries(Object.keys(instByComm).map(k => [k, instByComm[k] - (stockByComm[k] ?? 0)]));
    const rssDelta = Object.values(deltas).reduce((a, b) => a + b, 0);
    const memAvail = median(inst.map(s => s.meminfo.MemAvailable)) - median(stock.map(s => s.meminfo.MemAvailable));
    judge('P1', extra.size <= budgets.P1.extra_processes && rssDelta <= budgets.P1.rss_anon_delta_kib, {
      extra_processes: extra.size, extra: [...extra], rss_anon_delta_kib: rssDelta,
      rss_anon_delta_by_process_kib: deltas, mem_available_delta_kib: memAvail,
      after_disabled_boot_checked: afterBoot.length > 0 || bootOff != null,
      watches: { after_install: load('p1-installed-watch'), after_disabled_boot: load('p1-after-boot-watch') },
      budget: budgets.P1,
      raw: ['p1-stock-*.json', 'p1-installed-*.json', 'p1-*-watch.json', 'p1-after-boot-*.json', 'p10-boot-off.json', 'p1-state.json', 'install.json']
    });
  }
}

// ---------------------------------------------------------------- P2
{
  const footprint = snap => {
    const procs = snap ? packageProcs(snap.procs) : [];
    return procs.length ? { procs: procs.map(p => `${p.pid} ${p.cmdline}`), rss_kib: sum(procs, 'vm_rss_kb'),
      rss_anon_kib: sum(procs, 'rss_anon_kb') } : null;
  };
  const idle = footprint(load('p2-idle')), full = footprint(load('p2-full'));
  const reference = Object.fromEntries(['0', 'default', 'cap', 'max'].map(k => {
    const v = load(`calib-memref-${k}`);
    return [k, v ? { tables: [v.recent, v.top, v.pending], rss_kib: v.after?.vm_rss_kb, rss_anon_kib: v.after?.rss_anon_kb,
      tables_anon_kib: v.delta_anon_kb } : null];
  }));
  const counters = load('rpc-status')?.reply?.counters ?? null;
  if (!idle || !full) {
    notMeasured('P2', 'no monitor daemon in the idle and/or full snapshot', { idle, full, reference_ucode: reference });
  } else {
    judge('P2', idle.rss_kib <= budgets.P2.idle_rss_kib && full.rss_kib <= budgets.P2.full_rss_kib, {
      idle, full, counters_at_full: counters, reference_ucode: reference, budget: budgets.P2,
      raw: ['p2-idle.json', 'p2-full.json', 'calib-memref-*.json']
    });
  }
}

// ---------------------------------------------------------------- P3
{
  const win = load('idle-on'), off = load('idle-off');
  const offRef = off ? { syslog_lines: off.log?.total, dnsmasq_log_lines: off.log?.dnsmasq,
    logd: wakeups(off, p => named(p, 'logd')), dnsmasq: wakeups(off, p => named(p, 'dnsmasq')) } : null;
  if (!win || !daemonProcs(win.t0.procs).length) {
    notMeasured('P3', 'no monitor daemon during the idle window', { off_reference: offRef });
  } else {
    const dW = wakeups(win, daemonProcs), cW = wakeups(win, childProcs);
    const daemonPids = new Set(daemonProcs(win.t0.procs).map(p => String(p.pid)));
    const waits = {};
    for (const s of win.syscall_samples) for (const [pid, line] of Object.entries(s.pids)) {
      if (!daemonPids.has(pid)) continue;
      const kind = classifySyscall(line);
      waits[kind] = (waits[kind] ?? 0) + 1;
    }
    const timed = Object.keys(waits).filter(k => k.startsWith('wait-timed'));
    const dnsLines = win.log?.dnsmasq ?? null, logLines = win.log?.total ?? null;
    const quiet = dnsLines === 0;
    // In a window with no dnsmasq line the daemon has nothing to read: every
    // voluntary switch is a timer (or other spurious) wakeup.
    const timerWakeups = quiet ? dW.voluntary : null;
    // logread may wake once per syslog line of any daemon; anything beyond that is excess.
    const excess = dW.total + cW.total - (logLines ?? 0);
    judge('P3', quiet && timerWakeups <= budgets.P3.daemon_timer_wakeups && timed.length === 0 &&
      excess <= budgets.P3.excess_wakeups, {
      window_s: win.seconds, quiet_window: quiet, dnsmasq_log_lines: dnsLines, syslog_lines: logLines,
      daemon_wakeups: dW, child_wakeups: cW, daemon_timer_wakeups: timerWakeups, excess_wakeups: excess,
      daemon_wait_samples: waits, off_reference: offRef, budget: budgets.P3, raw: ['idle-on.json', 'idle-off.json']
    });
  }
}

// ---------------------------------------------------------------- P4, P5, P6
const loads = {};
for (const state of ['off', 'on']) for (const q of rates) for (let r = 1; r <= repeats; r++) {
  (loads[`${state}-${q}`] ??= []).push({ r, win: load(`win-${state}-${q}-r${r}`), dns: load(`load-${state}-${q}-r${r}`) });
}
const daemonDuringLoad = Object.entries(loads).some(([k, runs]) =>
  k.startsWith('on-') && runs.some(x => x.win && daemonProcs(x.win.t0.procs).length));
{
  const out = {}; let pass = true; let measured = true;
  for (const q of rates) {
    const runs = loads[`on-${q}`];
    const pcts = runs.map(x => (x.win && daemonProcs(x.win.t0.procs).length ? cpuPct(x.win, packageProcs) : null));
    const value = median(pcts);
    out[q] = { cpu_pct_median: round(value), cpu_pct_runs: pcts.map(v => round(v)),
      dnsmasq_lines_per_window: runs.map(x => x.win?.log?.dnsmasq ?? null), budget: budgets.P4.cpu_pct[q] };
    if (value == null) measured = false;
    else if (value > budgets.P4.cpu_pct[q]) pass = false;
  }
  const bench = [1, 2, 3].map(i => load(`calib-parsebench-${i}`)?.us_per_line ?? null);
  const calibration = { regex_us_per_line_median: round(median(bench)), runs: bench.map(v => round(v)) };
  if (!measured) notMeasured('P4', 'no monitor daemon during the load windows', { rates: out, calibration });
  else judge('P4', pass, { rates: out, calibration, raw: ['win-on-*.json', 'calib-parsebench-*.json'] });
}
{
  const out = {}; let pass = true; let measured = true;
  for (const q of rates) {
    const p95 = state => loads[`${state}-${q}`].map(x => x.dns?.latency_ms?.p95).filter(Number.isFinite);
    const loss = state => loads[`${state}-${q}`].map(x => (x.dns ? (100 * x.dns.lost) / Math.max(1, x.dns.sent) : null));
    const off = p95('off'), on = p95('on');
    const spread = v => (v.length >= 2 ? Math.max(...v) - Math.min(...v) : null);
    const noise = spread(off);
    const delta = off.length && on.length ? median(on) - median(off) : null;
    const allowed = noise == null ? null : Math.max(budgets.P5.p95_delta_floor_ms, noise);
    const lossOn = Math.max(0, ...loss('on').filter(Number.isFinite));
    out[q] = { p95_off_ms: off, p95_on_ms: on, p95_off_median_ms: round(median(off), 3),
      p95_on_median_ms: round(median(on), 3), delta_ms: round(delta, 3), noise_floor_ms: round(noise, 3),
      noise_floor_on_ms: round(spread(on), 3), allowed_delta_ms: round(allowed, 3),
      p50_off_ms: loads[`off-${q}`].map(x => x.dns?.latency_ms?.p50 ?? null),
      p50_on_ms: loads[`on-${q}`].map(x => x.dns?.latency_ms?.p50 ?? null),
      loss_pct_off: loss('off').map(v => round(v, 3)), loss_pct_on: loss('on').map(v => round(v, 3)),
      samples_off: loads[`off-${q}`].reduce((n, x) => n + (x.dns?.received ?? 0), 0),
      samples_on: loads[`on-${q}`].reduce((n, x) => n + (x.dns?.received ?? 0), 0) };
    if (off.length < budgets.P5.min_runs || on.length < budgets.P5.min_runs || delta == null) measured = false;
    else if (delta > allowed || lossOn > budgets.P5.max_loss_pct) pass = false;
  }
  const info = { rates: out, monitor_daemon_present: daemonDuringLoad, budget: budgets.P5, raw: ['load-*.json'] };
  if (!measured) notMeasured('P5', `fewer than ${budgets.P5.min_runs} off and on load runs per rate`, info);
  else if (!daemonDuringLoad) notMeasured('P5', 'no monitor daemon during the on runs, so the delta excludes its cost', info);
  else judge('P5', pass, info);
}
{
  const out = {}; let pass = true; let measured = true;
  for (const q of rates) {
    out[q] = {};
    for (const comm of budgets.P6.processes) {
      const sel = procs => named(procs, comm);
      const cpu = state => median(loads[`${state}-${q}`].map(x => cpuPct(x.win, sel)));
      const anon = state => median(loads[`${state}-${q}`].map(x => (x.win ? sum(sel(x.win.t1.procs), 'rss_anon_kb') : null)));
      const [cOn, cOff, aOn, aOff] = [cpu('on'), cpu('off'), anon('on'), anon('off')];
      const dCpu = cOn != null && cOff != null ? cOn - cOff : null;
      const dAnon = aOn != null && aOff != null ? aOn - aOff : null;
      out[q][comm] = { cpu_off_pct: round(cOff), cpu_on_pct: round(cOn), cpu_delta_pp: round(dCpu),
        rss_anon_off_kib: aOff, rss_anon_on_kib: aOn, rss_anon_delta_kib: dAnon };
      if (dCpu == null) { measured = false; continue; }
      if (dCpu > budgets.P6.cpu_delta_pp[q] || (dAnon ?? 0) > budgets.P6.rss_anon_delta_kib) pass = false;
    }
    const busy = state => median(loads[`${state}-${q}`].map(x => {
      if (!x.win) return null;
      const total = c => Object.values(c).reduce((s, v) => s + v, 0) - c.idle - c.iowait;
      return ((total(x.win.t1.cpu) - total(x.win.t0.cpu)) / CLK_TCK / ((x.win.t1.wall_ms - x.win.t0.wall_ms) / 1000)) * 100;
    }));
    out[q].system_busy = { off_pct: round(busy('off')), on_pct: round(busy('on')), delta_pp: round(busy('on') - busy('off')),
      note: 'all guest CPUs, percent of one CPU' };
  }
  const info = { rates: out, monitor_daemon_present: daemonDuringLoad, budget: budgets.P6, raw: ['win-*.json'] };
  if (!measured) notMeasured('P6', 'load windows missing', info);
  else if (!daemonDuringLoad) notMeasured('P6', 'no monitor daemon during the on runs (deltas cover query logging only)', info);
  else judge('P6', pass, info);
}

// ---------------------------------------------------------------- P7
{
  const calls = { status: load('rpc-status'), domains_recent: load('rpc-domains-recent'),
    domains_recent_q: load('rpc-domains-recent-q'), domains_top_blocked: load('rpc-domains-top-blocked'),
    domains_top_allowed: load('rpc-domains-top-allowed') };
  const out = {}; let pass = true; let measured = true;
  for (const [name, c] of Object.entries(calls)) {
    out[name] = c ? { p50_ms: round(c.stats?.p50), p95_ms: round(c.stats?.p95), max_ms: round(c.stats?.max),
      n: c.stats?.n ?? 0, error: c.error ?? null, reply_bytes: c.reply_bytes ?? 0 } : null;
    if (!c || c.error || !c.stats?.n || c.reply?.ok !== true) { measured = false; continue; }
    if (c.stats.p95 > (name === 'status' ? budgets.P7.status_p95_ms : budgets.P7.domains_p95_ms)) pass = false;
  }
  const floor = { system_board_p95_ms: round(load('calib-rpc-system-board')?.stats?.p95),
    session_list_p95_ms: round(load('calib-rpc-session-list')?.stats?.p95) };
  const info = { calls: out, ubus_floor: floor, budget: budgets.P7, raw: ['rpc-*.json', 'calib-rpc-*.json'] };
  if (!measured) notMeasured('P7', 'adblock-fast-monitor status/domains unavailable', info);
  else judge('P7', pass, info);
}

// ---------------------------------------------------------------- P8, P9
{
  const ok = c => c && !c.error && c.stats?.n > 0 && c.reply?.ok === true;
  const dry = load('p8-apply-dry'), real = load('p8-apply'), probe = load('p9-rpcd-probe');
  const info = {
    dry_run: dry ? { p95_ms: round(dry.stats?.p95), max_ms: round(dry.stats?.max), error: dry.error ?? null, reply: dry.reply } : null,
    real: real ? { max_ms: round(real.stats?.max), error: real.error ?? null, reply: real.reply } : null,
    job: load('p8-job'), rpcd_probe: probe?.stats ?? null, budget: budgets.P8, raw: ['p8-*.json', 'p9-rpcd-probe.json'] };
  if (!ok(dry) || !ok(real)) notMeasured('P8', 'apply unavailable or rejected', info);
  else judge('P8', Math.max(dry.stats.max, real.stats.max) <= budgets.P8.apply_max_ms &&
    (probe?.stats?.max ?? Infinity) <= budgets.P9.rpcd_block_max_ms, info);

  const rules = load('p9-rules');
  const info9 = { rules: rules ? { times_ms: rules.times_ms?.map(v => round(v)), error: rules.error ?? null,
    reply_sample: rules.reply?.domains ? Object.fromEntries(Object.entries(rules.reply.domains).slice(0, 3)) : rules.reply } : null,
  rpcd_probe: probe?.stats ?? null, fixture: load('p9-fixture'), budget: budgets.P9, raw: ['p9-*.json'] };
  if (!ok(rules) || !probe?.stats?.n) notMeasured('P9', 'rules unavailable or rpcd probe missing', info9);
  else judge('P9', rules.times_ms[0] / 1000 <= budgets.P9.rules_cold_s && probe.stats.max <= budgets.P9.rpcd_block_max_ms, info9);
}

// ---------------------------------------------------------------- P10
{
  const enables = [], disables = [];
  for (let r = 1; r <= repeats; r++) {
    const on = load(`toggle-on-r${r}`), off = load(`toggle-off-r${r}`);
    if (on) enables.push({ r, restarts: on.dnsmasq_restarts, uci_changes: on.uci_changes, package_procs: on.package_proc_count, dropins: on.dropins });
    if (off) disables.push({ r, restarts: off.dnsmasq_restarts, uci_changes: off.uci_changes });
  }
  const save = load('p10-save'), bootOn = load('p10-boot-on'), bootOff = load('p10-boot-off');
  const boot = bootOn && bootOff ? bootOn.dnsmasq_starts_since_boot - bootOff.dnsmasq_starts_since_boot : null;
  const enabledDaemon = enables.some(e => e.package_procs > 0);
  const info = { boot_monitor_restarts: boot, boot_on: bootOn, boot_off: bootOff, enable: enables,
    save: save ? { restarts: save.dnsmasq_restarts, uci_changes: save.uci_changes, package_procs: save.package_proc_count } : null,
    disable: disables, budget: budgets.P10, raw: ['toggle-*.json', 'p10-*.json'] };
  if (boot == null || !save || !enables.length) notMeasured('P10', 'boot, enable or save phase missing', info);
  else judge('P10', boot === budgets.P10.boot && enables.every(e => e.restarts === budgets.P10.enable) &&
    save.dnsmasq_restarts === budgets.P10.save && enabledDaemon,
  { ...info, ...(enabledDaemon ? {} : { reason: 'enabling started no monitor process' }) });
}

// ---------------------------------------------------------------- verdict
const order = ['P1', 'P2', 'P3', 'P4', 'P5', 'P6', 'P7', 'P8', 'P9', 'P10'];
const failed = order.filter(id => metrics[id]?.verdict !== 'PASS');
const summary = {
  run: relative(root, runDir), measured_at: run.finished_at,
  environment: { accel: meta.accel, guest_cpus: meta.guest_cpus, guest_memory_mib: meta.guest_memory_mib,
    host: meta.host_uname, package_file: meta.package_file, package_sha256: meta.package_sha256,
    repeats: meta.repeats, load_seconds: meta.load_seconds, idle_seconds: meta.idle_seconds, rates: meta.rates },
  harness_errors: run.errors ?? [], metrics
};
const verdict = { verdict: failed.length ? 'FAIL' : 'PASS', failed, run: summary.run, accel: meta.accel ?? null,
  per_metric: Object.fromEntries(order.map(id => [id, metrics[id]?.verdict ?? 'NOT_MEASURED'])) };
writeFileSync(join(runDir, 'summary.json'), `${JSON.stringify(summary, null, 1)}\n`);
writeFileSync(join(runDir, 'verdict.json'), `${JSON.stringify(verdict, null, 1)}\n`);

console.log(`P0 performance gate: ${summary.run} (accel ${meta.accel ?? '?'})`);
for (const id of order) {
  const m = metrics[id] ?? { verdict: 'NOT_MEASURED' };
  console.log(`  ${id.padEnd(4)} ${m.verdict.padEnd(12)} ${m.reason ?? ''}`);
}
if (summary.harness_errors.length) console.log(`  harness errors: ${summary.harness_errors.join('; ')}`);
console.log(`${verdict.verdict}: ${failed.length ? `${failed.join(', ')} not within budget or not measured` : 'all P0 budgets met'}` +
  ` (details: ${relative(root, join(runDir, 'summary.json'))})`);
process.exit(failed.length ? 1 : 0);
