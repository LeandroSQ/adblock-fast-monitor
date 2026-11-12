// SPDX-License-Identifier: Apache-2.0
// Writes synthetic scripts/perf/run.sh run directories for the gate's unit
// tests (test/unit/perf-gate.test.mjs). Every file has the shape the guest
// probe and the harness write; values are chosen per test.
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

export const root = resolve(import.meta.dirname, '../../..');
// Scratch space inside the repository's ignored cache, removed by the tests.
export const scratch = join(root, '.local-validation', 'scratch', `perf-gate-${process.pid}`);

let nextPid = 1000;
export function proc(cmdline, extra = {}) {
  const pid = extra.pid ?? nextPid++;
  return { pid, ppid: 1, comm: '', cmdline, kthread: false, state: 'S', utime: 0, stime: 0, cutime: 0, cstime: 0,
    starttime: pid, rss_anon_kb: 100, vctx: 0, nvctx: 0, ...extra };
}
export const kthread = (comm, extra = {}) => proc('', { comm, kthread: true, rss_anon_kb: 0, ...extra });

// A stock-like task table (userland and one kernel thread).
export function baseProcs({ rpcdAnon = 556 } = {}) {
  return [
    proc('/sbin/procd', { pid: 1, ppid: 0, comm: 'procd' }),
    proc('/sbin/ubusd', { pid: 500, comm: 'ubusd' }),
    proc('/sbin/logd -S 128', { pid: 501, comm: 'logd' }),
    proc('/sbin/rpcd -s /var/run/ubus/ubus.sock -t 30', { pid: 502, comm: 'rpcd', rss_anon_kb: rpcdAnon }),
    proc('/usr/sbin/uhttpd -f -h /www', { pid: 503, comm: 'uhttpd' }),
    proc('/usr/sbin/dnsmasq -C /var/etc/dnsmasq.conf.cfg01411c -k', { pid: 504, comm: 'dnsmasq' }),
    kthread('ksoftirqd/0', { pid: 10, ppid: 2 })
  ];
}

const cpu = (ncpu = 2) => ({ user: 0, nice: 0, system: 0, idle: 0, iowait: 0, irq: 0, softirq: 0, steal: 0, ncpu });
export const snapshot = (procs, extra = {}) =>
  ({ uptime_s: 100, wall_ms: 0, meminfo: { MemAvailable: 150000 }, cpu: cpu(), procs, ...extra });

export const watch = (procs = [], seconds = 15, interval = 250, uptime = 100) =>
  ({ seconds, interval_ms: interval, uptime_at_start_s: uptime, scans: (seconds * 1000) / interval, duration_ms: seconds * 1000, seen: {}, procs });

// A load window of SECONDS with CPU ticks used by dnsmasq, logd and an
// unmeasured task (procd). `lostTicks` removes ticks from the task total (a
// child whose time no live task accounts for), so the measured processes can
// exceed it; `kthreads: false` mimics a probe without kernel threads.
export function win({ dnsmasq = 0, logd = 0, other = 0, seconds = 30, ncpu = 2, lostTicks = 0, kthreads = true } = {}) {
  const t0 = baseProcs(), t1 = baseProcs();
  const bump = (procs, comm, ticks) => { procs.find(x => x.comm === comm).utime += ticks; };
  bump(t1, 'dnsmasq', dnsmasq); bump(t1, 'logd', logd); bump(t1, 'procd', other);
  t0.find(p => p.comm === 'procd').cutime = lostTicks;
  const strip = procs => (kthreads ? procs : procs.filter(p => !p.kthread));
  return { tag: 'w', seconds, t0: snapshot(strip(t0), { wall_ms: 0, cpu: cpu(ncpu) }),
    t1: snapshot(strip(t1), { wall_ms: seconds * 1000, cpu: cpu(ncpu) }), package_pids: [] };
}
export const dnsLoad = (p95, { p50 = p95 / 2, sent = 1500, lost = 0 } = {}) =>
  ({ sent, received: sent - lost, lost, latency_ms: { p50, p95 } });

