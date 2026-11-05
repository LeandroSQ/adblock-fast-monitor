import { existsSync } from 'node:fs';
import { resolve } from 'node:path';
import { projectRoot, readManifest } from './lib/manifest.mjs';

const target = process.argv[2];
const manifest = await readManifest();
const adapter = manifest.requiredAdapters?.[target];
if (!adapter) {
  console.error(`Unknown runtime check "${target}". Expected one of: ${Object.keys(manifest.requiredAdapters).join(', ')}`);
  process.exit(2);
}
if (!existsSync(resolve(projectRoot, adapter))) {
  console.error(
    `Cannot run ${target} verification: required runtime adapter is absent: ${adapter}\n` +
    'This is an unmet prerequisite, not a passing/skipped production test.'
  );
  process.exit(1);
}
