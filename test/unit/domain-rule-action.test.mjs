import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const job = await readFile('root/usr/libexec/adblock-fast-monitor-job', 'utf8');
const rpc = await readFile('root/usr/libexec/rpcd/adblock-fast-monitor-actions', 'utf8');
const api = await readFile('RULE_ACTION_API.md', 'utf8');

test('worker is syntactically valid and permits only bounded supported lifecycle calls', async () => {
  assert.match(job, /timeout "\$ACTION_TIMEOUT" \/etc\/init\.d\/adblock-fast allow "\$domain"/);
  assert.match(job, /timeout "\$ACTION_TIMEOUT" \/etc\/init\.d\/adblock-fast dl/);
  assert.doesNotMatch(job, /eval|sh -c|\/etc\/init\.d\/adblock-fast (?:restart|start|stop)/);
  assert.match(job, /ACTION_TIMEOUT=120/);
  assert.match(job, /\. \/usr\/lib\/adblock-fast-monitor\/common\.sh/);
  assert.match(job, /monitor_state_init/);
  assert.match(job, /chmod 0600 "\$tmp"/);
  assert.doesNotMatch(job, /chmod 0644/);
  assert.match(job, /\[ "\$rebuild_confirmed" = confirmed \]/);
  assert.match(job, /A full rebuild was not started because explicit confirmation is required/);
});

test('worker rejects malicious and broad domains before UCI mutation', () => {
  assert.match(job, /\*\[!a-z0-9\.-\]\*/);
  assert.match(job, /public-suffix-data-unavailable/);
  assert.match(job, /Refusing a public-suffix rule/);
  assert.match(job, /config\.blocked_domain=\$domain/);
  assert.match(job, /grep -Fqx -- "\$domain"/);
});

test('worker has idempotency, conflicts, and honest DNS verification outcomes', () => {
  assert.match(job, /Allow rule already exists; no change was made/);
  assert.match(job, /Block rule already exists; no change was made/);
  assert.match(job, /The domain is both allowed and blocked/);
  assert.match(job, /persisted-active-unknown/);
  assert.match(job, /cached, CNAME, or IPv6 responses/);
  assert.match(job, /rebuild-failed-active-unverified/);
});

test('RPC isolates write capability and gates rebuilding operations', () => {
  assert.match(rpc, /case "\$1" in/);
  assert.match(rpc, /action\)/);
  assert.match(rpc, /confirm_rebuild=true/);
  assert.match(rpc, /mkdir "\$LOCK_DIR"/);
  assert.match(rpc, /action_state_init \|\| \{ reply_error state-insecure/);
  assert.match(rpc, /"\$WORKER" "\$action" "\$domain" held/);
  assert.doesNotMatch(rpc, /\/bin\/sh -c|eval|exec "\$/);
  assert.match(api, /"adblock-fast-monitor-actions": \[ "job" \]/);
  assert.match(api, /"adblock-fast-monitor-actions": \[ "action" \]/);
});
