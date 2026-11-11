// Syntax checks for every source language in the repository:
//   - JSON: JSON.parse
//   - JS/MJS outside LuCI: node --check
//   - LuCI views/resources (root/www/ or htdocs/ **/*.js): compiled (not run)
//     as a function body, because LuCI evaluates them that way and they may
//     `return` at top level
//   - bash scripts (bash shebang or "# shellcheck shell=bash"): bash -n
//   - Python helpers (*.py or python shebang): ast.parse with python3
//   - POSIX sh scripts, including extensionless ones (#!/bin/sh): `ash -n` under
//     OpenWrt 25.12.6's BusyBox in the host userland container
//   - ucode (*.uc, #!/usr/bin/ucode, rpcd plugins in root/usr/share/rpcd/ucode/):
//     `ucode -c` with the pinned interpreter
// A shipped file (root/, htdocs/) that no checker claims fails the check.
// The container checks need Docker; set ABFM_STATIC_NO_CONTAINER=1 to skip them
// explicitly (reported as skipped, never as passed). Without python3 the
// Python check is skipped too, except under CI (where it fails).
// Style and lint (ESLint, ShellCheck, actionlint, markdownlint): npm run lint.
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import vm from 'node:vm';
import { projectRoot } from './lib/root.mjs';
import { classify, isShipped, listFiles } from './lint/files.mjs';

const failures = [];
const ash = [];
const ucode = [];
const python = [];
let checked = 0;
let skipped = '';

for (const name of await listFiles()) {
  const path = join(projectRoot, name);
  const kind = await classify(name);
  if (kind && kind !== 'data') checked++;

  if (kind === 'luci') {
    try {
      new vm.Script(`(function () {\n${await readFile(path, 'utf8')}\n})`, { filename: name, lineOffset: -1 });
    } catch (error) {
      failures.push(`${name}: ${error.message}`);
    }
  } else if (kind === 'js') {
    const result = spawnSync(process.execPath, ['--check', path], { encoding: 'utf8' });
    if (result.status !== 0) failures.push(`${name}: ${result.stderr.trim()}`);
  } else if (kind === 'json') {
    try {
      JSON.parse(await readFile(path, 'utf8'));
    } catch (error) {
      failures.push(`${name}: invalid JSON (${error.message})`);
    }
  } else if (kind === 'ucode') {
    ucode.push(name);
  } else if (kind === 'bash') {
    const result = spawnSync('bash', ['-n', path], { encoding: 'utf8' });
    if (result.status !== 0) failures.push(`${name}: ${result.stderr.trim()}`);
  } else if (kind === 'ash') {
    ash.push(name);
  } else if (kind === 'python') {
    python.push(name);
  } else if (!kind && isShipped(name)) {
    failures.push(`${name}: shipped file that no checker claims; classify it in scripts/lint/files.mjs`);
  }
}

if (python.length) {
  const result = spawnSync('python3', ['-c', 'import ast,sys\nfor p in sys.argv[1:]: ast.parse(open(p,"rb").read(), p)', ...python],
    { cwd: projectRoot, encoding: 'utf8' });
  if (result.error?.code === 'ENOENT') {
    if (process.env.CI) failures.push('python3 not found (needed for the Python syntax check)');
    else skipped += ` SKIPPED ${python.length} Python checks (python3 not found).`;
  } else if (result.status !== 0) {
    failures.push(`python ast.parse: ${`${result.stdout}${result.stderr}`.trim()}`);
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

if (ash.length || ucode.length) {
  if (process.env.ABFM_STATIC_NO_CONTAINER === '1') {
    skipped += ` SKIPPED ${ash.length} BusyBox sh and ${ucode.length} ucode checks (ABFM_STATIC_NO_CONTAINER=1).`;
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
    `Static/language check passed: ${checked} files (${ash.length} BusyBox sh, ${ucode.length} ucode, ` +
    `${python.length} Python).${skipped}`
  );
}
