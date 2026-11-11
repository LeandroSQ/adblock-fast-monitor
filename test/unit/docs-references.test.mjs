// SPDX-License-Identifier: Apache-2.0
// Repository checks (AGENTS.md → Testing obligations): these keep the docs and
// agent guidance consistent with the tree. They are not behavioural tests and
// are not counted as feature evidence.
//
// - every repository path, glob, link and `npm run` script named in any
//   Markdown file exists (paths into a deleted repository directory fail too);
// - path-specific instruction files have `applyTo` globs that match files, and
//   CLAUDE.md lists exactly the same files and globs;
// - the hard restrictions in .github/copilot-instructions.md are a byte copy
//   of the block in AGENTS.md;
// - every .github/CODEOWNERS pattern matches something;
// - every T-ID used in tests is defined in CONTRACT §13, and each §13 row's
//   files name its ID.
import assert from 'node:assert/strict';
import test from 'node:test';
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { dirname, join, normalize, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const repo = fileURLToPath(new URL('../../', import.meta.url));
const skipDirs = new Set(['.git', 'node_modules', '.local-validation', '.ci-work', 'dist', 'playwright-report', 'test-results']);

function walk(dir, out = []) {
  for (const e of readdirSync(join(repo, dir), { withFileTypes: true })) {
    if (skipDirs.has(e.name)) continue;
    const rel = dir ? `${dir}/${e.name}` : e.name;
    if (e.isDirectory()) walk(rel, out);
    else out.push(rel);
  }
  return out;
}
const tree = walk('');
const read = (f) => readFileSync(join(repo, f), 'utf8');
const npmScripts = JSON.parse(read('package.json')).scripts;

// A relative path whose first segment is a repository directory is checked
// even when that directory no longer exists, so a reference into a removed or
// renamed directory fails instead of being mistaken for a non-repo path.
const repoDirs = new Set([
  ...readdirSync(repo),
  '.claude', '.github', '.githooks', 'docs', 'htdocs', 'keys', 'po', 'root', 'scripts', 'test'
]);

const markdown = tree.filter((f) => f.endsWith('.md'));
const instructionFiles = tree.filter((f) => /^\.github\/instructions\/.+\.instructions\.md$/.test(f));

// Glob as used by Copilot `applyTo`, CODEOWNERS and the docs: `**` spans
// directories, `*` and `?` stay within one segment, `{a,b}` alternates.
function globToRegExp(glob) {
  let re = '';
  let depth = 0;
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    if (c === '*' && glob[i + 1] === '*') {
      i++;
      if (glob[i + 1] === '/') {
        i++;
        re += '(?:.*/)?';
      } else {
        re += '.*';
      }
    } else if (c === '*') re += '[^/]*';
    else if (c === '?') re += '[^/]';
    else if (c === '{') {
      depth++;
      re += '(?:';
    } else if (c === '}' && depth) {
      depth--;
      re += ')';
    } else if (c === ',' && depth) re += '|';
    else re += c.replace(/[.+^$()|[\]\\]/g, '\\$&');
  }
  return new RegExp(`^${re}$`);
}

const filesMatching = (pattern) => {
  const re = globToRegExp(pattern.replace(/\/$/, '/**'));
  return tree.filter((f) => re.test(f));
};
const matches = (pattern) => filesMatching(pattern).length > 0;

