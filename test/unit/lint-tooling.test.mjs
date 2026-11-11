// SPDX-License-Identifier: Apache-2.0
// The lint setup (scripts/lint/, eslint.config.mjs) against the real LuCI
// views: ESLint must catch planted LuCI-specific mistakes (HTML sinks, string
// children of E(), missing or unused 'require' bindings, non-literal _()),
// the file classification must claim the rpcd plugin and Python helpers, and
// `npm run lint` must enforce its baseline in both directions.
import assert from 'node:assert/strict';
import test from 'node:test';
import { existsSync, readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { ESLint } from 'eslint';
import { projectRoot } from '../../scripts/lib/root.mjs';
import { classify, isShipped } from '../../scripts/lint/files.mjs';

const VIEW = ['htdocs', 'root/www'].map((d) => `${d}/luci-static/resources/view/adblock-fast-monitor/overview.js`)
  .find((f) => existsSync(join(projectRoot, f)));
const original = readFileSync(join(projectRoot, VIEW), 'utf8');
const eslint = new ESLint({ cwd: projectRoot });

async function lint(text) {
  const [result] = await eslint.lintText(text, { filePath: join(projectRoot, VIEW) });
  return result.messages;
}
const key = (m) => `${m.ruleId}: ${m.message}`;

// Messages the planted text has beyond the unmodified file's.
async function added(transform) {
  const before = (await lint(original)).map(key);
  const after = await lint(transform(original));
  for (const k of before) {
    const i = after.findIndex((m) => key(m) === k);
    if (i >= 0) after.splice(i, 1);
  }
  return after;
}
// Inserts a function expression after the directives, where view code lives.
const plant = (fn) => (text) => text.replace(/^('require [^']*';\n)(?!')/m, `$1window.abfmPlanted = ${fn};\n`);

test('the unmodified view parses as a LuCI function body', async () => {
  const messages = await lint(original);
  assert.equal(messages.filter((m) => m.fatal).length, 0, messages.map(key).join('\n'));
  // `model` is also a browser global; the 'require … as model' binding must still count as used.
  assert.ok(!messages.some((m) => /binding 'model'/.test(m.message)), messages.map(key).join('\n'));
});

test('a dynamic innerHTML assignment is an error', async () => {
  const got = await added(plant('function (node, v) { node.innerHTML = v; }'));
  assert.deepEqual(got.map((m) => m.ruleId), ['no-restricted-properties']);
});

test('a string child of E() is an error (dom.append would set innerHTML)', async () => {
  const got = await added(plant("function (v) { return E('span', {}, 'x' + v); }"));
  assert.deepEqual(got.map((m) => m.ruleId), ['no-restricted-syntax']);
});

test('dom.parse and non-literal _() are errors', async () => {
  const got = await added(plant('function (v) { dom.parse(v); return _(v); }'));
  assert.deepEqual(got.map((m) => m.ruleId).sort(), ['no-restricted-properties', 'no-restricted-syntax']);
});

test('a used module without its require directive is undefined', async () => {
  assert.match(original, /^'require ui';$/m);
  const got = await added((text) => text.replace(/^'require ui';\n/m, ''));
  assert.ok(got.length > 0);
  for (const m of got) assert.equal(key(m), "luci/require-bindings: 'ui' is not defined (no declaration, global or 'require' directive).");
});

test('an unknown identifier is undefined, typeof probes are not', async () => {
  const got = await added(plant('function () { return typeof(notDefinedA) + notDefinedB(); }'));
  assert.deepEqual(got.map(key), ["luci/require-bindings: 'notDefinedB' is not defined (no declaration, global or 'require' directive)."]);
});

test('an unused require is an error; a dotted require binds a_b', async () => {
  const got = await added((text) => text.replace("'require view';", "'require view';\n'require tools.widgets';"));
  assert.deepEqual(got.map(key), ["luci/require-bindings: 'require' binding 'tools_widgets' is never used; drop the directive."]);
  const used = await added((text) => plant('function () { tools_widgets.x(); }')(
    text.replace("'require view';", "'require view';\n'require tools.widgets';")));
  assert.deepEqual(used, []);
});

test('a syntax error beyond ES2021 or outside a function body is reported', async () => {
  const got = await added(plant('class { #x = 1; static { } }'));
  assert.ok(got.some((m) => m.fatal), got.map(key).join('\n'));
});

test('files.mjs claims the rpcd plugin as ucode, Python helpers, and flags unclaimed shipped files', async () => {
  assert.equal(await classify('root/usr/share/rpcd/ucode/luci.adblock-fast-monitor'), 'ucode');
  assert.equal(await classify('scripts/guest/serial-console.py'), 'python');
  assert.equal(await classify('root/etc/init.d/adblock-fast-monitor'), 'ash');
  assert.equal(await classify('scripts/lint/fetch-tools.sh'), 'bash');
  assert.equal(await classify(VIEW), 'luci');
  assert.equal(await classify('root/etc/config/adblock-fast-monitor'), 'data');
  assert.ok(isShipped('htdocs/luci-static/resources/x.css'));
  assert.ok(!isShipped('docs/CONTRACT.md'));
});

test('npm run lint fails on findings above the baseline and on stale entries', () => {
  const baseline = JSON.parse(readFileSync(join(projectRoot, 'scripts/lint/baseline.json'), 'utf8'));
  const [dropped] = Object.keys(baseline);
  if (dropped) delete baseline[dropped];
  baseline['README.md'] = { ...baseline['README.md'], 'text/bom': 1 };
  const r = spawnSync(process.execPath, ['scripts/lint/run.mjs'], {
    cwd: projectRoot, encoding: 'utf8', env: { ...process.env, ABFM_LINT_BASELINE_JSON: JSON.stringify(baseline) }
  });
  assert.equal(r.status, 1, r.stdout + r.stderr);
  assert.match(r.stderr, /README\.md: text\/bom: baseline allows 1 but only 0 remain/);
  if (dropped) assert.match(r.stderr, new RegExp(`^${dropped.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}: \\S+: \\d+ finding\\(s\\), baseline allows 0:`, 'm'));
});
