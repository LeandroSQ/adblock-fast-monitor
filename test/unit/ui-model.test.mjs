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
const inst = (o = {}) => ({ section: 'cfg01411c', confdir: '/tmp/dnsmasq.cfg01411c.d', dropin: false,
  uci_logqueries: false, logfacility_file: false, ...o });
const info = (over = {}) => ({
  api: 2, ok: true,
  monitor: { query_logging: true },
  adblock_fast: { installed: true, enabled: true, status: 'statusSuccess', dns: 'dnsmasq.servers' },
  dnsmasq: { running: true, instances: [inst({ dropin: true })] },
  local_domains: ['lan'],
  warnings: [],
  ...over
});

test('rpcError extracts JSON-RPC and ubus codes from LuCI RPCError messages', () => {
  assert.equal(m.rpcError(new Error('RPC call to a/b failed with error -32000: Object not found')).rpc, -32000);
  assert.equal(m.rpcError(new Error('RPC call to a/b failed with error -32002: Access denied')).rpc, -32002);
  const u = m.rpcError(new Error('RPC call to a/b failed with ubus code 7: Request timed out'));
  assert.equal(u.rpc, null);
  assert.equal(u.ubus, 7);
  assert.equal(m.rpcError('boom').message, 'boom');
});

test('§8.5 pageState: first matching state wins', () => {
  const st = (i, l, rows = false) => { const r = m.pageState(i, l, rows); return [r.state, r.reason]; };
  const logOk = ok(null), logErr = m.failure(new Error('RPC call to log/read failed with ubus code 7: timeout'));
  assert.deepEqual(st(err(-32002), logOk), ['access-denied', null]);
  assert.deepEqual(st(ok(info({ adblock_fast: { installed: false } })), logOk), ['adblock-fast-missing', null]);
  assert.deepEqual(st(ok(info({ monitor: { query_logging: false }, dnsmasq: { running: true, instances: [inst()] } })), logOk),
    ['logging-off', null]);
  // logging turned on elsewhere (dnsmasq logqueries, e.g. luci-app-adblock-fast) is not "off"
  const elsewhere = ok(info({ monitor: { query_logging: false }, dnsmasq: { running: true, instances: [inst({ uci_logqueries: true })] } }));
  assert.deepEqual(st(elsewhere, logOk), ['healthy', null]);
  assert.equal(m.loggingElsewhere(elsewhere), true);
  assert.equal(m.loggingElsewhere(ok(info())), false);
  assert.deepEqual(st(ok(info({ dnsmasq: { running: false, instances: [inst({ dropin: true })] } })), logOk),
    ['logging-unavailable', 'dnsmasq-not-running']);
  assert.deepEqual(st(ok(info({ dnsmasq: { running: true, instances: [inst({ dropin: true }), inst({ logfacility_file: true })] } })), logOk),
    ['logging-unavailable', 'dnsmasq-logs-to-file']);
  assert.deepEqual(st(ok(info({ dnsmasq: { running: true, instances: [inst()] } })), logOk),
    ['logging-unavailable', 'logging-not-active']);
  assert.deepEqual(st(ok(info({ dnsmasq: { running: true, instances: [inst({ confdir: null })] } })), logOk),
    ['logging-unavailable', 'confdir-invalid']);
  // an untargeted instance with a drop-in does not count; an untargeted bad confdir does not matter
  assert.deepEqual(st(ok(info({ dnsmasq: { running: true, instances: [inst({ dropin: true, targeted: false }), inst({ targeted: true })] } })), logOk),
    ['logging-unavailable', 'logging-not-active']);
  assert.deepEqual(st(ok(info({ dnsmasq: { running: true, instances: [inst({ dropin: true, targeted: true }), inst({ confdir: null, targeted: false })] } })), logOk),
    ['healthy', null]);
  assert.deepEqual(st(ok(info()), logErr), ['error', null]);
  assert.deepEqual(st(ok(info()), logErr, true), ['healthy', null]);   // keeps earlier rows
  assert.deepEqual(st(ok(info()), null), ['loading', null]);
  assert.deepEqual(st(err(-32000), logOk), ['healthy', null]);          // info failed: judge by the log
  assert.deepEqual(st(null, null), ['loading', null]);
});

