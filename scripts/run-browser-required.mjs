import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { resolve } from 'node:path';
import { projectRoot } from './lib/manifest.mjs';

const baseURL = process.env.MONITOR_BASE_URL;
if (!baseURL) {
  console.error(
    'Browser verification prerequisite blocked: set MONITOR_BASE_URL to the real LuCI/QEMU URL. ' +
    'This command never starts or substitutes a mock server.'
  );
  process.exit(2);
}

try {
  const parsed = new URL(baseURL);
  if (!/^https?:$/.test(parsed.protocol)) throw new Error('unsupported protocol');
} catch {
  console.error(`Browser verification prerequisite blocked: MONITOR_BASE_URL is not an http(s) URL: ${baseURL}`);
  process.exit(2);
}

const testDir = resolve(projectRoot, 'test/browser');
if (!existsSync(testDir)) {
  console.error(`Browser verification prerequisite blocked: Playwright tests are absent: ${testDir}`);
  process.exit(2);
}

const result = spawnSync('npx', ['playwright', 'test', '--config', 'test/browser/playwright.config.mjs'], {
  cwd: projectRoot,
  env: process.env,
  stdio: 'inherit'
});
process.exit(result.status ?? 1);
