// Executes the real LuCI resource root/www/luci-static/resources/adblock-fast-monitor/model.js
// the way luci.js loads it: the file is the body of a factory function
// (window, document, L, ...requires) whose return value is a class that is
// instantiated once. Only `baseclass.extend` is provided by the harness.
import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const source = readFileSync(fileURLToPath(new URL(
  '../../root/www/luci-static/resources/adblock-fast-monitor/model.js', import.meta.url)), 'utf8');
const baseclass = { extend(proto) { return function Model() { Object.assign(this, proto); }; } };
// eslint-disable-next-line no-new-func
const Factory = new Function('window', 'document', 'L', 'baseclass', source);
const Cls = Factory({}, {}, {}, baseclass);
const m = new Cls();

const ok = (data) => m.settle(data);
const err = (code) => m.failure(new Error(`RPC call to x/y failed with error ${code}: msg`));
const info = (over = {}) => ({
  api: 1, ok: true,
  monitor: { enabled: true, manage_logging: true, poll_interval: 5, service: { running: true, pid: 1 }, object: true },
  adblock_fast: { installed: true, enabled: true, status: 'statusSuccess', dns: 'dnsmasq.servers' },
  dnsmasq: { running: true, instances: [{ section: 'cfg01411c', confdir: '/tmp/dnsmasq.cfg01411c.d', dropin: true, uci_logqueries: false, logfacility_file: false }] },
  warnings: [],
  ...over
});
const status = (over = {}) => ({ api: 1, ok: true, state: 'running', reasons: [], ...over });

test('rpcError extracts JSON-RPC and ubus codes from LuCI RPCError messages', () => {
  assert.equal(m.rpcError(new Error('RPC call to a/b failed with error -32000: Object not found')).rpc, -32000);
  assert.equal(m.rpcError(new Error('RPC call to a/b failed with error -32002: Access denied')).rpc, -32002);
  const u = m.rpcError(new Error('RPC call to a/b failed with ubus code 7: Request timed out'));
  assert.equal(u.rpc, null);
  assert.equal(u.ubus, 7);
  assert.equal(m.rpcError('boom').message, 'boom');
});

test('§8.1 deriveState: first matching row wins', () => {
  const now = 1000;
  assert.equal(m.deriveState(true, err(-32002), err(-32000), now, null).state, 'access-denied');
  assert.equal(m.deriveState(false, ok(info({ adblock_fast: { installed: false } })), ok(status()), now, null).state,
    'adblock-fast-missing');
  assert.equal(m.deriveState(false, ok(info()), err(-32000), now, now).state, 'disabled');
  // object missing while procd says running: starting for < 15 s, then not-running
  assert.equal(m.deriveState(true, ok(info()), err(-32000), now, now - 14).state, 'starting');
  assert.equal(m.deriveState(true, ok(info()), err(-32000), now, now - 15).state, 'not-running');
  const stopped = info({ monitor: { enabled: true, service: { running: false } } });
  assert.equal(m.deriveState(true, ok(stopped), err(-32000), now, now).state, 'not-running');
  // info itself unavailable: cannot claim starting
  assert.equal(m.deriveState(true, err(-32000), err(-32000), now, now).state, 'not-running');
});