test('viewOptions: poll_interval clamped to 2..60 (default 2), router hidden unless exclude_router=false', () => {
  const vo = (monitor) => m.viewOptions(ok(info({ monitor })));
  assert.deepEqual(vo({ poll_interval: 5, exclude_router: true }), { interval: 5, hideRouter: true });
  assert.deepEqual(vo({ poll_interval: 1 }), { interval: 2, hideRouter: true });
  assert.deepEqual(vo({ poll_interval: 600, exclude_router: false }), { interval: 60, hideRouter: false });
  assert.deepEqual(vo({ poll_interval: 'x' }), { interval: 2, hideRouter: true });
  assert.deepEqual(m.viewOptions(err(-32002)), { interval: 2, hideRouter: true });
});

test('localDomains takes only non-empty strings from info.local_domains', () => {
  assert.deepEqual(m.localDomains(ok(info({ local_domains: ['lan', '', 7, null, 'home.example'] }))), ['lan', 'home.example']);
  assert.deepEqual(m.localDomains(ok(info({ local_domains: 'lan' }))), []);
  assert.deepEqual(m.localDomains(err(-32002)), []);
  assert.deepEqual(m.localDomains(null), []);
});

test('rowOp: Allow on blocked rows, Block on allowed rows, nothing otherwise', () => {
  assert.equal(m.rowOp('blocked'), 'allow');
  assert.equal(m.rowOp('allowed'), 'block');
  for (const d of ['other', 'no-answer', undefined, '__proto__', 'constructor']) assert.equal(m.rowOp(d), null, String(d));
  assert.deepEqual(m.OPS, ['allow', 'block']);
});

test('filterRows: case-insensitive substring on the domain; blank keeps all', () => {
  const rows = [{ domain: 'ads.example.test' }, { domain: 'www.example.org' }, { domain: null }, null];
  assert.equal(m.filterRows(rows, ''), rows);
  assert.equal(m.filterRows(rows, '  '), rows);
  assert.deepEqual(m.filterRows(rows, ' EXAMPLE.'), [rows[0], rows[1]]);
  assert.deepEqual(m.filterRows(rows, 'ads'), [rows[0]]);
  assert.deepEqual(m.filterRows(rows, '<img'), []);
});

test('§6.4 normalization in the UI matches the grammar', () => {
  assert.equal(m.normalizeDomain('  Ads.Example.COM. '), 'ads.example.com');
  assert.equal(m.normalizeDomain('_dmarc.example.com'), '_dmarc.example.com');
  assert.equal(m.normalizeDomain('xn--bcher-kva.example'), 'xn--bcher-kva.example');
  for (const bad of ['localhost', 'a..b', '-a.com', 'a-.com', '1.2.3.4', '*.a.com', 'a/b.com', 'a b.com',
    'bücher.de', 'a.com..', `${'a'.repeat(64)}.com`, `${'a.'.repeat(127)}com`, '', null, 7]) {
    assert.equal(m.normalizeDomain(bad), null, String(bad));
  }
});

test('§8.4 staging: allow and block only, replace, same op again cancels, normalization, 64-item cap', () => {
  let s = m.emptyPending();
  let r = m.stage(s, 'block', 'Ads.Example.com.', 1);
  assert.equal(r.change, 'added');
  s = r.state;
  assert.deepEqual(s.items, [{ op: 'block', domain: 'ads.example.com', ts: 1 }]);
  r = m.stage(s, 'allow', 'ads.example.com', 2);
  assert.equal(r.change, 'replaced');
  assert.deepEqual(r.state.items, [{ op: 'allow', domain: 'ads.example.com', ts: 2 }]);
  r = m.stage(s, 'block', 'ads.example.com', 9);
  assert.equal(r.change, 'cancelled');
  assert.deepEqual(r.state.items, []);
  for (const op of ['unblock', 'unallow', 'nuke']) assert.equal(m.stage(s, op, 'x.example.com', 1).error, 'invalid-op', op);
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
  assert.equal(m.STORAGE_KEY, 'adblock-fast-monitor.pending.v2');
  // api-1 lists (pending.v1 shape, may hold unblock/unallow) are discarded
  assert.deepEqual(m.parsePending('{"v":1,"items":[{"op":"block","domain":"a.example.com"}]}'), m.emptyPending());
  const hostile = m.parsePending(JSON.stringify({ v: 2,
    items: [{ op: 'block', domain: '<img src=x>' }, { op: 'eval', domain: 'x.com' }, { op: 'block', domain: 'OK.com' },
      { op: 'allow', domain: 'ok.com' }, { op: 'unblock', domain: 'old.example.com' }, ...Array.from({ length: 100 }, (_, i) => ({ op: 'block', domain: `n${i}.com` }))],
    inflight: { job_id: '../../etc', items: [] } }));
  assert.equal(hostile.items[0].domain, 'ok.com');
  assert.equal(hostile.items[0].op, 'block');
  assert.equal(hostile.items.length, 64);
  assert.equal(hostile.inflight, null);
});

