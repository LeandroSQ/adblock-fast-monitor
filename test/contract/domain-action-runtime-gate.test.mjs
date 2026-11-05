import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

test('QEMU DNS lifecycle executes real domain-action lifecycle coverage', async () => {
  const [dnsLifecycle, actions] = await Promise.all([
    readFile('scripts/integration/runtime-dns-lifecycle.sh', 'utf8'),
    readFile('scripts/integration/runtime-domain-actions.sh', 'utf8')
  ]);

  assert.match(dnsLifecycle, /runtime-domain-actions\.sh/);
  for (const action of ['allow', 'unallow', 'block', 'unblock']) {
    assert.match(actions, new RegExp(`call_action ${action} `));
  }
  assert.match(actions, /\/etc\/init\.d\/adblock-fast dl/);
  assert.match(actions, /\/etc\/init\.d\/adblock-fast check/);
  assert.match(actions, /assert_blocked_a action-cname\.example\.test/);
  assert.match(actions, /assert_blocked_aaaa/);
  assert.match(actions, /rebuild-failed-active-unverified/);
  assert.match(actions, /error' \| grep -qx busy/);
  assert.match(actions, /wait_terminal_state/);
  assert.match(actions, /sync; reboot/);
  assert.match(actions, /remote "ubus call adblock-fast-monitor-actions/);
  assert.match(actions, /dig \+time=2/);
});
