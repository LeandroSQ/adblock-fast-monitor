import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const rpc = await readFile('root/usr/libexec/rpcd/adblock-fast-monitor-actions', 'utf8');
const api = await readFile('RULE_ACTION_API.md', 'utf8');

test('RPC list schema exposes only action and job on the mutable object', () => {
  assert.match(rpc, /"action":\{"action":"String","domain":"String","confirm_rebuild":"Boolean"\},"job":\{\}/);
  assert.doesNotMatch(rpc, /"status"|purge|activity/);
});

test('job schema reports persistence and explicitly bounded active-DNS confidence', () => {
  for (const field of ['state', 'result', 'current_rule', 'persisted', 'rebuild', 'active_dns', 'message']) {
    assert.match(rpc, new RegExp(`json_add_(?:string|boolean) ${field}`));
  }
  assert.match(api, /CNAME[\s\S]*IPv6/);
  assert.match(api, /unauthorised ubus caller must be denied/i);
  assert.match(api, /adapter starts a\s+job/);
  assert.match(api, /after reboot[\s\S]*never claims/i);
});
