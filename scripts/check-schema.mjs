import { access } from 'node:fs/promises';
import { resolve } from 'node:path';
import { projectRoot, readManifest, validateManifest } from './lib/manifest.mjs';

const manifest = await readManifest();
const errors = validateManifest(manifest);

for (const fixture of manifest.fixtureLists ?? []) {
  try {
    await access(resolve(projectRoot, fixture));
  } catch {
    errors.push(`fixture list does not exist: ${fixture}`);
  }
}

if (errors.length) {
  console.error(`Schema/manifest check failed:\n- ${errors.join('\n- ')}`);
  process.exitCode = 1;
} else {
  console.log('Schema/manifest check passed.');
}
