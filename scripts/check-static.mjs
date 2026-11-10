// Syntax checks for every source language in the repository:
//   - JSON: JSON.parse
//   - JS/MJS outside LuCI: node --check
//   - LuCI views/resources (root/www/**/*.js): compiled (not run) as a function
//     body, because LuCI evaluates them that way and they may `return` at top level
//   - bash scripts (bash shebang or "# shellcheck shell=bash"): bash -n
//   - POSIX sh scripts, including extensionless ones (#!/bin/sh): `ash -n` under
//     OpenWrt 25.12.6's BusyBox in the host userland container
//   - ucode (*.uc or #!/usr/bin/ucode): `ucode -c` with the pinned interpreter
// The container checks need Docker; set ABFM_STATIC_NO_CONTAINER=1 to skip them
// explicitly (reported as skipped, never as passed).
import { readdir, readFile } from 'node:fs/promises';
import { join, relative } from 'node:path';
import { spawnSync } from 'node:child_process';
import vm from 'node:vm';
import { projectRoot } from './lib/manifest.mjs';

const ignored = new Set(['node_modules', 'dist', '.git', '.ci-work', '.local-validation', 'playwright-report', 'test-results']);
const files = [];

async function walk(directory) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    if (ignored.has(entry.name)) continue;
    const path = join(directory, entry.name);
    if (entry.isDirectory()) await walk(path);
    else if (entry.isFile()) files.push(path);
  }
}

await walk(projectRoot);
const failures = [];
const ash = [];
const ucode = [];
let checked = 0;

for (const path of files) {
  const name = relative(projectRoot, path);
  const base = name.split('/').pop();
  const hasExtension = base.includes('.');
  let head = '';
  if (!hasExtension || /\.(sh|uc)$/.test(base)) {
    head = (await readFile(path, 'utf8')).slice(0, 4096);
  }
  const shebang = head.startsWith('#!') ? head.split('\n', 1)[0] : '';

  if (/\.(mjs|cjs|js)$/.test(base)) {
    checked++;
    if (name.startsWith('root/www/')) {
      try {
        new vm.Script(`(function () {\n${await readFile(path, 'utf8')}\n})`, { filename: name, lineOffset: -1 });
      } catch (error) {
        failures.push(`${name}: ${error.message}`);
      }
    } else {
      const result = spawnSync(process.execPath, ['--check', path], { encoding: 'utf8' });
      if (result.status !== 0) failures.push(`${name}: ${result.stderr.trim()}`);
    }
  } else if (base.endsWith('.json')) {
    checked++;
    try {
      JSON.parse(await readFile(path, 'utf8'));
    } catch (error) {
      failures.push(`${name}: invalid JSON (${error.message})`);
    }
  } else if (base.endsWith('.uc') || /\bucode\b/.test(shebang)) {
    checked++;
    ucode.push(name);
  } else if (/\bbash\b/.test(shebang) || (base.endsWith('.sh') && /^# shellcheck shell=bash$/m.test(head))) {
    checked++;
    const result = spawnSync('bash', ['-n', path], { encoding: 'utf8' });
    if (result.status !== 0) failures.push(`${name}: ${result.stderr.trim()}`);
  } else if (base.endsWith('.sh') || /^#!\s*\/bin\/(ash|sh)\b/.test(shebang)) {
    checked++;
    ash.push(name);
  }
}

const containerScript = `
rc=0
mode=ash
for f in "$@"; do
  case "$f" in
    --ucode) mode=ucode; continue ;;
  esac
  if [ "$mode" = ash ]; then
    out=$(ash -n "$f" 2>&1) || { printf '%s: ash -n: %s\\n' "$f" "$out"; rc=1; }
  else
    out=$(ucode -c -o /dev/null "$f" 2>&1) || { printf '%s: ucode -c: %s\\n' "$f" "$(printf '%s' "$out" | head -n 6)"; rc=1; }
  fi
done
exit $rc
`;

let skipped = '';
if (ash.length || ucode.length) {
  if (process.env.ABFM_STATIC_NO_CONTAINER === '1') {
    skipped = ` SKIPPED ${ash.length} BusyBox sh and ${ucode.length} ucode checks (ABFM_STATIC_NO_CONTAINER=1).`;
  } else {
    const result = spawnSync(
      join(projectRoot, 'test/lib/userland'),
      ['--', '/bin/ash', '-c', containerScript, 'check-static', ...ash, '--ucode', ...ucode],
      { encoding: 'utf8' }
    );
    if (result.error) failures.push(`userland container: ${result.error.message}`);
    else if (result.status !== 0) {
      const output = `${result.stdout}${result.stderr}`.trim();
      failures.push(output || `userland container exited ${result.status}`);
    }
  }
}

if (failures.length) {
  console.error(`Static/language check failed:\n- ${failures.join('\n- ')}`);
  process.exitCode = 1;
} else {
  console.log(
    `Static/language check passed: ${checked} files (${ash.length} BusyBox sh, ${ucode.length} ucode).${skipped}`
  );
}
