// SPDX-License-Identifier: Apache-2.0
// T26: scripts/performance-gate.mjs judges synthetic run directories (the
// shapes scripts/perf/run.sh and the guest probe write). The real gate runs
// as a child process; its verdict.json and summary.json are checked.
import { after, test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { INIT_RELOAD, INIT_RUNNING, p6Files, passingFiles, proc, root, scratch, snapshot, baseProcs, toggle, watch, writeRun } from './helpers/perf-run.mjs';

after(() => rmSync(scratch, { recursive: true, force: true }));

function gate(files) {
  const dir = writeRun(files);
  const r = spawnSync(process.execPath, [join(root, 'scripts/performance-gate.mjs'), dir], { encoding: 'utf8' });
  assert.equal(r.error, undefined);
  const verdict = JSON.parse(readFileSync(join(dir, 'verdict.json'), 'utf8'));
  const summary = JSON.parse(readFileSync(join(dir, 'summary.json'), 'utf8'));
  return { status: r.status, out: r.stdout, verdict, summary, metric: id => summary.metrics[id] };
}
const edit = fn => { const f = passingFiles(); fn(f); return f; };

test('T26: P1, P2 and P10 pass on a clean run; unmeasured metrics fail the gate', () => {
  const g = gate(passingFiles());
  assert.equal(g.verdict.per_metric.P1, 'PASS', JSON.stringify(g.metric('P1').found));
  assert.equal(g.verdict.per_metric.P2, 'PASS');
  assert.equal(g.verdict.per_metric.P10, 'PASS');
  assert.equal(g.metric('P1').transient.boot_max_invocations, 2);
  assert.equal(g.verdict.per_metric.P7, 'NOT_MEASURED');
  assert.equal(g.verdict.verdict, 'FAIL');
  assert.notEqual(g.status, 0);
});

test('T26: P1 fails on a resident package process in a snapshot', () => {
  const g = gate(edit(f => {
    f['p1-installed-on-2'] = snapshot([...baseProcs({ rpcdAnon: 768 }), proc('/usr/bin/ucode /usr/libexec/adblock-fast-monitor/daemon.uc')]);
  }));
  assert.equal(g.verdict.per_metric.P1, 'FAIL');
  assert.ok(g.metric('P1').found.some(x => x.includes('daemon.uc')));
});

test('T26: P1 counts init-script descendants as part of a transient invocation, within the lifetime limit', () => {
  const g = gate(edit(f => {
    f['p1-after-boot-on-watch'].procs.push({ pid: 912, ppid: 911, cmdline: 'jsonfilter -e @.adblock-fast-monitor', first_ms: 2700, last_ms: 2800, samples: 2 });
  }));
  assert.equal(g.verdict.per_metric.P1, 'PASS');
  assert.equal(g.metric('P1').package_processes, 0);
  assert.equal(g.metric('P1').transient.boot_max_invocations, 2);
});

test('T26: P1 fails when an init invocation or its descendant outlives the lifetime limit', () => {
  const long = gate(edit(f => { f['p1-after-boot-on-watch'].procs[0].last_ms = 2400 + 11000; }));
  assert.equal(long.verdict.per_metric.P1, 'FAIL');
  const child = gate(edit(f => { f['p1-after-boot-on-watch'].procs[2].last_ms = 2700 + 12000; }));
  assert.equal(child.verdict.per_metric.P1, 'FAIL');
  assert.ok(child.metric('P1').found.some(x => x.includes('ubus call service list')));
});

test('T26: P1 fails on more than two invocations per boot or any while idle', () => {
  const boot = gate(edit(f => {
    f['p1-after-boot-on-watch'].procs.push({ pid: 950, ppid: 1, cmdline: INIT_RELOAD, first_ms: 9000, last_ms: 9100, samples: 2 });
  }));
  assert.equal(boot.verdict.per_metric.P1, 'FAIL');
  const idle = gate(edit(f => {
    f['p1-idle-after-boot-on-watch'] = watch([{ pid: 960, ppid: 1, cmdline: INIT_RELOAD, first_ms: 100, last_ms: 200, samples: 2 }], 60, 100);
  }));
  assert.equal(idle.verdict.per_metric.P1, 'FAIL');
  assert.equal(idle.metric('P1').transient.idle_invocations, 1);
});

test('T26: P1 is not measured without stock snapshots', () => {
  const g = gate(edit(f => { for (const i of [1, 2, 3]) delete f[`p1-stock-${i}`]; }));
  assert.equal(g.verdict.per_metric.P1, 'NOT_MEASURED');
});

test('T26: P2 fails on one request while hidden or closed', () => {
  const hidden = gate(edit(f => { f['browser-p2'].phases.hidden.requests = 1; }));
  assert.equal(hidden.verdict.per_metric.P2, 'FAIL');
  const closed = gate(edit(f => { f['browser-p2'].phases.closed.requests = 1; }));
  assert.equal(closed.verdict.per_metric.P2, 'FAIL');
});

test('T26: P2 is not measured without the run, a working counter or a full window', () => {
  assert.equal(gate(edit(f => { delete f['browser-p2']; })).verdict.per_metric.P2, 'NOT_MEASURED');
  assert.equal(gate(edit(f => { f['browser-p2'].phases.visible_control.requests = 0; })).verdict.per_metric.P2, 'NOT_MEASURED');
  assert.equal(gate(edit(f => { f['browser-p2'].phases.hidden.to_ms = 50000; })).verdict.per_metric.P2, 'NOT_MEASURED');
});

test('T26: P10 fails on a boot restart difference, an extra enable restart or a restart on save', () => {
  assert.equal(gate(edit(f => { f['p10-boot-on'].dnsmasq_starts_since_boot = 2; })).verdict.per_metric.P10, 'FAIL');
  assert.equal(gate(edit(f => { f['toggle-on-r1'] = toggle(true, 2); })).verdict.per_metric.P10, 'FAIL');
  assert.equal(gate(edit(f => { f['p10-save'].dnsmasq_restarts = 1; })).verdict.per_metric.P10, 'FAIL');
});

test('T26: P10 is not measured when a boot report is missing', () => {
  assert.equal(gate(edit(f => { delete f['p10-boot-off']; })).verdict.per_metric.P10, 'NOT_MEASURED');
});

// 30 s windows: 30 ticks = 1 % of one CPU.
const ticks = pct => Math.round(pct * 30);
const spec = (dnsmasq, logd = 1) => ({ dnsmasq: ticks(dnsmasq), logd: ticks(logd), other: ticks(5) });

test('T26: P6 passes when the package adds nothing beyond the hand-written drop-in', () => {
  const g = gate({ ...passingFiles(), ...p6Files({ off: [spec(5), spec(5), spec(5)], manual: [spec(8), spec(8.5), spec(7.5)], on: [spec(8), spec(8.2), spec(8.4)] }) });
  assert.equal(g.verdict.per_metric.P6, 'PASS', JSON.stringify(g.metric('P6').rates['50'].dnsmasq));
  assert.equal(g.metric('P6').rates['50'].dnsmasq.cpu_delta_pp, 3.2);
  assert.equal(g.metric('P6').rates['50'].dnsmasq.package_vs_manual_pp, 0.2);
  assert.equal(g.summary.windows.invalid, 0);
});

test('T26: P6 fails when the package costs more than dnsmasq logging alone, beyond the noise', () => {
  const g = gate({ ...passingFiles(), ...p6Files({ off: [spec(5), spec(5), spec(5)], manual: [spec(6), spec(6.2), spec(6.1)], on: [spec(8), spec(8.2), spec(8.1)] }) });
  assert.equal(g.verdict.per_metric.P6, 'FAIL');
  assert.equal(g.metric('P6').rates['50'].dnsmasq.package_vs_manual_pp, 2);
  assert.equal(g.metric('P6').rates['50'].dnsmasq.package_allowed_pp, 0.5);
});

test('T26: P6 fails when query logging costs more than the budget (on − off)', () => {
  const g = gate({ ...passingFiles(), ...p6Files({ off: [spec(1), spec(1), spec(1)], manual: [spec(13), spec(13), spec(13)], on: [spec(13), spec(13), spec(13)] }) });
  assert.equal(g.verdict.per_metric.P6, 'FAIL');
  assert.equal(g.metric('P6').rates['50'].dnsmasq.cpu_delta_pp, 12);
});

test('T26: a window whose processes exceed the task-based system total is invalid and excluded', () => {
  const bad = { ...spec(8), lostTicks: ticks(20) };
  const g = gate({ ...passingFiles(), ...p6Files({ off: [spec(5), spec(5), spec(5)], manual: [spec(8), spec(8), spec(8)], on: [bad, spec(8), spec(8)] }) });
  assert.equal(g.summary.windows.invalid, 1);
  assert.match(g.summary.windows.list[0].reasons[0], /exceed the system total/);
  assert.equal(g.metric('P6').rates['50'].dnsmasq.cpu_on_pct_runs[0], null);
  assert.equal(g.verdict.per_metric.P6, 'NOT_MEASURED');
});

test('T26: a window beyond the guest CPUs, or without kernel threads, is invalid', () => {
  const g = gate({ ...passingFiles(), ...p6Files({ off: [spec(5), spec(5), spec(5)], manual: [spec(8), spec(8), spec(8)],
    on: [{ ...spec(8), other: ticks(250) }, { ...spec(8), kthreads: false }, spec(8)] }) });
  assert.equal(g.summary.windows.invalid, 2);
  const reasons = g.summary.windows.list.flatMap(w => w.reasons).join(' | ');
  assert.match(reasons, /exceeds 2 CPUs/);
  assert.match(reasons, /no kernel threads/);
});

test('T26: P1 counts the boot start apart from trigger invocations, with its own limit', () => {
  const S18 = '/bin/sh /etc/rc.common /etc/rc.d/S18adblock-fast-monitor boot';
  const bootWatch = extra => watch([
    { pid: 800, ppid: 1, cmdline: S18, first_ms: 400, last_ms: 600, samples: 2 },
    { pid: 801, ppid: 800, cmdline: '/usr/bin/ucode /usr/libexec/adblock-fast-monitor/logging.uc reconcile', first_ms: 500, last_ms: 500, samples: 1 },
    { pid: 900, ppid: 1, cmdline: INIT_RUNNING, first_ms: 700, last_ms: 700, samples: 1 },
    { pid: 950, ppid: 1, cmdline: '/usr/bin/ucode /usr/libexec/adblock-fast-monitor/logging.uc reconcile', first_ms: 10100, last_ms: 10200, samples: 2 },
    ...extra
  ], 60, 100, 9);
  const ok = gate(edit(f => { f['p1-after-boot-on-watch'] = bootWatch([]); }));
  assert.equal(ok.verdict.per_metric.P1, 'PASS', JSON.stringify(ok.metric('P1').found));
  assert.equal(ok.metric('P1').transient.boot_max_starts, 1);
  assert.equal(ok.metric('P1').transient.boot_max_invocations, 2);
  const twice = gate(edit(f => {
    f['p1-after-boot-on-watch'] = bootWatch([{ pid: 990, ppid: 1, cmdline: S18, first_ms: 20000, last_ms: 20100, samples: 2 }]);
  }));
  assert.equal(twice.verdict.per_metric.P1, 'FAIL');
});
