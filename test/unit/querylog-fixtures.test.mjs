// SPDX-License-Identifier: Apache-2.0
// querylog.js over real `log read` replies captured from an OpenWrt 25.12.6
// guest (logd + dnsmasq 2.93 + adblock-fast 1.2.4-r4,
// test/fixtures/logread/capture.sh), including polling with the adaptive
// window over a bounded logd ring, a dnsmasq restart and a logd restart.
import assert from 'node:assert/strict';
import test from 'node:test';
import { ql, fixture } from './querylog-load.mjs';

const OPTS = { local_domains: ['lan'] };
const brief = (r) => [r.domain, r.qtype, r.decision, r.source];

function load(name, opts = OPTS) {
  const st = ql.create(opts);
  const r = ql.ingest(st, fixture(name));
  assert.deepEqual([r.missed, r.reset, r.refetch], [0, false, null]);
  return st;
}

test('servers.json (dns=dnsmasq.servers): rows, CNAME chains, TTL, rejections', () => {
  const st = load('servers.json');
  const rows = ql.rows(st);
  const find = (d, t = 'A') => rows.find((r) => r.domain === d && r.qtype === t);
  assert.deepEqual(brief(find('ads.example.test')), ['ads.example.test', 'A', 'blocked', 'config']);
  assert.deepEqual(find('ads.example.test').answers, ['NXDOMAIN']);
  assert.deepEqual(brief(find('ads.example.test', 'HTTPS')), ['ads.example.test', 'HTTPS', 'blocked', 'config']);
  assert.deepEqual(brief(find('metrics.example.test')), ['metrics.example.test', 'A', 'blocked', 'config']);
  assert.deepEqual(brief(find('mixed.example.test')), ['mixed.example.test', 'A', 'blocked', 'config'],
    'dnsmasq lower-cased MiXeD');
  assert.deepEqual(brief(find('nx.example.test')), ['nx.example.test', 'A', 'allowed', 'upstream'],
    'upstream NXDOMAIN is not a block');
  assert.deepEqual(brief(find('www.up.example.test', 'HTTPS')), ['www.up.example.test', 'HTTPS', 'other', 'error']);
  assert.deepEqual(find('www.up.example.test', 'HTTPS').answers, ['REFUSED']);
  assert.deepEqual(brief(find('localhost')), ['localhost', 'A', 'other', 'hosts']);
  for (const d of ['openwrt.lan', 'wpad', 'printer.local'])
    assert.deepEqual(brief(find(d)).slice(2), ['other', 'local'], d);
  for (const r of rows.filter((x) => x.qtype === 'PTR'))
    assert.deepEqual([r.decision, r.source, r.answers], ['other', 'local', ['NXDOMAIN']], r.domain);
  assert.deepEqual(brief(find('err.example.test')).slice(2), ['no-answer', null], 'unanswered for > 10 s of log time');

  // CNAME chain via the second local dnsmasq: alias2 -> alias -> target (2 A, 1 AAAA)
  assert.deepEqual(find('alias2.cn.example.test').answers,
    ['alias.cn.example.test', 'target.cn.example.test', '192.0.2.30', '192.0.2.31']);
  assert.equal(find('alias2.cn.example.test').source, 'upstream');
  const aaaa = find('alias2.cn.example.test', 'AAAA');
  assert.deepEqual([aaaa.source, aaaa.answers], ['cache', ['alias.cn.example.test', 'target.cn.example.test', '2001:db8::30']],
    'decided by the first (cached) line; the refreshed chain only adds answers');
  assert.deepEqual(find('target.cn.example.test').answers, ['192.0.2.31', '192.0.2.30'], 'multi-record reply');

  for (const r of rows)
    assert.ok(!/[ <>A-Z]/.test(r.domain), `no spoofed row: ${r.domain}`);
  assert.equal(rows.some((r) => r.router), false);
  const all = ql.rows(st, { show_router: true });
  assert.deepEqual(all.filter((r) => r.router).map((r) => [r.client, ...brief(r)]), [
    ['::1', 'www.up.example.test', 'AAAA', 'allowed', 'cache'],
    ['::1', 'www.up.example.test', 'A', 'allowed', 'cache'],
    ['127.0.0.1', 'ads.example.test', 'AAAA', 'blocked', 'config'],
    ['127.0.0.1', 'ads.example.test', 'A', 'blocked', 'config']
  ]);
  assert.deepEqual(ql.stats(st), {
    kept: 24, blocked: 7, allowed: 9, other: 7, no_answer: 1, pending: 0, blocked_pct: 43.8, span_s: 14,
    missed_total: 0, dnsmasq_lost: 0, paused_total: 0, rejected: 4, since_open: { queries: 24, blocked: 7, allowed: 9 }
  });
  // newest first, times are epoch seconds from logd
  for (let i = 1; i < rows.length; i++)
    assert.ok(rows[i - 1].time >= rows[i].time);
  assert.ok(Number.isInteger(rows[0].time) && rows[0].time > 1.7e9 && rows[0].time < 2e9);
});

test('addnhosts.json (dns=dnsmasq.addnhosts): addnhosts source', () => {
  const rows = ql.rows(load('addnhosts.json'));
  const find = (d, t = 'A') => rows.find((r) => r.domain === d && r.qtype === t);
  for (const d of ['ads.example.test', 'telemetry.example.test', 'metrics.example.test']) {
    assert.deepEqual(brief(find(d)).slice(2), ['blocked', 'addnhosts'], d);
    assert.deepEqual(find(d).answers, ['127.0.0.1']);
  }
  // names absent from the hosts file but under a listed name are refused by config
  assert.deepEqual(brief(find('sub.ads.example.test')).slice(2), ['blocked', 'config']);
  assert.deepEqual(brief(find('ads.example.test', 'AAAA')).slice(2), ['blocked', 'config']);
});

