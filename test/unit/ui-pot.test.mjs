// SPDX-License-Identifier: Apache-2.0
// Repository check (not a behavioural test, review S5): the translation
// template po/templates/adblock-fast-monitor.pot holds exactly the strings
// the web UI passes to `_()`. Regenerate it with LuCI's i18n-scan.pl (see
// .github/instructions/luci-js.instructions.md) when this fails.
import assert from 'node:assert/strict';
import test from 'node:test';
import { readdirSync, readFileSync } from 'node:fs';
import { join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const repo = fileURLToPath(new URL('../../', import.meta.url));

function files(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((e) =>
    e.isDirectory() ? files(join(dir, e.name)) : e.name.endsWith('.js') ? [join(dir, e.name)] : []);
}

const unescape = (s) => s.replace(/\\(.)/g, (m, c) => ({ n: ' ', t: ' ' }[c] ?? c));
const key = (id, ctx) => (ctx == null ? id : `${ctx}\u0004${id}`);

// `_('text')` or `_('text', 'context')`, single or double quoted.
const CALL = /(?<![\w$.])_\(\s*('(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*")\s*(?:,\s*('(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*")\s*)?\)/g;

function sourceStrings() {
  const out = new Map();
  for (const f of files(join(repo, 'htdocs'))) {
    for (const m of readFileSync(f, 'utf8').matchAll(CALL)) {
      const id = unescape(m[1].slice(1, -1)).replace(/\s+/g, ' ').trim();
      out.set(key(id, m[2] ? unescape(m[2].slice(1, -1)) : null), relative(repo, f));
    }
  }
  return out;
}

function potStrings() {
  const text = readFileSync(join(repo, 'po/templates/adblock-fast-monitor.pot'), 'utf8');
  const out = new Map();
  for (const block of text.split(/\n\n+/)) {
    const refs = [...block.matchAll(/^#: (\S+):\d+/gm)].map((m) => m[1]);
    const field = (name) => {
      const m = new RegExp(`^${name} ((?:"(?:[^"\\\\]|\\\\.)*"\\n?)+)`, 'm').exec(block);
      return m ? [...m[1].matchAll(/"((?:[^"\\]|\\.)*)"/g)].map((x) => x[1].replace(/\\(.)/g, '$1')).join('') : null;
    };
    const id = field('msgid');
    if (id) out.set(key(id, field('msgctxt')), refs);
  }
  return out;
}

test('the .pot holds every _() string of the web UI and no stale ones', () => {
  const src = sourceStrings();
  const pot = potStrings();
  assert.ok(src.size > 100, `found only ${src.size} strings`);
  const missing = [...src.keys()].filter((k) => !pot.has(k));
  assert.deepEqual(missing, [], 'strings missing from the .pot');
  const stale = [...pot].filter(([k, refs]) => refs.every((r) => r.startsWith('htdocs/')) && !src.has(k)).map(([k]) => k);
  assert.deepEqual(stale, [], 'strings in the .pot that the UI no longer uses');
});
