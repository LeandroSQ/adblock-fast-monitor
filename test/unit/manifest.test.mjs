import assert from 'node:assert/strict';
import test from 'node:test';
import { readManifest, validateManifest } from '../../scripts/lib/manifest.mjs';

test('runtime test manifest is internally valid', async () => {
  assert.deepEqual(validateManifest(await readManifest()), []);
});

test('manifest validation rejects external fixture URLs', () => {
  const invalid = {
    fixtureLists: ['https://lists.example.invalid/hosts'],
    requiredAdapters: {
      browser: 'test/browser/',
      qemu: 'scripts/integration/runtime-dns-lifecycle.sh',
      performance: 'root/test/performance/results.json'
    },
    performanceBudgets: { dnsQueryP95Ms: 1, peakRssMiB: 1, refreshSeconds: 1 }
  };
  assert.match(validateManifest(invalid).join('\n'), /deterministic local list/);
});
