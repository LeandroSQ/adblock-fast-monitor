import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { resolve } from 'node:path';
import { projectRoot, readManifest } from '../../scripts/lib/manifest.mjs';

test('blocklist fixtures are deterministic, parseable host mappings', async () => {
  const { fixtureLists } = await readManifest();
  const primary = await readFile(resolve(projectRoot, fixtureLists[0]), 'utf8');
  const mappings = primary.split('\n').filter(line => line && !line.startsWith('#'));
  assert.ok(mappings.length > 0);
  for (const mapping of mappings) {
    assert.match(mapping, /^(?:0\.0\.0\.0|127\.0\.0\.1)\s+[a-z0-9.-]+\.test$/);
  }
});

test('allow fixture uses adblock exception syntax', async () => {
  const { fixtureLists } = await readManifest();
  const allow = await readFile(resolve(projectRoot, fixtureLists[1]), 'utf8');
  assert.match(allow, /^@@\|\|allowed\.example\.test\^$/m);
});