test('§8.1 logging-unavailable reasons in table order', () => {
  const s = ok(status({ state: 'degraded', reasons: ['input-overflow'] }));
  const inst = (o) => ({ section: 's', confdir: '/tmp/x', dropin: false, uci_logqueries: false, logfacility_file: false, ...o });
  const withDns = (dnsmasq) => ok(info({ dnsmasq }));
  let r = m.deriveState(true, withDns({ running: false, instances: [inst({ logfacility_file: true })] }), s, 0, null);
  assert.deepEqual([r.state, r.reasons], ['logging-unavailable', ['dnsmasq-not-running']]);
  r = m.deriveState(true, withDns({ running: true, instances: [inst({ dropin: true }), inst({ logfacility_file: true })] }), s, 0, null);
  assert.deepEqual(r.reasons, ['dnsmasq-logs-to-file']);
  r = m.deriveState(true, withDns({ running: true, instances: [inst()] }), s, 0, null);
  assert.deepEqual(r.reasons, ['logging-not-active']);
  r = m.deriveState(true, withDns({ running: true, instances: [inst({ confdir: null })] }), s, 0, null);
  assert.deepEqual(r.reasons, ['confdir-invalid']);
  r = m.deriveState(true, withDns({ running: true, instances: [inst({ uci_logqueries: true })] }), s, 0, null);
  assert.deepEqual([r.state, r.reasons], ['degraded', ['input-overflow']]);
  assert.equal(m.deriveState(true, ok(info()), ok(status()), 0, null).state, 'healthy');
  // other failures without data
  const e = m.deriveState(true, ok(info()), m.failure(new Error('XHR timeout')), 0, null);
  assert.deepEqual([e.state, e.message], ['error', 'XHR timeout']);
  assert.equal(m.deriveState(true, null, null, 0, null).state, 'loading');
});

test('missingSince remembers the first -32000 and resets when the object returns', () => {
  assert.equal(m.missingSince(null, err(-32000), 10), 10);
  assert.equal(m.missingSince(10, err(-32000), 20), 10);
  assert.equal(m.missingSince(10, ok(status()), 30), null);
  assert.equal(m.missingSince(null, err(-32002), 30), null);
});

test('stale overlay after 3 × poll_interval, with clamped interval', () => {
  assert.equal(m.isStale(100, 115, 5), false);
  assert.equal(m.isStale(100, 116, 5), true);
  assert.equal(m.isStale(100, 106, 0), false);   // clamps to 2 → 6 s
  assert.equal(m.isStale(100, 107, 0), true);
  assert.equal(m.isStale(null, 1e9, 5), false);
});

test('§3 option clamping for poll_interval', () => {
  assert.equal(m.pollInterval('1'), 2);
  assert.equal(m.pollInterval('61'), 60);
  assert.equal(m.pollInterval('abc'), 5);
  assert.equal(m.pollInterval(undefined), 5);
  assert.equal(m.pollInterval('10'), 10);
});

test('§6.4 normalization in the UI matches the grammar', () => {
  assert.equal(m.normalizeDomain('  Ads.Example.COM. '), 'ads.example.com');
  assert.equal(m.normalizeDomain('_dmarc.example.com'), '_dmarc.example.com');
  assert.equal(m.normalizeDomain('xn--bcher-kva.example'), 'xn--bcher-kva.example');
  for (const bad of ['localhost', 'a..b', '-a.com', 'a-.com', '1.2.3.4', '*.a.com', 'a/b.com', 'a b.com',
    'bücher.de', 'a.com..', `${'a'.repeat(64)}.com`, `${'a.'.repeat(127)}com`, '', null, 7]) {
    assert.equal(m.normalizeDomain(bad), null, String(bad));
  }
  assert.equal(m.searchQuery(' Exa '), 'exa');
  assert.equal(m.searchQuery(''), '');
  assert.equal(m.searchQuery('a b'), null);
  assert.equal(m.searchQuery('x'.repeat(65)), null);
});

test('§6.2 row actions keep contract order and ignore unknown entries', () => {
  assert.deepEqual(m.rowActions({ actions: ['unallow', 'block', 'evil', 'allow'] }), ['allow', 'block', 'unallow']);
  assert.deepEqual(m.rowActions(null), []);
  assert.deepEqual(m.rowActions({ actions: 'block' }), []);
});

