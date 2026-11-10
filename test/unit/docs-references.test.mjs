// Self-check of the agent/contributor guidance: every repository path, glob,
// `npm run` script, link and `@import` named in the guidance files must exist,
// and every path-specific instruction file must have an `applyTo` that
// matches at least one file. Keeps AGENTS.md and its pointers from drifting.
import assert from 'node:assert/strict';
import test from 'node:test';
import { existsSync, readFileSync, readdirSync } from 'node:fs';
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
const topLevel = new Set(readdirSync(repo));
const npmScripts = JSON.parse(readFileSync(join(repo, 'package.json'), 'utf8')).scripts;

const instructionFiles = tree.filter((f) => /^\.github\/instructions\/.+\.instructions\.md$/.test(f));
const guidance = [
  'AGENTS.md', 'CLAUDE.md', 'CONTRIBUTING.md', 'README.md', 'docs/README.md',
  '.github/copilot-instructions.md', ...instructionFiles
];

// Glob as used by Copilot `applyTo` and in the docs: `**` spans directories,
// `*` and `?` stay within one segment, `{a,b}` alternates.
function globToRegExp(glob) {
  let re = '';
  let depth = 0;
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    if (c === '*' && glob[i + 1] === '*') {
      i++;
      if (glob[i + 1] === '/') { i++; re += '(?:.*/)?'; } else re += '.*';
    } else if (c === '*') re += '[^/]*';
    else if (c === '?') re += '[^/]';
    else if (c === '{') { depth++; re += '(?:'; }
    else if (c === '}' && depth) { depth--; re += ')'; }
    else if (c === ',' && depth) re += '|';
    else re += c.replace(/[.+^$()|[\]\\]/g, '\\$&');
  }
  return new RegExp(`^${re}$`);
}

const matches = (pattern) => {
  const re = globToRegExp(pattern.replace(/\/$/, '/**'));
  return tree.some((f) => re.test(f));
};

const exists = (path) => {
  if (/[*?{]/.test(path)) return matches(path);
  return existsSync(join(repo, path));
};

// Code spans and fenced blocks, split into words; a word is a repository
// reference when it is relative and its first segment exists at the top level
// (so router paths like /etc/config/x and `linux/amd64` are not checked).
function codeWords(text) {
  const spans = [...text.matchAll(/```[^\n]*\n([\s\S]*?)```|`([^`\n]+)`/g)].map((m) => m[1] ?? m[2]);
  return spans.flatMap((s) => s.split(/[\s"'=(),;]+/)).filter(Boolean);
}

// Placeholders in examples: a last segment named `x.*` or in capitals
// (`FILE`, `PKG.apk`, `WORKDIR`).
const placeholder = (w) => /^(x|[A-Z][A-Z_]*)(\.[\w.]+)?$/.test(w.split('/').pop());

function repoPathRefs(text) {
  return codeWords(text)
    .map((w) => w.replace(/[.:]+$/, ''))
    .filter((w) => w.includes('/') && !w.startsWith('/') && !/[<>$…]|\.\.\.|:\/\//.test(w))
    .filter((w) => topLevel.has(w.split('/')[0]) && !w.startsWith('.local-validation') && !placeholder(w));
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

for (const file of guidance) {
  test(`${file}: referenced paths, links and npm scripts exist`, () => {
    assert.ok(existsSync(join(repo, file)), `${file} is missing`);
    const text = readFileSync(join(repo, file), 'utf8');
    const missing = [];
    for (const p of repoPathRefs(text)) if (!exists(p)) missing.push(`path ${p}`);
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
    const text = readFileSync(join(repo, file), 'utf8');
    const fm = text.match(/^---\n([\s\S]*?)\n---\n/);
    assert.ok(fm, `${file}: no frontmatter`);
    const applyTo = fm[1].match(/^applyTo:\s*"([^"]+)"\s*$/m);
    assert.ok(applyTo, `${file}: no quoted applyTo`);
    for (const glob of applyTo[1].split(',').map((g) => g.trim())) {
      assert.ok(matches(glob), `${file}: applyTo ${glob} matches no file`);
    }
  }
});

test('tool pointer files defer to AGENTS.md', () => {
  assert.ok(claudeImports(readFileSync(join(repo, 'CLAUDE.md'), 'utf8')).includes('AGENTS.md'),
    'CLAUDE.md must import @AGENTS.md');
  assert.ok(linkRefs('.github/copilot-instructions.md',
    readFileSync(join(repo, '.github/copilot-instructions.md'), 'utf8')).includes('AGENTS.md'),
    '.github/copilot-instructions.md must link AGENTS.md');
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
