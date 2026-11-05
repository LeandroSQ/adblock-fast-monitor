import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

test('browser gate requires a real URL and QEMU forwards it to Playwright', async () => {
  const [runner, lifecycle, qemu, spec, ci] = await Promise.all([
    readFile('scripts/run-browser-required.mjs', 'utf8'),
    readFile('scripts/integration/package-lifecycle.sh', 'utf8'),
    readFile('scripts/integration/run-openwrt-qemu.sh', 'utf8'),
    readFile('test/browser/monitor.spec.mjs', 'utf8'),
    readFile('.github/workflows/ci.yml', 'utf8')
  ]);

  assert.match(runner, /MONITOR_BASE_URL/);
  assert.match(runner, /never starts or substitutes a mock server/);
  assert.match(
    lifecycle,
    /MONITOR_BASE_URL="\$OPENWRT_LUCI_BASE_URL"\s*\\\s*MONITOR_LUCI_USERNAME="\$MONITOR_READONLY_LUCI_USERNAME"\s*\\\s*MONITOR_LUCI_PASSWORD="\$MONITOR_READONLY_LUCI_PASSWORD"\s*\\\s*npm run test:browser:required/
  );
  assert.match(qemu, /hostfwd=tcp::8080-:80/);
  assert.match(qemu, /OPENWRT_LUCI_BASE_URL=http:\/\/127\.0\.0\.1:8080/);
  assert.match(spec, /getByRole\('status'\)/);
  assert.match(spec, /toHaveCount\(0\)/);
  assert.match(ci, /qemu-runtime:/);
  assert.match(ci, /npm run test:qemu/);
});