test('§8.2 staging: replace, inverse cancels, normalization, 64-item cap', () => {
  let s = m.emptyPending();
  let r = m.stage(s, 'block', 'Ads.Example.com.', 1);
  assert.equal(r.change, 'added');
  s = r.state;
  assert.deepEqual(s.items, [{ op: 'block', domain: 'ads.example.com', ts: 1 }]);
  r = m.stage(s, 'allow', 'ads.example.com', 2);
  assert.equal(r.change, 'replaced');
  assert.deepEqual(r.state.items, [{ op: 'allow', domain: 'ads.example.com', ts: 2 }]);
  r = m.stage(r.state, 'unallow', 'ads.example.com', 3);
  assert.equal(r.change, 'cancelled');
  assert.deepEqual(r.state.items, []);
  r = m.stage(m.stage(s, 'unblock', 'ads.example.com', 4).state, 'block', 'ads.example.com', 5);
  assert.equal(r.change, 'added');   // block → unblock cancelled → block again
  assert.equal(m.stage(s, 'block', 'ads.example.com', 9).change, 'unchanged');
  assert.equal(m.stage(s, 'nuke', 'x.com', 1).error, 'invalid-op');
  assert.equal(m.stage(s, 'block', 'not a domain', 1).error, 'invalid-domain');
  s = m.emptyPending();
  for (let i = 0; i < 64; i++) s = m.stage(s, 'block', `d${i}.example.com`, i).state;
  assert.equal(s.items.length, 64);
  assert.equal(m.stage(s, 'block', 'd64.example.com', 1).error, 'too-many');
  assert.equal(m.stage(s, 'allow', 'd3.example.com', 1).change, 'replaced');   // replace still works at cap
  assert.deepEqual(m.toOps(m.unstage(s, 'd0.example.com')).slice(0, 1), [{ op: 'block', domain: 'd1.example.com' }]);
  assert.deepEqual(m.discard(s).items, []);
  assert.equal(m.pendingOp(s, 'd5.example.com'), 'block');
});

test('§8.2 storage round-trip and hostile input', () => {
  let s = m.stage(m.emptyPending(), 'allow', 'a.example.com', 7).state;
  s = m.beginInflight(s, 'j1762747400-3f2a');
  s = m.stage(s, 'block', 'b.example.com', 8).state;
  const parsed = m.parsePending(m.serializePending(s));
  assert.deepEqual(parsed, s);
  assert.deepEqual(m.parsePending('{not json'), m.emptyPending());
  assert.deepEqual(m.parsePending('{"v":2,"items":[]}'), m.emptyPending());
  const hostile = m.parsePending(JSON.stringify({ v: 1,
    items: [{ op: 'block', domain: '<img src=x>' }, { op: 'eval', domain: 'x.com' }, { op: 'block', domain: 'OK.com' },
      { op: 'allow', domain: 'ok.com' }, ...Array.from({ length: 100 }, (_, i) => ({ op: 'block', domain: `n${i}.com` }))],
    inflight: { job_id: '../../etc', items: [] } }));
  assert.equal(hostile.items[0].domain, 'ok.com');
  assert.equal(hostile.items[0].op, 'block');
  assert.equal(hostile.items.length, 64);
  assert.equal(hostile.inflight, null);
});

