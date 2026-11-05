import assert from 'node:assert/strict';
import { access, readFile } from 'node:fs/promises';
import test from 'node:test';

test('active QEMU adapter validates the production dnsmasq ownership lifecycle', async () => {
  const [adapter, common, manifest] = await Promise.all([
    readFile('scripts/integration/runtime-dns-lifecycle.sh', 'utf8'),
    readFile('root/usr/lib/adblock-fast-monitor/common.sh', 'utf8'),
    readFile('test/contracts/runtime-test-manifest.json', 'utf8')
  ]);
  assert.match(common, /MONITOR_RUNTIME=\/var\/run\/adblock-fast-monitor/);
  assert.match(common, /MONITOR_DNS_OWNER="\$MONITOR_RUNTIME\/dnsmasq-logqueries\.owner"/);
  assert.match(adapter, /own_logqueries=1/);
  assert.match(adapter, /own_logqueries=0/);
  assert.match(adapter, /dnsmasq-logqueries\.owner/);
  assert.match(adapter, /stat -c '%u:%a'/);
  assert.match(adapter, /test .*logqueries.* = 1/);
  assert.match(adapter, /test .*logqueries.* = 0/);
  assert.match(manifest, /scripts\/integration\/runtime-dns-lifecycle\.sh/);
  await assert.rejects(access('root/test/openwrt/provision.sh'));
});
