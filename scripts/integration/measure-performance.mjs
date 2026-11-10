#!/usr/bin/env node
// T26 entrypoint: measures the P0 budgets (docs/CONTRACT.md §11) of an APK on
// a fresh OpenWrt 25.12.6 guest and runs the gate on the result.
//
//   node scripts/integration/measure-performance.mjs PACKAGE.apk
//   (PACKAGE_APK=... also works; ABFM_PERF_* tune scripts/perf/run.sh)
//
// Boots the guest with scripts/verify-guest.sh (in Docker on non-Linux hosts)
// without installing the APK, runs scripts/perf/run.sh as the host command,
// writes raw JSON to .local-validation/perf/<run>/ and exits with the verdict
// of scripts/performance-gate.mjs.
import { spawnSync } from 'node:child_process';
import { existsSync, realpathSync } from 'node:fs';
import { join, relative, resolve } from 'node:path';

const root = resolve(import.meta.dirname, '../..');
const apkArg = process.argv[2] ?? process.env.PACKAGE_APK;
if (!apkArg || !existsSync(apkArg)) {
  console.error('usage: measure-performance.mjs PACKAGE.apk (inside the worktree or .local-validation/)');
  process.exit(2);
}
// Paths must resolve inside the validation container: worktree-relative, or
// under the shared cache, which is mounted at its real absolute path.
const visible = path => {
  const abs = realpathSync(resolve(path));
  const rel = relative(realpathSync(root), abs);
  return rel.startsWith('..') ? abs : rel;
};
const stamp = new Date().toISOString().replace(/[-:]/g, '').replace(/\.\d+Z$/, 'Z');
const runId = `${stamp}-${process.pid}`;
const out = join('.local-validation', 'perf', runId);

const measure = spawnSync(join(root, 'scripts/verify-guest.sh'),
  ['--no-install', '--no-tests', '--host-cmd', 'scripts/perf/run.sh', visible(apkArg)],
  { cwd: root, stdio: 'inherit', env: { ...process.env, ABFM_PERF_OUT: out } });
if (measure.status !== 0) console.error(`measure-performance: guest run exited ${measure.status}; evaluating what was recorded`);
const gate = spawnSync(process.execPath, [join(root, 'scripts/performance-gate.mjs'), join(root, out)],
  { cwd: root, stdio: 'inherit' });
process.exit(gate.status ?? 1);
