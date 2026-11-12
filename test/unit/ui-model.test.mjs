// SPDX-License-Identifier: Apache-2.0
// Executes the real LuCI resource htdocs/luci-static/resources/adblock-fast-monitor/model.js
// the way luci.js loads it: the file is the body of a factory function
// (window, document, L, ...requires) whose return value is a class that is
// instantiated once. Only `baseclass.extend` and `_` are provided by the harness.
import assert from 'node:assert/strict';
import test from 'node:test';
import { loadLuci } from './querylog-load.mjs';
import { validate } from '../browser/lib/schemas.mjs';

const m = loadLuci('adblock-fast-monitor/model.js');

const ok = (data) => m.settle(data);
const err = (code) => m.failure(new Error(`RPC call to x/y failed with error ${code}: msg`));
const inst = (o = {}) => ({ section: 'cfg01411c', confdir: '/tmp/dnsmasq.cfg01411c.d', dropin: false,
  uci_logqueries: false, running: true, logfacility_file: false, ...o });
// The full api-2 `info` reply (docs/CONTRACT.md §6.1); checked against the schema below.
const info = (over = {}) => ({
  api: 2, ok: true,
  monitor: { query_logging: true },
  local_domains: ['lan'],
  protected_suffixes: ['localhost', 'arpa', 'local', 'internal', 'invalid', 'onion', 'bind', 'lan', 'openwrt'],
  logd: { size_kib: 128 },
  adblock_fast: { installed: true, enabled: true, status: 'statusSuccess', dns: 'dnsmasq.servers',
    output_file: '/var/run/adblock-fast/dnsmasq.servers', output_exists: true, external_config: false, pending_uci_changes: false },
  dnsmasq: { running: true, instances: [inst({ dropin: true })] },
  warnings: [],
  ...over
});

test('the info fixtures match the api-2 schema (S3), so they cannot drift from the real replies', () => {
  assert.deepEqual(validate('info', info()), []);
  assert.deepEqual(validate('info', info({ warnings: ['query-logging-active', 'logd-to-flash', 'logd-remote'],
    dnsmasq: { running: false, instances: [inst({ confdir: null, reason: 'confdir-invalid', running: false })] } })), []);
  // the schema is strict: removed api-1/api-2-draft fields and unknown warnings fail
  assert.notDeepEqual(validate('info', info({ monitor: { query_logging: true, poll_interval: 2 } })), []);
  assert.notDeepEqual(validate('info', info({ warnings: ['nope'] })), []);
  assert.notDeepEqual(validate('info', { ...info(), api: 1 }), []);
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
  // one instance with a drop-in is enough; a bad confdir elsewhere does not matter then
  assert.deepEqual(st(ok(info({ dnsmasq: { running: true, instances: [inst({ dropin: true }), inst({ confdir: null })] } })), logOk),
    ['healthy', null]);
  assert.deepEqual(st(ok(info()), logErr), ['error', null]);
  assert.deepEqual(st(ok(info()), logErr, true), ['healthy', null]);   // keeps earlier rows
  assert.deepEqual(st(ok(info()), null), ['loading', null]);
  assert.deepEqual(st(err(-32000), logOk), ['healthy', null]);          // info failed: judge by the log
  assert.deepEqual(st(null, null), ['loading', null]);
});

test('poll interval is fixed at 2 s (§8.1)', () => {
  assert.equal(m.POLL_INTERVAL, 2);
});

test('§6.5 protected names: builtin list, local domains and info.protected_suffixes', () => {
  const p = m.protectedNames(ok(info({ local_domains: ['lan', 'Home.Example'], protected_suffixes: ['localhost', 'router-name', 'HB.example.net', 7] })));
  for (const d of ['x.internal', 'internal', 'a.b.home.arpa', 'localhost', 'z.local', '1.0.0.10.in-addr.arpa', 'x.onion',
    'y.invalid', 'version.bind', 'printer.lan', 'nas.home.example', 'router-name', 'hb.example.net', 'x.hb.example.net']) {
    assert.equal(m.isProtected(p, d), true, d);
  }
  for (const d of ['ads.example.test', 'internal.example.com', 'lan.example.com', 'notlan', 'xhb.example.net']) {
    assert.equal(m.isProtected(p, d), false, d);
  }
  assert.equal(p.filter((d) => d === 'localhost').length, 1, 'de-duplicated');
  // without info only the builtin list applies; hostile shapes are ignored
  const bare = m.protectedNames(err(-32002));
  assert.equal(m.isProtected(bare, 'x.internal'), true);
  assert.equal(m.isProtected(bare, 'printer.lan'), false);
  assert.equal(m.isProtected(m.protectedNames(ok(info({ protected_suffixes: 'lan', local_domains: null }))), 'x.lan'), false);
  assert.equal(m.isProtected(null, 'x.internal'), false);
  assert.equal(m.isProtected(bare, '__proto__'), false);
  // staging a block of a protected name is refused; allowing it is not
  assert.equal(m.stage(m.emptyPending(), 'block', 'X.Internal.', 1, p).error, 'protected-domain');
  assert.equal(m.stage(m.emptyPending(), 'allow', 'x.internal', 1, p).change, 'added');
  assert.equal(m.stage(m.emptyPending(), 'block', 'x.internal', 1).change, 'added');   // no list: the server decides
});