const exists = (path) => {
  if (/[*?{]/.test(path)) return matches(path);
  return existsSync(join(repo, path));
};

// Code spans and fenced blocks, split into words.
function codeWords(text) {
  const spans = [...text.matchAll(/```[^\n]*\n([\s\S]*?)```|`([^`\n]+)`/g)].map((m) => m[1] ?? m[2]);
  return spans
    .map((s) => s.replace(/\{[^{}\s]*\}/g, (b) => b.replaceAll(',', '\0')))
    .flatMap((s) => s.split(/[\s"'=(),;]+/))
    .map((w) => w.replaceAll('\0', ','))
    .filter(Boolean);
}

// Placeholders in examples: a last segment named `x.*` or in capitals
// (`FILE`, `PKG.apk`, `WORKDIR`).
const placeholder = (w) => /^(x|[A-Z][A-Z_]*)(\.[\w.]+)?$/.test(w.split('/').pop());

function repoPathRefs(text) {
  return codeWords(text)
    .map((w) => w.replace(/[.:]+$/, ''))
    .filter((w) => w.includes('/') && !w.startsWith('/') && !/[<>$…]|\.\.\.|:\/\//.test(w))
    .filter((w) => repoDirs.has(w.split('/')[0]) && !placeholder(w));
}

function linkRefs(file, text) {
  const prose = text.replace(/```[\s\S]*?```/g, '');
  return [...prose.matchAll(/\]\(([^)\s]+)\)/g)]
    .map((m) => m[1].split('#')[0])
    .filter((t) => t && !/^[a-z]+:/i.test(t))
    .map((t) => normalize(relative(repo, join(repo, dirname(file), t))));
}

function claudeImports(text) {
  const prose = text.replace(/```[\s\S]*?```/g, '').replace(/`[^`\n]*`/g, '');
  return [...prose.matchAll(/(?:^|\s)@([^\s]+)/g)].map((m) => m[1]);
}

function applyToOf(file) {
  const fm = read(file).match(/^---\n([\s\S]*?)\n---\n/);
  assert.ok(fm, `${file}: no frontmatter`);
  const applyTo = fm[1].match(/^applyTo:\s*"([^"]+)"\s*$/m);
  assert.ok(applyTo, `${file}: no quoted applyTo`);
  return applyTo[1].split(',').map((g) => g.trim());
}

// Paths and applyTo globs that may be named before they exist, per file.
// An entry the file no longer names fails, so the list cannot go stale;
// delete entries once the path exists.
const notYet = {
  // Web assets move from root/www/ to htdocs/ (luci.mk installs htdocs/ to /www).
  'AGENTS.md': ['htdocs/'],
  'CLAUDE.md': ['htdocs/**'],
  '.github/instructions/luci-js.instructions.md': [
    'htdocs/**', 'htdocs/luci-static/resources/adblock-fast-monitor/model.js'
  ],
  // Created by the maintainer when the signing key is generated (keys/README.md).
  'keys/README.md': ['keys/adblock-fast-monitor.pem', 'keys/adblock-fast-monitor-2027.pem']
};

for (const file of markdown) {
  test(`${file}: referenced paths, links and npm scripts exist`, () => {
    const text = read(file);
    const missing = [];
    const refs = repoPathRefs(text);
    const allowed = new Set(notYet[file] ?? []);
    const named = [...refs, ...(instructionFiles.includes(file) ? applyToOf(file) : [])];
    for (const p of allowed) if (!named.includes(p)) missing.push(`stale notYet entry ${p}`);
    for (const p of refs) if (!allowed.has(p) && !exists(p)) missing.push(`path ${p}`);
    for (const p of linkRefs(file, text)) if (!existsSync(join(repo, p))) missing.push(`link ${p}`);
    for (const [, name] of text.matchAll(/npm run ([\w:.-]+)/g)) {
      if (!Object.hasOwn(npmScripts, name)) missing.push(`npm script ${name}`);
    }
    if (file === 'CLAUDE.md') {
      for (const p of claudeImports(text)) if (!existsSync(join(repo, p))) missing.push(`@import ${p}`);
    }
    assert.deepEqual(missing, [], `${file} references things that do not exist`);
  });
}

test('path-specific instruction files have applyTo globs that match files', () => {
  assert.ok(instructionFiles.length > 0, 'no .github/instructions/*.instructions.md files');
  for (const file of instructionFiles) {
    for (const glob of applyToOf(file)) {
      assert.ok(matches(glob) || notYet[file]?.includes(glob), `${file}: applyTo ${glob} matches no file`);
    }
  }
});

test('tool pointer files defer to AGENTS.md', () => {
  assert.ok(claudeImports(read('CLAUDE.md')).includes('AGENTS.md'), 'CLAUDE.md must import @AGENTS.md');
  assert.ok(linkRefs('.github/copilot-instructions.md', read('.github/copilot-instructions.md')).includes('AGENTS.md'),
    '.github/copilot-instructions.md must link AGENTS.md');
});

test('CLAUDE.md lists every instruction file with its applyTo globs', () => {
  const listed = new Map();
  for (const line of read('CLAUDE.md').split('\n')) {
    const m = line.match(/^\s*- (.+?) → `(\.github\/instructions\/[^`]+)`\s*$/);
    if (m) listed.set(m[2], [...m[1].matchAll(/`([^`]+)`/g)].map((g) => g[1]).sort());
  }
  const expected = new Map(instructionFiles.map((f) => [f, applyToOf(f).sort()]));
  assert.deepEqual(Object.fromEntries(listed), Object.fromEntries(expected));
});