export const toggle = (on, restarts) => ({ action: `query_logging=${on ? 1 : 0}`, uci_changes: 1, dnsmasq_restarts: restarts,
  settle_s: 7, query_logging: on ? '1' : '0', package_procs: '', package_proc_count: 0, plugin_object: true,
  dropins: on ? '/tmp/dnsmasq.cfg01411c.d/adblock-fast-monitor.conf' : '', manual_dropins: '', dnsmasq_pids: '504' });

export const INIT_RELOAD = '/bin/sh /etc/rc.common /etc/init.d/adblock-fast-monitor reload';
export const INIT_RUNNING = '/bin/sh /etc/rc.common /etc/init.d/adblock-fast-monitor running';

// A data set in which P1, P2 and P10 pass; tests change single files.
export function passingFiles() {
  const files = {
    'meta-host': { accel: 'hvf', guest: 'armsr-hvf', guest_target: 'armsr-armv8', rates: [50], repeats: 3, browser: true },
    'browser-p2': { phases: {
      visible_control: { from_ms: 0, to_ms: 12000, requests: 6 },
      hidden: { from_ms: 12000, to_ms: 72300, requests: 0, method: 'emulated', urls: [], router_ticks: {} },
      resumed: { first_request_after_ms: 5 },
      closed: { from_ms: 72400, to_ms: 132700, requests: 0, router_ticks: {} } }, errors: [] },
    'p10-save': { dnsmasq_restarts: 0, uci_changes: 1 },
    'p10-unsave': { dnsmasq_restarts: 0 },
    'p10-boot-on': { boot: true, dnsmasq_starts_since_boot: 1 },
    'p10-boot-off': { boot: true, dnsmasq_starts_since_boot: 1 },
    'toggle-on-r0': toggle(true, 1), 'toggle-on-r1': toggle(true, 1), 'toggle-off-r1': toggle(false, 1)
  };
  for (let i = 1; i <= 3; i++) {
    files[`p1-stock-${i}`] = snapshot(baseProcs());
    files[`p1-installed-off-${i}`] = snapshot(baseProcs({ rpcdAnon: 768 }));
    files[`p1-installed-on-${i}`] = snapshot(baseProcs({ rpcdAnon: 768 }));
    for (const st of ['on', 'off']) files[`p1-after-boot-${st}-${i}`] = snapshot(baseProcs({ rpcdAnon: 768 }));
  }
  for (const w of ['installed-off', 'installed-on', 'after-boot-off', 'idle-after-boot-on', 'idle-after-boot-off']) {
    files[`p1-${w}-watch`] = watch();
  }
  // One trigger firing at the logging-on boot: `reload`, then procd's
  // `running` check, whose ubus child belongs to that invocation.
  files['p1-after-boot-on-watch'] = watch([
    { pid: 900, ppid: 1, cmdline: INIT_RELOAD, first_ms: 2400, last_ms: 2600, samples: 3 },
    { pid: 910, ppid: 1, cmdline: INIT_RUNNING, first_ms: 2700, last_ms: 2800, samples: 2 },
    { pid: 911, ppid: 910, cmdline: 'ubus call service list {"name":"adblock-fast-monitor"}', first_ms: 2700, last_ms: 2700, samples: 1 }
  ], 30, 100, 19);
  return files;
}

// P6 load windows: for each state, one window spec per repeat.
export function p6Files(byState, rate = 50) {
  const files = {};
  for (const [state, runs] of Object.entries(byState)) {
    runs.forEach((spec, i) => {
      files[`win-${state}-${rate}-r${i + 1}`] = win(spec);
      files[`load-${state}-${rate}-r${i + 1}`] = dnsLoad(5);
    });
  }
  return files;
}

let count = 0;
export function writeRun(files) {
  const dir = join(scratch, `run-${count++}`);
  rmSync(dir, { recursive: true, force: true });
  mkdirSync(join(dir, 'raw'), { recursive: true });
  for (const [name, value] of Object.entries(files)) {
    if (value !== undefined) writeFileSync(join(dir, 'raw', `${name}.json`), JSON.stringify(value));
  }
  writeFileSync(join(dir, 'run.json'), JSON.stringify({ harness: 'scripts/perf/run.sh', finished_at: 'synthetic', errors: [] }));
  return dir;
}
