import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';

export const projectRoot = resolve(import.meta.dirname, '../..');
export const manifestPath = resolve(projectRoot, 'test/contracts/runtime-test-manifest.json');

export async function readManifest() {
  return JSON.parse(await readFile(manifestPath, 'utf8'));
}

export function validateManifest(manifest) {
  const errors = [];
  if (!Array.isArray(manifest.fixtureLists) || manifest.fixtureLists.length === 0) {
    errors.push('fixtureLists must contain at least one local list.');
  }
  for (const list of manifest.fixtureLists ?? []) {
    if (typeof list !== 'string' || !/^test\/fixtures\/lists\/[\w.-]+\.txt$/.test(list)) {
      errors.push(`fixture list is not a deterministic local list: ${list}`);
    }
  }
  for (const [name, path] of Object.entries({
    browser: 'test/browser/',
    qemu: 'scripts/integration/runtime-dns-lifecycle.sh',
    performance: 'root/test/performance/results.json'
  })) {
    if (manifest.requiredAdapters?.[name] !== path) {
      errors.push(`requiredAdapters.${name} must be ${path}`);
    }
  }
  for (const field of ['dnsQueryP95Ms', 'peakRssMiB', 'refreshSeconds']) {
    if (!(Number(manifest.performanceBudgets?.[field]) > 0)) {
      errors.push(`performanceBudgets.${field} must be a positive number.`);
    }
  }
  return errors;
}