test('§8.2 job settlement: ok/skipped leave, mismatch/unverified/failed return with reason', () => {
  let s = m.emptyPending();
  for (const [op, d] of [['allow', 'a.example.com'], ['block', 'b.example.com'], ['unblock', 'c.example.com'],
    ['unallow', 'd.example.com'], ['block', 'e.example.com']]) s = m.stage(s, op, d, 1).state;
  s = m.beginInflight(s, 'j1762747400-3f2a');
  assert.deepEqual(s.items, []);
  // user stages a newer op for e.example.com while the job runs
  s = m.stage(s, 'allow', 'e.example.com', 2).state;
  const job = { id: 'j1762747400-3f2a', state: 'partial', error: null, items: [
    { domain: 'a.example.com', result: 'ok' },
    { domain: 'b.example.com', result: 'mismatch', reason: 'not-blocked' },
    { domain: 'c.example.com', result: 'unverified', reason: 'dns-error' },
    { domain: 'd.example.com', result: 'skipped' },
    { domain: 'e.example.com', result: 'mismatch', reason: 'not-blocked' }] };
  assert.equal(m.settleJob(s, { ...job, id: 'j1762747401-0000' }).state, s);   // other job: no-op
  assert.equal(m.settleJob(s, { ...job, state: 'verifying' }).state, s);       // not terminal
  const r = m.settleJob(s, job);
  assert.deepEqual(r.done, ['a.example.com', 'd.example.com']);
  assert.deepEqual(r.returned, ['b.example.com', 'c.example.com', 'e.example.com']);
  assert.equal(r.state.inflight, null);
  assert.deepEqual(r.state.items.map((i) => [i.op, i.domain, i.reason]), [
    ['allow', 'e.example.com', undefined],
    ['block', 'b.example.com', 'not-blocked'],
    ['unblock', 'c.example.com', 'dns-error']]);
  const failed = m.settleJob(m.beginInflight(m.stage(m.emptyPending(), 'block', 'x.example.com', 1).state, 'j1762747400-3f2a'),
    { id: 'j1762747400-3f2a', state: 'failed', error: { code: 'rebuild-failed' }, items: [{ domain: 'x.example.com', result: 'pending' }] });
  assert.deepEqual(failed.state.items, [{ op: 'block', domain: 'x.example.com', ts: 1, reason: 'rebuild-failed' }]);
  const back = m.returnInflight(m.beginInflight(m.stage(m.emptyPending(), 'block', 'y.example.com', 1).state, 'j1762747400-3f2a'), 'rebuild-required');
  assert.deepEqual(back.items[0].reason, 'rebuild-required');
  assert.equal(m.isTerminal({ state: 'applied' }) && m.isTerminal({ state: 'partial' }) && !m.isTerminal({ state: 'queued' }), true);
  assert.deepEqual(m.settleNoop(s).items, []);
  const marked = m.markError(m.stage(m.emptyPending(), 'block', 'z.example.com', 1).state, { code: 'protected-domain', domain: 'Z.example.com' });
  assert.equal(marked.items[0].reason, 'protected-domain');
});

test('applyPlan: confirmation needed for rebuild or may_escalate, never for noop', () => {
  assert.deepEqual(m.applyPlan({ ok: true, mode: 'rebuild', plan: [{ change: ['block:add'] }] }).needsConfirm, true);
  assert.equal(m.applyPlan({ ok: true, mode: 'fast-allow', may_escalate: true, plan: [{ change: ['allow:add'] }] }).needsConfirm, true);
  assert.equal(m.applyPlan({ ok: true, mode: 'persist-only', plan: [{ change: ['allow:add'] }] }).needsConfirm, false);
  const noop = m.applyPlan({ ok: true, mode: 'rebuild', plan: [{ change: [] }] });
  assert.deepEqual([noop.noop, noop.needsConfirm], [true, false]);
  assert.equal(m.applyPlan({ ok: true, noop: true, job_id: null, plan: [] }).noop, true);
});

test('formatting: counts, percentages, durations, local times, drops, paging', () => {
  assert.equal(m.formatCount(1234567), '1,234,567');
  assert.equal(m.formatPct(15.4), '15.4 %');
  assert.equal(m.formatPct(null), '—');
  assert.deepEqual([0, 59, 60, 3599, 3600, 3660, 86400, 90000].map(m.formatDuration),
    ['0 s', '59 s', '1 min', '59 min', '1 h', '1 h 1 min', '1 d', '1 d 1 h']);
  const t = 1762747359;
  const d = new Date(t * 1000);
  assert.equal(m.formatTime(t), `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')} ${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}:${String(d.getSeconds()).padStart(2, '0')}`);
  assert.equal(m.formatTime(null), '—');
  assert.equal(m.sumDrops({ dropped: { input_overflow: 1, pending_evicted: 2, dnsmasq_reported: 3 } }), 6);
  assert.deepEqual(m.pageInfo(137, 25, 25), { first: 26, last: 50, total: 137, hasPrev: true, hasNext: true, prevOffset: 0, nextOffset: 50 });
  assert.deepEqual(m.pageInfo(0, 0, 25).first, 0);
  assert.equal(m.pageInfo(50, 25, 25).hasNext, false);
});