test('dnsModeNote: firewall modes and other resolvers are explained', () => {
  const mode = (dns) => m.dnsModeNote(ok(info({ adblock_fast: { installed: true, dns } })));
  assert.equal(mode('dnsmasq.ipset'), 'firewall');
  assert.equal(mode('dnsmasq.nftset'), 'firewall');
  assert.equal(mode('smartdns.domainset'), 'unsupported');
  assert.equal(mode('unbound.adb_list'), 'unsupported');
  for (const dns of ['dnsmasq.servers', 'dnsmasq.conf', 'dnsmasq.addnhosts', null, 7]) assert.equal(mode(dns), null, String(dns));
  assert.equal(m.dnsModeNote(err(-32002)), null);
});

test('backoffSkip: failed log reads wait 2^n polls, capped at 32 s', () => {
  assert.deepEqual([0, 1, 2, 3, 4, 5, 50, -1, 'x'].map(m.backoffSkip), [0, 1, 3, 7, 15, 15, 15, 0, 0]);
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
  // any other storage version is discarded
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

test('§8.4 in-flight batch is exactly the sent ops; items staged meanwhile stay pending', () => {
  const A = 'a.example.com', B = 'b.example.com', C = 'c.example.com';
  let s = m.stage(m.stage(m.emptyPending(), 'allow', A, 1).state, 'block', B, 2).state;
  const ops = m.toOps(s);
  // while the request runs: C staged (here or in another tab), B replaced by allow, A cancelled
  s = m.stage(s, 'block', C, 3).state;
  s = m.stage(s, 'allow', B, 4).state;
  s = m.unstage(s, A);
  const q = m.beginInflight(s, 'j1762747400-3f2a', ops);
  assert.deepEqual(q.inflight.items, [{ op: 'allow', domain: A, ts: 0 }, { op: 'block', domain: B, ts: 0 }]);
  assert.deepEqual(q.items.map((i) => [i.op, i.domain]), [['allow', B], ['block', C]]);
  // the job ends applied with entries only for the sent items: C is still pending
  const r = m.settleJob(q, { id: 'j1762747400-3f2a', state: 'applied', items: [{ domain: A, result: 'ok' }, { domain: B, result: 'ok' }] });
  assert.deepEqual(r.done, [A, B]);
  assert.deepEqual(r.state.items.map((i) => [i.op, i.domain]), [['allow', B], ['block', C]]);
  // applied without per-item entries: the sent items leave, nothing else
  const r2 = m.settleJob(m.beginInflight(m.stage(m.stage(m.emptyPending(), 'block', A, 1).state, 'block', C, 2).state,
    'j1762747400-3f2a', [{ op: 'block', domain: A }]), { id: 'j1762747400-3f2a', state: 'applied', items: [] });
  assert.deepEqual(r2.state.items.map((i) => i.domain), [C]);
  // a noop reply removes only the sent items
  const n = m.settleNoop(m.stage(s, 'allow', A, 5).state, ops);
  assert.deepEqual(n.items.map((i) => [i.op, i.domain]), [['allow', B], ['block', C]]);
  // without ops the whole list is the batch (resume path)
  assert.deepEqual(m.beginInflight(s, 'j1762747400-3f2a').items, []);
  assert.deepEqual(m.settleNoop(s).items, []);
});

test('applyPlan: confirmation needed for every rebuild, never for noop or persist-only', () => {
  assert.equal(m.applyPlan({ ok: true, mode: 'rebuild', plan: [{ change: ['block:add'] }] }).needsConfirm, true);
  // allow-only batches are rebuilds too
  assert.equal(m.applyPlan({ ok: true, mode: 'rebuild', plan: [{ change: ['allow:add'] }] }).needsConfirm, true);
  assert.equal(m.applyPlan({ ok: true, mode: 'persist-only', plan: [{ change: ['allow:add'] }] }).needsConfirm, false);
  const noop = m.applyPlan({ ok: true, mode: 'rebuild', plan: [{ change: [] }] });
  assert.deepEqual([noop.noop, noop.needsConfirm], [true, false]);
  assert.equal(m.applyPlan({ ok: true, noop: true, job_id: null, plan: [] }).noop, true);
});

test('fmt fills %s in order and keeps %%', () => {
  assert.equal(m.fmt('%s of %s = %s %%', 1, 2, 50), '1 of 2 = 50 %');
  assert.equal(m.fmt('none'), 'none');
});

test('formatting: counts, percentages, durations, clock times', () => {
  assert.equal(m.formatCount(1234567), '1,234,567');
  assert.equal(m.formatPct(15.4), '15 %');
  assert.equal(m.formatPct(33.5), '34 %');
  assert.equal(m.formatPct(0), '0 %');
  assert.equal(m.formatPct(0.4), '<1 %');
  assert.equal(m.formatPct(100), '100 %');
  assert.equal(m.formatPct(null), '—');
  assert.deepEqual([0, 59, 60, 3599, 3600, 3660, 86400, 90000].map(m.formatDuration),
    ['0 s', '59 s', '1 min', '59 min', '1 h', '1 h 1 min', '1 d', '1 d 1 h']);
  const t = 1762747359;
  const d = new Date(t * 1000);
  assert.equal(m.formatClock(t), `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}:${String(d.getSeconds()).padStart(2, '0')}`);
  assert.equal(m.formatClock(null), '—');
});

test('summary: the one-line statistics of the page and the Status include', () => {
  const stats = (o) => ({ kept: 0, blocked: 0, allowed: 0, other: 0, no_answer: 0, pending: 0, blocked_pct: null, span_s: 0, ...o });
  assert.deepEqual(m.summary(stats({ kept: 13, blocked: 4, allowed: 8, other: 1, blocked_pct: 33.3, span_s: 8 }), null),
    { pct: 33.3, value: '33 %', text: '4 of 12 queries blocked in the last 8 s' });
  assert.deepEqual(m.summary(stats({ blocked: 1500, allowed: 500, blocked_pct: 75, span_s: 125 }), null),
    { pct: 75, value: '75 %', text: '1,500 of 2,000 queries blocked in the last 2 min' });
  // no answered query yet (only pending or other rows): no percentage
  assert.deepEqual(m.summary(stats({ kept: 2, other: 1, pending: 1 }), null), { pct: null, value: null, text: 'No queries yet.' });
  assert.deepEqual(m.summary(null, null), { pct: null, value: null, text: 'No queries yet.' });
  // the log cannot show blocks in the firewall modes, nor for other resolvers
  const fw = m.summary(stats({ blocked: 0, allowed: 9, blocked_pct: 0 }), 'firewall');
  assert.deepEqual([fw.pct, fw.value], [null, null]);
  assert.match(fw.text, /firewall/);
  assert.match(m.summary(stats({ allowed: 9 }), 'unsupported').text, /does not use dnsmasq/);
});

test('loggingSource and loggingRisks: the query-logging line and the turn-on question', () => {
  assert.equal(m.loggingSource(null), null);
  assert.equal(m.loggingSource(err(-32002)), null);
  assert.equal(m.loggingSource(ok(info())), 'ours');
  assert.equal(m.loggingSource(ok(info({ monitor: { query_logging: false } }))), 'off');
  // dnsmasq's own logqueries wins: this app's switch does not matter then
  assert.equal(m.loggingSource(ok(info({ dnsmasq: { running: true, instances: [inst({ uci_logqueries: true })] } }))), 'elsewhere');
  assert.deepEqual(m.loggingRisks(ok(info({ warnings: ['query-logging-active', 'logd-remote', 'logd-to-flash'] }))),
    ['logd-to-flash', 'logd-remote']);
  assert.deepEqual(m.loggingRisks(ok(info({ warnings: ['query-logging-active'] }))), []);
  assert.deepEqual(m.loggingRisks(null), []);
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

test('edges: job id anchors, multi-digit codes, length limits, numeric parsing', () => {
  for (const id of ['xj1762747400-3f2a', 'j1762747400-3f2aX', 'j176274740-3f2a', 'j1762747400-3F2A']) {
    assert.equal(m.parsePending(JSON.stringify({ v: 2, items: [], inflight: { job_id: id, items: [] } })).inflight, null, id);
  }
  assert.equal(m.rpcError(new Error('RPC call to a/b failed with ubus code 10: x')).ubus, 10);
  assert.equal(m.rpcError(new Error('RPC call to a/b failed with error -32602: x')).rpc, -32602);
  const d253 = `${'a'.repeat(63)}.${'b'.repeat(63)}.${'c'.repeat(63)}.${'d'.repeat(57)}.com`;
  assert.equal(d253.length, 253);
  assert.equal(m.normalizeDomain(d253), d253);
  assert.equal(m.normalizeDomain(`a${d253}`), null);
  assert.equal(m.normalizeDomain(`${'a.'.repeat(126)}c`), `${'a.'.repeat(126)}c`);   // 127 labels, 253 chars
  assert.equal(m.normalizeDomain('a.12'), null);
  assert.equal(m.normalizeDomain('a.1b'), 'a.1b');
  assert.equal(m.normalizeDomain('a.b1'), 'a.b1');
  for (const v of [true, false, '', null, undefined, 'x', NaN]) assert.equal(m.formatCount(v), '0', String(v));
  assert.equal(m.formatClock(0), '—');
  assert.equal(m.formatClock(true), '—');
  assert.deepEqual(m.parsePending({ v: 2, items: [{ op: 'block', domain: 'a.example.com', ts: '5', reason: 'x'.repeat(100) }] }).items,
    [{ op: 'block', domain: 'a.example.com', ts: 5, reason: 'x'.repeat(64) }]);
  assert.deepEqual(m.markError(m.emptyPending(), null), m.emptyPending());
  assert.equal(m.applyPlan(null).mode, null);
  assert.equal(m.applyPlan({ ok: true, mode: 'rebuild', plan: [] }).noop, false);
});
