import { access, mkdir, rm } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import { resolve } from 'node:path';
import { projectRoot, readManifest } from '../lib/manifest.mjs';

for (const name of ['OPENWRT_HOST', 'OPENWRT_SSH_PORT', 'OPENWRT_SSH_KEY']) {
  if (!process.env[name]) throw new Error(`${name} is required for isolated QEMU performance measurement.`);
}

const adapter = resolve(projectRoot, 'scripts/integration/measure-monitor-resident.sh');
const dnsProbe = resolve(projectRoot, 'scripts/integration/dns-probe.mjs');
await access(adapter);
await access(dnsProbe);
const manifest = await readManifest();
const output = resolve(projectRoot, manifest.requiredAdapters.performance);
await mkdir(resolve(projectRoot, '.ci-work'), { recursive: true });
await rm(output, { force: true });

const child = spawn(adapter, [output, ...manifest.fixtureLists.map(path => resolve(projectRoot, path))], {
  cwd: projectRoot,
  env: { ...process.env, MONITOR_DNS_PROBE: dnsProbe },
  stdio: 'inherit'
});
const code = await new Promise((resolveExit, reject) => {
  child.once('error', reject);
  child.once('exit', status => resolveExit(status ?? 1));
});
if (code !== 0) process.exit(code);
