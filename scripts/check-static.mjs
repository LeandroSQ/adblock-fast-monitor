import { readdir, readFile } from 'node:fs/promises';
import { join, relative } from 'node:path';
import { spawnSync } from 'node:child_process';
import { projectRoot } from './lib/manifest.mjs';

const ignored = new Set(['node_modules', 'dist', '.git', '.ci-work', '.local-validation']);
const files = [];

async function walk(directory) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    if (ignored.has(entry.name)) continue;
    const path = join(directory, entry.name);
    if (entry.isDirectory()) await walk(path);
    else files.push(path);
  }
}

await walk(projectRoot);
const failures = [];
for (const path of files) {
  const name = relative(projectRoot, path);
  if (name.endsWith('.mjs') || name.endsWith('.js')) {
    const result = spawnSync(process.execPath, ['--check', path], { encoding: 'utf8' });
    if (result.status !== 0) failures.push(`${name}: ${result.stderr.trim()}`);
  }
  if (name.endsWith('.json')) {
    try {
      JSON.parse(await readFile(path, 'utf8'));
    } catch (error) {
      failures.push(`${name}: invalid JSON (${error.message})`);
    }
  }
  if (name.endsWith('.sh')) {
    const result = spawnSync('bash', ['-n', path], { encoding: 'utf8' });
    if (result.status !== 0) failures.push(`${name}: ${result.stderr.trim()}`);
  }
}

if (failures.length) {
  console.error(`Static/language check failed:\n- ${failures.join('\n- ')}`);
  process.exitCode = 1;
} else {
  console.log(`Static/language check passed (${files.length} files scanned).`);
}