test('copilot-instructions.md repeats the AGENTS.md hard restrictions byte for byte', () => {
  const block = (file) => {
    const m = read(file).match(/<!-- hard-restrictions:begin -->\n[\s\S]*?<!-- hard-restrictions:end -->/);
    assert.ok(m, `${file}: no hard-restrictions block`);
    return m[0];
  };
  const agents = block('AGENTS.md');
  assert.ok((agents.match(/^\d+\. /gm) ?? []).length >= 10, 'AGENTS.md block lost its numbered rules');
  assert.equal(block('.github/copilot-instructions.md'), agents);
});

test('every CODEOWNERS pattern matches a file', () => {
  const lines = read('.github/CODEOWNERS').split('\n').filter((l) => l.trim() && !l.startsWith('#'));
  assert.ok(lines.length > 0);
  for (const line of lines) {
    const [pattern, ...owners] = line.trim().split(/\s+/);
    assert.ok(owners.length > 0 && owners.every((o) => o.startsWith('@')), `CODEOWNERS ${pattern}: no owner`);
    assert.ok(pattern.startsWith('/'), `CODEOWNERS ${pattern}: anchor patterns at the repository root`);
    const p = pattern.slice(1);
    const dir = p.endsWith('/') || (existsSync(join(repo, p)) && statSync(join(repo, p)).isDirectory());
    assert.ok(matches(dir ? `${p.replace(/\/$/, '')}/**` : p), `CODEOWNERS ${pattern} matches nothing`);
  }
});

// CONTRACT §13 rows: `| Tnn | item | assertion | env | where |`.
function matrix() {
  const rows = new Map();
  for (const m of read('docs/CONTRACT.md').matchAll(/^\| (T\d\d) \|(.*)\|\s*$/gm)) {
    const where = m[2].split('|').pop();
    rows.set(m[1], [...where.matchAll(/`([^`]+)`/g)].map((g) => g[1]).filter((p) => p.includes('/')));
  }
  return rows;
}

// T-IDs whose §13 files do not name them yet. Shrink only: a row leaves this
// list once one of its files names the ID (e.g. a `T07: …` test title).
const unnamedIds = new Set(['T01', 'T02', 'T03', 'T04', 'T05', 'T27', 'T28', 'T29']);

test('T-IDs in tests are defined in CONTRACT §13 and each row\'s files name its ID', () => {
  const rows = matrix();
  assert.ok(rows.size >= 30, 'CONTRACT §13 matrix not found');
  const code = tree.filter((f) => /^(test|scripts)\//.test(f) && !f.startsWith('test/fixtures/'));
  const undefinedIds = [];
  for (const f of code) {
    for (const [id] of read(f).matchAll(/\bT\d\d\b/g)) if (!rows.has(id)) undefinedIds.push(`${f}: ${id}`);
  }
  assert.deepEqual(undefinedIds, [], 'T-IDs used but not defined in CONTRACT §13');
  const unnamed = [];
  for (const [id, where] of rows) {
    const files = where.flatMap((p) => (p.endsWith('/') || /[*?{]/.test(p)) ? filesMatching(p) : [p])
      .filter((f) => existsSync(join(repo, f)) && statSync(join(repo, f)).isFile());
    const named = files.some((f) => new RegExp(`\\b${id}\\b`).test(read(f)));
    if (!named && !unnamedIds.has(id)) unnamed.push(id);
    if (named && unnamedIds.has(id)) unnamed.push(`${id} (now named: remove it from unnamedIds)`);
  }
  assert.deepEqual(unnamed, [], 'CONTRACT §13 rows whose files do not name the ID');
});

test('glob matcher semantics', () => {
  const g = (p, s) => globToRegExp(p).test(s);
  assert.ok(g('root/www/**', 'root/www/a/b.js'));
  assert.ok(g('test/ucode/**/*.test.uc', 'test/ucode/a.test.uc'));
  assert.ok(g('test/ucode/**/*.test.uc', 'test/ucode/x/y/a.test.uc'));
  assert.ok(!g('test/guest/*.sh', 'test/guest/lib/x.sh'));
  assert.ok(g('src/*.{ts,tsx}', 'src/a.tsx'));
  assert.ok(!g('src/*.{ts,tsx}', 'src/a.js'));
});

test('a path into a removed repository directory is checked, not skipped', () => {
  assert.deepEqual(repoPathRefs('`htdocs/gone.js` `linux/amd64` `lib/x.sh`'), ['htdocs/gone.js']);
});
