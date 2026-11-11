// SPDX-License-Identifier: Apache-2.0
// Pinned external linters. scripts/lint/fetch-tools.sh installs these exact
// versions into .local-validation/bin/<uname -s>-<uname -m>/; a binary on
// PATH is accepted only if it reports the same version, so a run never
// silently lints with a different rule set.
import { existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { machine, type } from 'node:os';
import { join } from 'node:path';
import { projectRoot } from '../lib/root.mjs';

export const PINS = {
  shellcheck: { version: '0.11.0', probe: (out) => /^version: (\S+)$/m.exec(out)?.[1] },
  actionlint: { version: '1.7.12', probe: (out) => out.split('\n', 1)[0].trim() }
};

const pinnedDir = join(projectRoot, '.local-validation/bin', `${type()}-${machine()}`);

// Returns { bin } or { missing: reason }.
export function findTool(name) {
  const { version, probe } = PINS[name];
  const candidates = [join(pinnedDir, name)];
  const onPath = spawnSync('sh', ['-c', `command -v ${name}`], { encoding: 'utf8' }).stdout.trim();
  if (onPath) candidates.push(onPath);
  const seen = [];
  for (const bin of candidates) {
    if (!existsSync(bin)) continue;
    const got = probe(spawnSync(bin, ['--version'], { encoding: 'utf8' }).stdout ?? '');
    if (got === version) return { bin };
    seen.push(`${bin} is ${got ?? 'unknown'}`);
  }
  return { missing: `${name} ${version} not installed${seen.length ? ` (${seen.join(', ')})` : ''}; run scripts/lint/fetch-tools.sh` };
}