test('§8.2 job settlement: ok/skipped leave, mismatch/unverified/failed return with reason', () => {
  let s = m.emptyPending();
  for (const [op, d] of [['allow', 'a.example.com'], ['block', 'b.example.com'], ['allow', 'c.example.com'],
    ['allow', 'd.example.com'], ['block', 'e.example.com']]) s = m.stage(s, op, d, 1).state;
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
    ['allow', 'c.example.com', 'dns-error']]);
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

test('applyPlan: confirmation needed for every rebuild, never for noop or persist-only', () => {
  assert.equal(m.applyPlan({ ok: true, mode: 'rebuild', plan: [{ change: ['block:add'] }] }).needsConfirm, true);
  // allow-only batches are rebuilds too (v1 never uses fast-allow)
  assert.equal(m.applyPlan({ ok: true, mode: 'rebuild', may_escalate: false, plan: [{ change: ['allow:add'] }] }).needsConfirm, true);
  assert.equal(m.applyPlan({ ok: true, mode: 'persist-only', plan: [{ change: ['allow:add'] }] }).needsConfirm, false);
  const noop = m.applyPlan({ ok: true, mode: 'rebuild', plan: [{ change: [] }] });
  assert.deepEqual([noop.noop, noop.needsConfirm], [true, false]);
  assert.equal(m.applyPlan({ ok: true, noop: true, job_id: null, plan: [] }).noop, true);
});

test('formatting: counts, percentages, durations, local times', () => {
  assert.equal(m.formatCount(1234567), '1,234,567');
  assert.equal(m.formatPct(15.4), '15.4 %');
  assert.equal(m.formatPct(null), '—');
  assert.deepEqual([0, 59, 60, 3599, 3600, 3660, 86400, 90000].map(m.formatDuration),
    ['0 s', '59 s', '1 min', '59 min', '1 h', '1 h 1 min', '1 d', '1 d 1 h']);
  const t = 1762747359;
  const d = new Date(t * 1000);
  assert.equal(m.formatTime(t), `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')} ${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}:${String(d.getSeconds()).padStart(2, '0')}`);
  assert.equal(m.formatTime(null), '—');
});

test('logWatch/logStalled: notice after a logd restart with no dnsmasq line since', () => {
  const g = m.LOG_STALL_GRACE;
  const rep = (...msgs) => ({ log: msgs.map((msg, i) => ({ id: i + 1, msg })) });
  const quiet = rep('netifd: up', 'dnsmasq-dhcp[1]: DHCPACK', 'logger: dnsmasq[1]: fake');
  // no reset: nothing pending, replies are not even needed
  assert.deepEqual(m.logWatch(null, [quiet], false, 100), { resetAt: null });
  // reset with only non-dnsmasq lines -> pending from now
  let w = m.logWatch(null, [quiet], true, 100);
  assert.deepEqual(w, { resetAt: 100 });
  assert.equal(m.logStalled(w, 100 + g - 1), false);   // grace
  // still silent: keeps the first reset time
  w = m.logWatch(w, [quiet], false, 130);
  assert.deepEqual(w, { resetAt: 100 });
  assert.equal(m.logStalled(w, 100 + g), true);
  // any dnsmasq line (also the refetch reply of the same poll) clears it
  assert.deepEqual(m.logWatch(w, [quiet, rep('dnsmasq[1]: started, version 2.93')], false, 140), { resetAt: null });
  // a reset whose reply already holds dnsmasq lines is not a stall
  assert.deepEqual(m.logWatch(null, [rep('dnsmasq[1]: 5 10.0.2.2/1 query[A] a.example.test from 10.0.2.2')], true, 100), { resetAt: null });
  // a second reset restarts the clock
  assert.deepEqual(m.logWatch({ resetAt: 100 }, [quiet], true, 200), { resetAt: 200 });
  // hostile shapes
  assert.deepEqual(m.logWatch(null, [null, { log: 'x' }, { log: [null, { msg: 7 }] }], true, 5), { resetAt: 5 });
  assert.equal(m.logStalled(null, 1e9), false);
});
