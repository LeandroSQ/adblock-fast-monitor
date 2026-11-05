import { cp, mkdir, rm, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { projectRoot } from './lib/manifest.mjs';

const output = resolve(projectRoot, 'dist/test-infrastructure');
await rm(resolve(projectRoot, 'dist'), { recursive: true, force: true });
await mkdir(output, { recursive: true });
for (const path of ['scripts', 'schemas', 'test/contracts', 'test/fixtures', 'docs/test-traceability.md', 'README.md', 'package.json']) {
  await cp(resolve(projectRoot, path), resolve(output, path), { recursive: true });
}
await writeFile(
  resolve(output, 'build-manifest.json'),
  `${JSON.stringify({ name: 'adblock-fast-monitor-test-infrastructure', generatedBy: 'scripts/build.mjs' }, null, 2)}\n`
);
console.log(`Built test infrastructure in ${output}.`);
