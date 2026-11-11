// SPDX-License-Identifier: Apache-2.0
// The repository file walker and language classification shared by
// scripts/check-static.mjs (syntax) and scripts/lint/run.mjs (lint), so both
// see the same files: never `find`, which would descend into the 4 GB
// .local-validation/ cache (SDK trees with their own eslint configs).
import { readdir, readFile } from 'node:fs/promises';
import { join, relative } from 'node:path';
import { projectRoot } from '../lib/root.mjs';

export const IGNORED_DIRS = new Set(['node_modules', 'dist', '.git', '.ci-work', '.local-validation',
  'playwright-report', 'test-results']);

// LuCI class files: root/www/ until the luci.mk move, htdocs/ after it.
export const isLuci = (name) => /^(root\/www|htdocs)\/.*\.js$/.test(name);

// Files under root/ and htdocs/ that no syntax checker reads (UCI config and
// sysupgrade keep lists are plain data).
const DATA = /^root\/(etc\/config|lib\/upgrade\/keep\.d)\//;

export async function listFiles(directory = projectRoot, out = []) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    if (IGNORED_DIRS.has(entry.name) || /^openwrt-sdk-/.test(entry.name)) continue;
    const path = join(directory, entry.name);
    if (entry.isDirectory()) await listFiles(path, out);
    else if (entry.isFile()) out.push(relative(projectRoot, path));
  }
  return out.sort();
}

// Returns 'luci' | 'js' | 'json' | 'ucode' | 'bash' | 'ash' | 'python' |
// 'data' (deliberately unchecked shipped data) | null (not a source file).
export async function classify(name) {
  const base = name.split('/').pop();
  let head = '';
  if (!base.includes('.') || /\.(sh|uc|py)$/.test(base)) {
    head = (await readFile(join(projectRoot, name), 'utf8')).slice(0, 4096);
  }
  const shebang = head.startsWith('#!') ? head.split('\n', 1)[0] : '';

  if (/\.(mjs|cjs|js)$/.test(base)) return isLuci(name) ? 'luci' : 'js';
  if (base.endsWith('.json')) return 'json';
  // rpcd ucode plugins are named luci.<name>, with neither .uc nor a shebang.
  if (base.endsWith('.uc') || /\bucode\b/.test(shebang) || name.startsWith('root/usr/share/rpcd/ucode/')) return 'ucode';
  if (/\bbash\b/.test(shebang) || (base.endsWith('.sh') && /^# shellcheck shell=bash$/m.test(head))) return 'bash';
  if (base.endsWith('.sh') || /^#!\s*\/bin\/(ash|sh)\b/.test(shebang)) return 'ash';
  if (base.endsWith('.py') || /\bpython3?\b/.test(shebang)) return 'python';
  if (DATA.test(name)) return 'data';
  return null;
}

// A shipped file (installed by the APK) that no checker claims is an error:
// it would first be parsed on the router.
export const isShipped = (name) => /^(root|htdocs)\//.test(name);