test('restart.json: dnsmasq restart turns the in-flight query into no-answer', () => {
  const st = load('restart.json');
  const all = ql.rows(st, { show_router: true });
  assert.deepEqual(all.map((r) => [r.client, ...brief(r)]), [
    ['10.0.2.2', 'alias2.cn.example.test', 'A', 'allowed', 'upstream'],
    ['10.0.2.2', 'www.up.example.test', 'A', 'allowed', 'upstream'],
    ['10.0.2.2', 'ads.example.test', 'A', 'blocked', 'addnhosts'],
    ['127.0.0.1', 'a.up.example.test', 'AAAA', 'allowed', 'upstream'],
    ['127.0.0.1', 'a.up.example.test', 'A', 'allowed', 'upstream'],
    ['10.0.2.2', 'err.example.test', 'A', 'no-answer', null],
    ['10.0.2.2', 'www.up.example.test', 'A', 'allowed', 'cache'],
    ['10.0.2.2', 'ads.example.test', 'A', 'blocked', 'addnhosts']
  ]);
  assert.equal(new Set(all.map((r) => r.key)).size, all.length);
});

test('logd restart: ids go backwards -> reset, history kept, cursor follows the new ring', () => {
  const st = ql.create(OPTS);
  const before = fixture('logd-before.json'), after = fixture('logd-after.json');
  assert.ok(after.log[0].id === 0 && after.log.at(-1).id < before.log.at(-1).id);
  ql.ingest(st, before);
  const kept = ql.rows(st);
  assert.deepEqual(kept.map(brief), [
    ['www.up.example.test', 'A', 'allowed', 'cache'], ['ads.example.test', 'A', 'blocked', 'addnhosts']]);
  ql.ingest(st, { log: before.log.slice(-3) });                    // a poll with nothing new
  const r = ql.ingest(st, after);
  assert.deepEqual(r, { added: 0, missed: 0, paused: 0, reset: true, refetch: null });
  assert.deepEqual(ql.rows(st), kept);
  assert.equal(ql.stats(st).missed_total, 0);
  assert.equal(ql.nextRequest(st).lines, 900);
  assert.equal(st.cursor, after.log.at(-1).id);
  // the next poll continues on the new ring without another reset
  const r2 = ql.ingest(st, { log: after.log.slice(-5) });
  assert.deepEqual([r2.reset, r2.missed, r2.refetch], [false, 0, null]);
});

// Replays a fixture through a logd ring of `ring` entries, revealing `step`
// new entries per poll and answering each request like logd (the last N).
function poll(log, ring, step) {
  const st = ql.create(OPTS);
  let head = 0, polls = 0, refetches = 0;
  const read = (n) => ({ log: log.slice(Math.max(0, head - Math.min(n, ring)), head) });
  while (head < log.length) {
    head = Math.min(log.length, head + step);
    const r = ql.ingest(st, read(ql.nextRequest(st).lines));
    polls++;
    if (r.refetch) {
      refetches++;
      assert.ok(r.refetch.lines >= 16 && r.refetch.lines <= 900);
      assert.equal(ql.ingest(st, read(r.refetch.lines)).refetch, null, 'only one refetch');
    }
  }
  return { st, polls, refetches };
}

test('polling with the adaptive window reproduces the one-shot result', () => {
  for (const name of ['servers.json', 'addnhosts.json', 'restart.json']) {
    const log = fixture(name).log;
    const once = ql.rows(load(name));
    for (const step of [1, 3, 7, 25, 200]) {
      const { st } = poll(log, 900, step);
      assert.deepEqual(ql.rows(st), once, `${name} step ${step}`);
      assert.equal(ql.stats(st).missed_total, 0);
    }
  }
});

test('a ring smaller than one poll: refetch cannot help, missed equals the id gap', () => {
  const log = fixture('servers.json').log;
  const ring = 20, step = 35;
  const { st, refetches } = poll(log, ring, step);
  assert.ok(refetches > 0);
  // every poll after the first loses (step - ring) entries, the last one fewer
  let expected = 0, head = Math.min(log.length, step), cursor = log[head - 1].id;
  while (head < log.length) {
    head = Math.min(log.length, head + step);
    const first = log[head - Math.min(ring, head)].id;
    if (first > cursor + 1) expected += first - cursor - 1;
    cursor = log[head - 1].id;
  }
  assert.ok(expected > 0);
  assert.equal(ql.stats(st).missed_total, expected);
});

test('a short poll gap is closed by the refetch', () => {
  const log = fixture('servers.json').log;
  const st = ql.create(OPTS);
  ql.ingest(st, { log: log.slice(0, 10) });                         // N for the next poll: 31
  const r = ql.ingest(st, { log: log.slice(50, 81) });
  assert.ok(r.refetch && r.refetch.lines === log[80].id - log[9].id + 16);
  ql.ingest(st, { log: log.slice(Math.max(0, 81 - r.refetch.lines), 81) });
  ql.ingest(st, { log: log.slice(70) });
  assert.deepEqual(ql.rows(st), ql.rows(load('servers.json')));
  assert.equal(ql.stats(st).missed_total, 0);
});
