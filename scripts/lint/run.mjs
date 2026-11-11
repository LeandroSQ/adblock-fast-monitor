#!/usr/bin/env node
// SPDX-License-Identifier: Apache-2.0
// `npm run lint`: every linter over the same file list as check-static
// (scripts/lint/files.mjs), with one temporary per-file baseline.
//
//   node scripts/lint/run.mjs           # check (npm run lint)
//   node scripts/lint/run.mjs --fix     # ESLint autofix first (npm run lint:fix)
//   node scripts/lint/run.mjs --prune   # lower baseline counts to the current ones (npm run lint:baseline)
//   node scripts/lint/run.mjs --init    # rewrite the baseline from scratch (integrator only)
//
// Linters: ESLint (eslint.config.mjs; JS, LuCI views, JSON), markdownlint
// (.markdownlint.jsonc), ShellCheck (-s sh for BusyBox ash files, -s bash
// for bash; .shellcheckrc) and actionlint (.github/workflows), plus a text
// check (trailing whitespace, CR, space before tab, BOM, final newline).
// ShellCheck and actionlint are pinned (scripts/lint/tools.mjs). If one is
// missing the run reports it as SKIPPED (never as passed); with CI set it
// fails instead. Nothing here needs Docker, so the git hooks can run it.
//
// scripts/lint/baseline.json maps file -> "tool/rule" -> count of tolerated
// existing findings, keyed by the post-move path (root/www/ is recorded as
// htdocs/). More findings than the baseline fail; fewer fail as a stale
// baseline (run --prune) so it only ever shrinks. It must end up empty.
import { readFile, writeFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { ESLint } from 'eslint';
import { lint as markdownlint } from 'markdownlint/promise';
import { projectRoot } from '../lib/root.mjs';
import { classify, listFiles } from './files.mjs';
import { findTool } from './tools.mjs';

const BASELINE = join(projectRoot, 'scripts/lint/baseline.json');
const mode = process.argv[2] ?? 'check';
if (!['check', '--fix', '--prune', '--init'].includes(mode)) {
  console.error(`usage: node scripts/lint/run.mjs [--fix|--prune|--init]`);
  process.exit(2);
}

const baselineKey = (name) => name.replace(/^root\/www\//, 'htdocs/');
// Captured data must stay byte-identical (and .gitleaksignore pins its lines).
const isCaptured = (name) => /^test\/fixtures\/.*\.(json|log|txt)$/.test(name);

const findings = [];
const skipped = [];
const ran = new Set();
const add = (tool, rule, file, line, col, message) =>
  findings.push({ tool, rule: `${tool}/${rule}`, file, line: line ?? 0, col: col ?? 0, message });

const files = await listFiles();
const kinds = new Map();
for (const name of files) kinds.set(name, await classify(name));

// Text hygiene.
ran.add('text');
for (const name of files) {
  if (isCaptured(name)) continue;
  const text = await readFile(join(projectRoot, name), 'utf8');
  if (text.includes('\0')) continue;
  if (text.startsWith('\uFEFF')) add('text', 'bom', name, 1, 1, 'byte order mark');
  if (text && !text.endsWith('\n')) add('text', 'final-newline', name, 0, 0, 'no newline at end of file');
  text.split('\n').forEach((line, i) => {
    if (/\r$/.test(line)) add('text', 'crlf', name, i + 1, line.length, 'CR line ending');
    else if (/[ \t]$/.test(line)) add('text', 'trailing-whitespace', name, i + 1, line.length, 'trailing whitespace');
    if (/^ +\t/.test(line)) add('text', 'space-before-tab', name, i + 1, 1, 'space before tab in indentation');
  });
}

// ESLint.
ran.add('eslint');
const eslint = new ESLint({ cwd: projectRoot, fix: mode === '--fix', errorOnUnmatchedPattern: false });
const eslintResults = await eslint.lintFiles(['.']);
if (mode === '--fix') await ESLint.outputFixes(eslintResults);
for (const result of eslintResults) {
  const name = result.filePath.slice(projectRoot.length + 1);
  for (const m of result.messages) add('eslint', m.ruleId ?? 'parse', name, m.line, m.column, m.message);
}

// markdownlint.
ran.add('markdownlint');
const mdConfig = JSON.parse((await readFile(join(projectRoot, '.markdownlint.jsonc'), 'utf8'))
  .split('\n').filter((l) => !/^\s*\/\//.test(l)).join('\n'));
const markdown = files.filter((f) => f.endsWith('.md') && !f.startsWith('test/fixtures/'));
const mdResults = await markdownlint({ files: markdown.map((f) => join(projectRoot, f)), config: mdConfig });
for (const [path, list] of Object.entries(mdResults)) {
  for (const m of list) {
    add('markdownlint', m.ruleNames[0], path.slice(projectRoot.length + 1), m.lineNumber, m.errorRange?.[0],
      `${m.ruleDescription}${m.errorDetail ? ` [${m.errorDetail}]` : ''}`);
  }
}

function external(name, run) {
  const tool = findTool(name);
  if (tool.missing) {
    if (process.env.CI) add(name, 'missing', '(tool)', 0, 0, tool.missing);
    else skipped.push(tool.missing);
    return;
  }
  ran.add(name);
  run(tool.bin);
}

// ShellCheck, with the same ash/bash split as check-static's ash -n / bash -n.
external('shellcheck', (bin) => {
  for (const [dialect, kind] of [['sh', 'ash'], ['bash', 'bash']]) {
    const list = files.filter((f) => kinds.get(f) === kind);
    if (!list.length) continue;
    const r = spawnSync(bin, ['-f', 'json1', '-S', 'info', '-s', dialect, ...list],
      { cwd: projectRoot, encoding: 'utf8', maxBuffer: 64 << 20 });
    let out;
    try { out = JSON.parse(r.stdout); } catch { add('shellcheck', 'run', '(tool)', 0, 0, `${r.stdout}${r.stderr}`.trim()); continue; }
    for (const c of out.comments) add('shellcheck', `SC${c.code}`, c.file, c.line, c.column, `${c.level}: ${c.message}`);
  }
});

// actionlint over .github/workflows, using the pinned ShellCheck for run: steps.
external('actionlint', (bin) => {
  const sc = findTool('shellcheck');
  const r = spawnSync(bin, ['-format', '{{json .}}', `-shellcheck=${sc.bin ?? ''}`],
    { cwd: projectRoot, encoding: 'utf8', maxBuffer: 64 << 20 });
  let out;
  try { out = JSON.parse(r.stdout || '[]'); } catch { add('actionlint', 'run', '(tool)', 0, 0, `${r.stdout}${r.stderr}`.trim()); return; }
  for (const e of out) add('actionlint', e.kind, e.filepath, e.line, e.column, e.message);
});

// Baseline.
// ABFM_LINT_BASELINE_JSON replaces the file's content in check mode (tests).
const override = mode === 'check' ? process.env.ABFM_LINT_BASELINE_JSON : undefined;
const baseline = JSON.parse(override ?? await readFile(BASELINE, 'utf8').catch(() => '{}'));
const actual = {};
for (const f of findings) {
  const entry = (actual[baselineKey(f.file)] ??= {});
  entry[f.rule] = (entry[f.rule] ?? 0) + 1;
}
const toolOf = (rule) => rule.split('/', 1)[0];

if (mode === '--init' || mode === '--prune') {
  const next = {};
  const keys = new Set([...Object.keys(baseline), ...(mode === '--init' ? Object.keys(actual) : [])]);
  for (const file of [...keys].sort()) {
    const rules = new Set([...Object.keys(baseline[file] ?? {}), ...(mode === '--init' ? Object.keys(actual[file] ?? {}) : [])]);
    for (const rule of [...rules].sort()) {
      // Keep entries of a tool that did not run; never raise a count on --prune.
      const now = ran.has(toolOf(rule)) ? (actual[file]?.[rule] ?? 0) : baseline[file]?.[rule] ?? 0;
      const count = mode === '--init' ? now : Math.min(now, baseline[file]?.[rule] ?? 0);
      if (count > 0) (next[file] ??= {})[rule] = count;
    }
  }
  await writeFile(BASELINE, `${JSON.stringify(next, null, 2)}\n`);
  console.log(`lint: wrote ${BASELINE.slice(projectRoot.length + 1)} (${Object.keys(next).length} files)`);
}

const current = mode === 'check' || mode === '--fix' ? baseline : JSON.parse(await readFile(BASELINE, 'utf8'));
const problems = [];
let tolerated = 0;
for (const file of new Set([...Object.keys(actual), ...Object.keys(current)])) {
  for (const rule of new Set([...Object.keys(actual[file] ?? {}), ...Object.keys(current[file] ?? {})])) {
    if (!ran.has(toolOf(rule)) && !(actual[file]?.[rule])) continue;
    const have = actual[file]?.[rule] ?? 0;
    const allowed = current[file]?.[rule] ?? 0;
    if (have > allowed) {
      problems.push(`${file}: ${rule}: ${have} finding(s), baseline allows ${allowed}:`);
      for (const f of findings.filter((x) => baselineKey(x.file) === file && x.rule === rule))
        problems.push(`  ${f.file}:${f.line}:${f.col}: ${f.message}`);
    } else if (have < allowed) {
      problems.push(`${file}: ${rule}: baseline allows ${allowed} but only ${have} remain; run npm run lint:baseline`);
    }
    tolerated += Math.min(have, allowed);
  }
}

const summary = `${[...ran].join(', ')} over ${files.length} files` +
  (tolerated ? `; ${tolerated} baselined finding(s) in scripts/lint/baseline.json` : '') +
  skipped.map((s) => `; SKIPPED ${s}`).join('');
if (problems.length) {
  console.error(`Lint failed (${summary}):\n${problems.join('\n')}`);
  process.exitCode = 1;
} else {
  console.log(`Lint passed: ${summary}.`);
}
