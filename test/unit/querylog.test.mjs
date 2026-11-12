// SPDX-License-Identifier: Apache-2.0
// Behaviour of the real querylog.js (docs/CONTRACT.md
// §8.1-§8.3): grammar and classification table, spoofing rejections,
// raw strings, request sizing, gaps and refetch, restarts, CNAME chains, the
// pending TTL, router hiding, statistics and the row cap.
import assert from 'node:assert/strict';
import test from 'node:test';
import { ql, reply } from './querylog-load.mjs';

const T0 = 1794354461000;
const C = '192.0.2.10';
let serial = 1;

// One query from a LAN client and its answer lines; returns the row.
function decide(tail, { qtype = 'A', name = 'ads.example.test', opts = {}, client = C } = {}) {
  const st = ql.create({ local_domains: ['lan'], ...opts });
  const s = serial++;
  const head = `dnsmasq[1]: ${s} ${client}/5353 `;
  const lines = [`${head}query[${qtype}] ${name} from ${client}`]
    .concat((Array.isArray(tail) ? tail : [tail]).map((t) => head + t));
  ql.ingest(st, reply(lines));
  const rows = ql.rows(st, { show_router: true });
  assert.equal(rows.length, 1, `one row for ${lines.join(' | ')}`);
  return { row: rows[0], st };
}
const outcome = (tail, o) => {
  const { row } = decide(tail, o);
  return [row.decision, row.source];
};

test('T03: §8.3 classification table: config answers', () => {
  for (const a of ['NXDOMAIN', 'NODATA', 'NODATA-IPv4', 'NODATA-IPv6', '0.0.0.0', '::', '127.0.0.1'])
    assert.deepEqual(outcome(`config ads.example.test is ${a}`), ['blocked', 'config'], a);
  assert.deepEqual(outcome('config ads.example.test is 198.51.100.7'), ['other', 'config'], 'address=');
  assert.deepEqual(outcome('config ads.example.test is <CNAME>'), ['other', 'config'], 'local cname=');
});

test('§8.3 local names: judged on the query name, never blocked', () => {
  const local = (name, opts) => outcome(`config ${name} is NXDOMAIN`, { name, opts });
  for (const n of ['wpad', 'openwrt.lan', 'a.b.lan', 'printer.local', 'x.localhost', 'x.invalid',
    'x.onion', 'version.bind', '1.0.0.10.in-addr.arpa', 'home.arpa'])
    assert.deepEqual(local(n), ['other', 'local'], n);
  assert.deepEqual(local('nas.home', { local_domains: ['home'] }), ['other', 'local'], 'dhcp domain from info');
  assert.deepEqual(local('nas.home', { local_domains: [] }), ['blocked', 'config'], 'without it: blocked');
  assert.deepEqual(local('notlan', { local_domains: ['lan'] }), ['other', 'local'], 'single label');
  assert.deepEqual(local('xlan.example.test'), ['blocked', 'config'], 'suffix must be a whole label');
  assert.deepEqual(local('ads.example.test'), ['blocked', 'config'], '`test` is not special-use here');
  // reverse lookups log the address on the terminal line; the query name decides
  assert.deepEqual(outcome('config 10.0.0.1 is NXDOMAIN', { name: '1.0.0.10.in-addr.arpa', qtype: 'PTR' }),
    ['other', 'local']);
  assert.deepEqual(outcome('config fd00::1 is NXDOMAIN', { name: 'example.test', qtype: 'PTR' }),
    ['blocked', 'config'], 'locality is not judged on the logged address');
  assert.deepEqual(outcome('config 192.0.2.1 is NXDOMAIN', { name: '192.0.2.1' }), ['other', 'local'], 'address');
});

test('§8.3 classification table: hosts, DHCP, reply, cache, auth', () => {
  assert.deepEqual(outcome('/var/run/adblock-fast/dnsmasq.addnhosts ads.example.test is ::'), ['blocked', 'addnhosts']);
  assert.deepEqual(outcome('/var/run/adblock-fast/dnsmasq.addnhosts ads.example.test is 127.0.0.1'), ['blocked', 'addnhosts']);
  assert.deepEqual(outcome('/etc/hosts ads.example.test is 127.0.0.1'), ['other', 'hosts']);
  assert.deepEqual(outcome('/tmp/hosts/dhcp.cfg01411c router.lan is 192.168.1.1', { name: 'router.lan' }), ['other', 'hosts']);
  assert.deepEqual(outcome('DHCP host.example.test is 192.0.2.5', { name: 'host.example.test' }), ['other', 'dhcp']);
  for (const a of ['SERVFAIL', 'REFUSED', 'FORMERR', '3', '15'])
    assert.deepEqual(outcome(`reply ads.example.test is ${a}`), ['other', 'error'], a);
  assert.deepEqual(outcome('reply ads.example.test is SERVFAIL (EDE: network error)'), ['other', 'error'], 'EDE suffix');
  for (const a of ['192.0.2.1', '2001:db8::1', '<CNAME>', '<HTTPS>', 'NXDOMAIN', 'NODATA', 'NODATA-IPv6'])
    assert.deepEqual(outcome(`reply ads.example.test is ${a}`), ['allowed', 'upstream'], a);
  assert.deepEqual(outcome('cached ads.example.test is 192.0.2.1'), ['allowed', 'cache']);
  assert.deepEqual(outcome('cached-stale ads.example.test is 192.0.2.1'), ['allowed', 'cache']);
  assert.deepEqual(outcome('auth ads.example.test is 192.0.2.1'), ['other', 'auth']);
});

test('§8.3 TCP/UDP prefix and the first terminal line decides', () => {
  const st = ql.create();
  ql.ingest(st, reply([
    'dnsmasq[1]: TCP 7 192.0.2.10/40000 query[A] tcp.example.test from 192.0.2.10',
    'dnsmasq[1]: TCP 7 192.0.2.10/40000 forwarded tcp.example.test to 192.0.2.53',
    'dnsmasq[1]: TCP 7 192.0.2.10/40000 reply tcp.example.test is 192.0.2.1',
    'dnsmasq[1]: TCP 7 192.0.2.10/40000 config tcp.example.test is NXDOMAIN'
  ]));
  const [r] = ql.rows(st);
  assert.deepEqual([r.decision, r.source, r.answers], ['allowed', 'upstream', ['192.0.2.1', 'NXDOMAIN']]);
});

test('non-terminal, ignored and duplicate lines leave the query pending', () => {
  for (const t of ['forwarded ads.example.test to 192.0.2.53', 'reply query is duplicate',
    'validation ads.example.test is 192.0.2.1', 'dnssec-query[DS] example.test to 192.0.2.53',
    'reply ads.example.test to 192.0.2.1'])
    assert.deepEqual(outcome(t), ['pending', null], t);
  // a repeated query line does not open a second entry
  const st = ql.create();
  const q = 'dnsmasq[1]: 3 192.0.2.10/1 query[A] a.example.test from 192.0.2.10';
  assert.equal(ql.ingest(st, reply([q, q])).added, 1);
  assert.equal(ql.rows(st).length, 1);
});

test('orphan answers (query not seen) are ignored', () => {
  const st = ql.create();
  ql.ingest(st, reply(['dnsmasq[1]: 9 192.0.2.10/1 config ads.example.test is NXDOMAIN']));
  assert.deepEqual(ql.rows(st), []);
  assert.equal(ql.stats(st).kept, 0);
});

test('§8.3 spoofing and malformed lines are rejected', () => {
  const st = ql.create();
  const msgs = [
    'dnsmasq[1]: 1 192.0.2.10/1 query[A] victim.example.com is 0.0.0.0.example.test from 192.0.2.10',
    'dnsmasq[1]: 2 192.0.2.10/1 query[A] <name unprintable> from 192.0.2.10',
    'dnsmasq[1]: 3 192.0.2.10/1 query[A] MiXeD.example.test from 192.0.2.10',
    'dnsmasq[1]: 4 192.0.2.10/1 query[A] a.example.test from 192.0.2.10 extra',
    'dnsmasq[1]: 5 192.0.2.10/1 query[A] a b.example.test from 192.0.2.10',
    'dnsmasq[1]: 6 192.0.2.10 query[A] a.example.test from 192.0.2.10',
    'dnsmasq[1]: 7 192.0.2.10/1 query[A] a.example.test frm 192.0.2.10',
    'dnsmasq[1]: 8 192.0.2.10/1 reply a.example.test is not implemented'
  ];
  ql.ingest(st, reply(msgs));
  assert.deepEqual(ql.rows(st), []);
  assert.equal(ql.stats(st).rejected, msgs.length);

  const other = ql.create();
  ql.ingest(other, reply([
    'dnsmasq-dhcp[1]: 1 192.0.2.10/1 query[A] a.example.test from 192.0.2.10',
    'abfm[1]: 1 192.0.2.10/1 query[A] a.example.test from 192.0.2.10',
    ' dnsmasq[1]: 1 192.0.2.10/1 query[A] a.example.test from 192.0.2.10',
    'dnsmasq[x]: 1 192.0.2.10/1 query[A] a.example.test from 192.0.2.10',
    'dnsmasq[1]: 1 192.0.2.10/1 query[A]] a.example.test from 192.0.2.10',
    'dnsmasq[1]: 1 192.0.2.10/1 query[] a.example.test from 192.0.2.10',
    'dnsmasq[1]: 1 192.0.2.10/1 query a.example.test from 192.0.2.10',
    'dnsmasq[1]: started, version 2.93 cachesize 1000',
    'dnsmasq[1]: read /etc/hosts - 12 names'
  ]));
  assert.deepEqual(ql.rows(other), []);
  assert.equal(ql.stats(other).rejected, 0, 'informational and foreign lines are ignored silently');

  // a spoofed answer on a real query rejects only that line; the entry stays pending
  const { row } = decide(['config ads.example.test is 0.0.0.0 x', 'config ads.example.test is NX DOMAIN']);
  assert.equal(row.decision, 'pending');
});

test('T01: §8.3 LOST lines count as missed (shown), with dnsmasq_lost as the breakdown', () => {
  const st = ql.create();
  ql.ingest(st, reply(['dnsmasq[1]: overflow: 12 log entries lost', 'dnsmasq[1]: overflow: 3 log entries lost',
    'dnsmasq[1]: overflow: x log entries lost']));
  assert.equal(ql.stats(st).dnsmasq_lost, 15);
  assert.equal(ql.stats(st).missed_total, 15, 'the page shows missed_total');
  // a later log-id gap adds to the same total; LOST does not force a full refetch
  assert.equal(ql.nextRequest(st).lines, Math.ceil(1.2 * 3) + 16);
  const far = reply(Array.from({ length: 900 }, () => 'kernel: b'), { id: 2000 });
  assert.deepEqual(ql.ingest(st, far).refetch, { lines: 900 });
  assert.equal(ql.ingest(st, far).missed, 2000 - 102 - 1);
  assert.equal(ql.stats(st).missed_total, 15 + (2000 - 102 - 1));
  assert.equal(ql.stats(st).dnsmasq_lost, 15);
});

test('T02: raw strings: an HTML payload in a PTR answer is kept verbatim', () => {
  const payload = '<img/src=x/onerror=window.__x=1>';
  const { row } = decide(`reply 203.0.113.5 is ${payload}`, { name: '5.113.0.203.in-addr.arpa', qtype: 'PTR' });
  assert.deepEqual(row.answers, [payload]);
  assert.equal(row.domain, '5.113.0.203.in-addr.arpa');
  const amp = decide('reply example.test is &lt;b&gt;"\'', { name: 'example.test', qtype: 'PTR' }).row;
  assert.deepEqual(amp.answers, ['&lt;b&gt;"\'']);
});

test('CNAME chain: names replace <CNAME>, at most 4 answers, decision unchanged', () => {
  const { row } = decide([
    'reply a.example.test is <CNAME>',
    'reply b.example.test is <CNAME>',
    'reply c.example.test is <CNAME>',
    'reply d.example.test is 192.0.2.1',
    'reply d.example.test is 192.0.2.2',
    'config d.example.test is NXDOMAIN'
  ], { name: 'a.example.test' });
  assert.deepEqual([row.decision, row.source], ['allowed', 'upstream']);
  assert.deepEqual(row.answers, ['b.example.test', 'c.example.test', 'd.example.test', '192.0.2.1']);
  assert.ok(row.answers.length <= ql.ANSWERS_MAX);
  // a chain that never resolves shows the placeholder
  assert.deepEqual(decide('config a.example.test is <CNAME>', { name: 'a.example.test' }).row.answers, ['<CNAME>']);
  // repeated values are shown once
  assert.deepEqual(decide(['cached a.example.test is 192.0.2.1', 'reply a.example.test is 192.0.2.1'],
    { name: 'a.example.test' }).row.answers, ['192.0.2.1']);
});

test('T04: nextRequest: 900 first, adaptive clamp(1.2*batch+16), never <16, >900 or 0', () => {
  const st = ql.create();
  assert.deepEqual(ql.nextRequest(st), { lines: 900 });
  assert.deepEqual(ql.nextRequest(st), { lines: 900 }, 'pure');
  let id = 0;
  const sizes = [0, 0, 1, 2, 10, 100, 300, 589, 590, 599, 600, 900, 3, 0, 5000, 1];
  for (const n of sizes) {
    const req = ql.nextRequest(st).lines;
    const batch = Math.min(n, req);
    const msgs = Array.from({ length: batch }, () => 'kernel: x');
    ql.ingest(st, reply(msgs, { id: id + 1 }));
    id += batch;
    const next = ql.nextRequest(st).lines;
    assert.ok(Number.isInteger(next) && next >= 16 && next <= 900, `${n} -> ${next}`);
    assert.equal(next, Math.min(900, Math.max(16, Math.ceil(1.2 * batch) + 16)), `batch ${batch}`);
  }
  for (let i = 0; i < 2000; i++) {
    const s = ql.create();
    ql.ingest(s, reply(Array.from({ length: i % 950 }, () => 'x: y'), { id: 1 }));
    const n = ql.nextRequest(s).lines;
    assert.ok(n >= 16 && n <= 900 && n !== 0);
  }
});

test('gap: one refetch of min(900, lastId-cursor+16), then the rest is missed', () => {
  const st = ql.create();
  const filler = (n) => Array.from({ length: n }, (_, i) => `kernel: ${i}`);
  ql.ingest(st, reply(filler(10), { id: 1 }));                 // cursor 10, batch 10
  assert.equal(ql.nextRequest(st).lines, 28);
  // 28 lines requested, ids 50..77 returned: 39 entries not seen
  let r = ql.ingest(st, reply(filler(28), { id: 50 }));
  assert.deepEqual(r, { added: 0, missed: 0, paused: 0, reset: false, refetch: { lines: 77 - 10 + 16 } });
  assert.equal(ql.stats(st).missed_total, 0, 'nothing ingested from the gapped reply');
  // the refetch reaches back far enough: no gap
  r = ql.ingest(st, reply(filler(83), { id: 1 }));
  assert.deepEqual(r, { added: 0, missed: 0, paused: 0, reset: false, refetch: null });
  assert.equal(st.cursor, 83);

  // still a gap after the refetch: counted, no second refetch
  ql.ingest(st, reply(filler(13), { id: 84 }));                 // cursor 96, batch 13
  r = ql.ingest(st, reply(filler(32), { id: 200 }));
  assert.deepEqual(r.refetch, { lines: 231 - 96 + 16 });
  r = ql.ingest(st, reply(filler(146), { id: 150 }));
  assert.deepEqual(r, { added: 0, missed: 150 - 96 - 1, paused: 0, reset: false, refetch: null });
  assert.equal(ql.stats(st).missed_total, 53);
  assert.equal(ql.nextRequest(st).lines, 900, 'after a miss ask for the maximum');

  // a gap on a 900-line request is counted at once (no refetch can help)
  ql.ingest(st, reply(filler(900), { id: 1001 }));
  assert.equal(ql.stats(st).missed_total, 53 + (1001 - 295 - 1));
  // the refetch is capped at 900
  ql.ingest(st, reply(filler(5), { id: 1901 }));
  r = ql.ingest(st, reply(filler(23), { id: 5000 }));
  assert.deepEqual(r.refetch, { lines: 900 });
});

test('overlapping replies ingest each entry once', () => {
  const st = ql.create();
  const q = (s, p) => `dnsmasq[1]: ${s} 192.0.2.10/${p} query[A] e${s}.example.test from 192.0.2.10`;
  assert.equal(ql.ingest(st, reply([q(1, 1), q(2, 2)], { id: 1 })).added, 2);
  assert.equal(ql.ingest(st, reply([q(1, 1), q(2, 2), q(3, 3)], { id: 1 })).added, 1);
  assert.equal(ql.ingest(st, reply([], { id: 1 })).added, 0);
  assert.equal(ql.rows(st).length, 3);
  assert.equal(ql.nextRequest(st).lines, 16, 'empty reply');
});

test('dnsmasq restart (`started, version`): pending -> no-answer, serials start again', () => {
  const st = ql.create();
  const h = (s) => `dnsmasq[1]: ${s} 192.0.2.10/5353 `;
  ql.ingest(st, reply([
    `${h(1)}query[A] old.example.test from 192.0.2.10`,
    `${h(2)}query[A] lost.example.test from 192.0.2.10`,
    `${h(1)}config old.example.test is NXDOMAIN`,
    'dnsmasq[1]: exiting on receipt of SIGTERM',
    'dnsmasq[1]: started, version 2.93 cachesize 1000',
    `${h(2)}reply lost.example.test is 192.0.2.1`,     // same key, new instance: orphan
    `${h(1)}query[A] new.example.test from 192.0.2.10`, // same key as old.example.test
    `${h(1)}reply new.example.test is 192.0.2.2`
  ]));
  const rows = ql.rows(st);
  assert.deepEqual(rows.map((r) => [r.domain, r.decision, r.source]), [
    ['new.example.test', 'allowed', 'upstream'],
    ['lost.example.test', 'no-answer', null],
    ['old.example.test', 'blocked', 'config']
  ]);
  assert.notEqual(rows[0].key, rows[2].key, 'row keys stay unique across restarts');
});

test('pending TTL is log time: 10 s -> no-answer, late answers ignored', () => {
  const st = ql.create({ pending_ttl_s: 10 });
  const h = 'dnsmasq[1]: 1 192.0.2.10/5353 ';
  ql.ingest(st, reply([[`${h}query[A] slow.example.test from 192.0.2.10`, T0], ['kernel: tick', T0 + 9999]], { id: 1 }));
  assert.equal(ql.rows(st)[0].decision, 'pending');
  assert.equal(ql.stats(st).pending, 1);
  ql.ingest(st, reply([['kernel: tick', T0 + 10000], [`${h}reply slow.example.test is 192.0.2.1`, T0 + 10000]], { id: 3 }));
  const [r] = ql.rows(st);
  assert.deepEqual([r.decision, r.source, r.answers], ['no-answer', null, []]);
  assert.equal(ql.stats(st).no_answer, 1);

  // an answer just inside the TTL decides
  const ok = ql.create();
  ql.ingest(ok, reply([[`${h}query[A] slow.example.test from 192.0.2.10`, T0],
    [`${h}reply slow.example.test is 192.0.2.1`, T0 + 9999]], { id: 1 }));
  assert.equal(ql.rows(ok)[0].decision, 'allowed');
});

test('router clients are hidden by default and not counted since open', () => {
  const st = ql.create();
  ql.ingest(st, reply([
    'dnsmasq[1]: 1 127.0.0.1/1 query[A] a.example.test from 127.0.0.1',
    'dnsmasq[1]: 1 127.0.0.1/1 config a.example.test is NXDOMAIN',
    'dnsmasq[1]: 2 ::1/1 query[A] b.example.test from ::1',
    'dnsmasq[1]: 2 ::1/1 reply b.example.test is 192.0.2.1',
    'dnsmasq[1]: 3 192.0.2.10/1 query[A] c.example.test from 192.0.2.10',
    'dnsmasq[1]: 3 192.0.2.10/1 reply c.example.test is 192.0.2.1'
  ]));
  assert.deepEqual(ql.rows(st).map((r) => r.domain), ['c.example.test']);
  const all = ql.rows(st, { show_router: true });
  assert.deepEqual(all.map((r) => [r.domain, r.client, r.router]), [
    ['c.example.test', '192.0.2.10', false], ['b.example.test', '::1', true], ['a.example.test', '127.0.0.1', true]]);
  assert.deepEqual(ql.stats(st).since_open, { queries: 1, blocked: 0, allowed: 1 });
  assert.equal(ql.stats(st, { show_router: true }).kept, 3);
  assert.equal(ql.stats(st, { show_router: true }).blocked_pct, 33.3);

  const shown = ql.create({ hide_router: false });
  ql.ingest(shown, reply(['dnsmasq[1]: 1 127.0.0.1/1 query[A] a.example.test from 127.0.0.1']));
  assert.equal(ql.rows(shown).length, 1);
  assert.equal(ql.stats(shown).since_open.queries, 1);
});

test('stats: blocked_pct null without blocked+allowed, rounding, span, counts', () => {
  const st = ql.create();
  assert.deepEqual(ql.stats(st), {
    kept: 0, blocked: 0, allowed: 0, other: 0, no_answer: 0, pending: 0, blocked_pct: null, span_s: 0,
    missed_total: 0, dnsmasq_lost: 0, paused_total: 0, rejected: 0, since_open: { queries: 0, blocked: 0, allowed: 0 }
  });
  const h = (s) => `dnsmasq[1]: ${s} 192.0.2.10/${s} `;
  ql.ingest(st, reply([
    [`${h(1)}query[A] wpad from 192.0.2.10`, T0], [`${h(1)}config wpad is NXDOMAIN`, T0],
    [`${h(2)}query[A] p.example.test from 192.0.2.10`, T0 + 4600]
  ]));
  let s = ql.stats(st);
  assert.deepEqual([s.kept, s.other, s.pending, s.blocked_pct, s.span_s], [2, 1, 1, null, 5]);
  ql.ingest(st, reply([
    [`${h(3)}query[A] a.example.test from 192.0.2.10`, T0 + 5000], [`${h(3)}config a.example.test is NXDOMAIN`, T0 + 5000],
    [`${h(4)}query[A] b.example.test from 192.0.2.10`, T0 + 5000], [`${h(4)}cached b.example.test is 192.0.2.1`, T0 + 5000],
    [`${h(5)}query[A] c.example.test from 192.0.2.10`, T0 + 5000], [`${h(5)}cached c.example.test is 192.0.2.1`, T0 + 5000]
  ], { id: 103 }));
  s = ql.stats(st);
  assert.deepEqual([s.kept, s.blocked, s.allowed, s.other, s.pending, s.blocked_pct],
    [5, 1, 2, 1, 1, 33.3]);
  assert.deepEqual(s.since_open, { queries: 5, blocked: 1, allowed: 2 });
});

test('row cap: at most max_rows (≤500) entries, oldest dropped first', () => {
  const st = ql.create();
  const msgs = [];
  for (let i = 1; i <= 650; i++)
    msgs.push(`dnsmasq[1]: ${i} 192.0.2.10/${i} query[A] d${i}.example.test from 192.0.2.10`,
      `dnsmasq[1]: ${i} 192.0.2.10/${i} reply d${i}.example.test is 192.0.2.1`);
  ql.ingest(st, reply(msgs.slice(0, 900), { id: 1 }));
  ql.ingest(st, reply(msgs.slice(900), { id: 901 }));
  const rows = ql.rows(st);
  assert.equal(rows.length, 500);
  assert.equal(rows[0].domain, 'd650.example.test');
  assert.equal(rows[499].domain, 'd151.example.test');
  assert.equal(st.pending.size, 0);
  assert.equal(ql.stats(st).since_open.queries, 650);
  // answers for evicted entries are orphans
  ql.ingest(st, reply(['dnsmasq[1]: 1 192.0.2.10/1 config d1.example.test is NXDOMAIN'], { id: 1301 }));
  assert.equal(ql.stats(st).blocked, 0);

  const small = ql.create({ max_rows: 3 });
  ql.ingest(small, reply(msgs.slice(0, 20), { id: 1 }));
  assert.deepEqual(ql.rows(small).map((r) => r.domain), ['d10.example.test', 'd9.example.test', 'd8.example.test']);
  assert.equal(ql.create({ max_rows: 5000 }).maxRows, 500);
  // pending entries are bounded by the same cap
  const p = ql.create();
  ql.ingest(p, reply(Array.from({ length: 900 }, (_, i) =>
    `dnsmasq[1]: ${i} 192.0.2.10/1 query[A] p${i}.example.test from 192.0.2.10`), { id: 1 }));
  assert.equal(p.pending.size, 500);
});

test('rows are copies: mutating them does not change the state', () => {
  const { row, st } = decide('reply ads.example.test is 192.0.2.1');
  row.answers.push('x');
  row.decision = 'blocked';
  assert.deepEqual(ql.rows(st)[0].answers, ['192.0.2.1']);
  assert.equal(ql.rows(st)[0].decision, 'allowed');
});

test('§8.1 logd restart drops the pending queries (they become no-answer), keeps answered rows', () => {
  const st = ql.create();
  const h = (s) => `dnsmasq[1]: ${s} ${C}/${s} `;
  ql.ingest(st, reply([`${h(1)}query[A] answered.example.test from ${C}`, `${h(1)}reply answered.example.test is 192.0.2.1`,
    `${h(2)}query[A] waiting.example.test from ${C}`], { id: 500 }));
  assert.equal(ql.stats(st).pending, 1);
  // ids go backwards: logd restarted; the answer to serial 2 that arrives now is ignored
  const r = ql.ingest(st, reply([`${h(2)}reply waiting.example.test is 192.0.2.2`], { id: 0 }));
  assert.equal(r.reset, true);
  const rows = Object.fromEntries(ql.rows(st).map((x) => [x.domain, x.decision]));
  assert.deepEqual(rows, { 'answered.example.test': 'allowed', 'waiting.example.test': 'no-answer' });
  assert.equal(ql.stats(st).pending, 0);
  assert.equal(st.pending.size, 0);
});

test('§8.1 resume after a hidden page: one right-sized request, a remaining gap is paused, not missed', () => {
  const st = ql.create();
  const filler = (n, id) => reply(Array.from({ length: n }, (_, i) => `kernel: ${i}`), { id });
  ql.ingest(st, filler(10, 1));                                   // cursor 10, batch 10
  // 30 polls skipped: ceil(1.2 * 10 * 30) + 16 = 376 lines, once
  ql.resume(st, 30);
  assert.equal(ql.nextRequest(st).lines, 376);
  assert.equal(ql.nextRequest(st).lines, 376, 'pure');
  // the ring moved 5000 entries meanwhile: the reply starts far beyond the cursor
  let r = ql.ingest(st, filler(376, 5001));
  assert.deepEqual(r.refetch, { lines: 900 });
  r = ql.ingest(st, filler(900, 4477));
  assert.deepEqual([r.missed, r.paused], [0, 4477 - 10 - 1]);
  const s = ql.stats(st);
  assert.deepEqual([s.missed_total, s.paused_total], [0, 4466]);
  // back to normal sizing (the last batch was 900 new entries); the next gap is a real miss again
  assert.equal(ql.nextRequest(st).lines, 900);
  ql.ingest(st, filler(20, 5377));
  assert.equal(ql.nextRequest(st).lines, Math.ceil(1.2 * 20) + 16);
  ql.ingest(st, filler(40, 9000));
  ql.ingest(st, filler(900, 9000));
  assert.equal(ql.stats(st).missed_total, 9000 - 5396 - 1);
  assert.equal(ql.stats(st).paused_total, 4466);
  // resume before any read asks for the maximum; nothing to resume from
  const fresh = ql.create();
  ql.resume(fresh, 3);
  assert.equal(ql.nextRequest(fresh).lines, 900);
  // a resume that finds no gap leaves both totals alone; garbage counts as one poll
  const q = ql.create();
  ql.ingest(q, filler(4, 1));
  ql.resume(q, 'x');
  assert.equal(ql.nextRequest(q).lines, Math.ceil(1.2 * 4) + 16);
  ql.ingest(q, filler(6, 1));
  assert.deepEqual([ql.stats(q).missed_total, ql.stats(q).paused_total], [0, 0]);
});

test('keys carry the dnsmasq restart epoch and the full pid; only tagged, anchored lines count', () => {
  const st = ql.create();
  ql.ingest(st, reply([
    `dnsmasq[12]: 7 ${C}/1 query[A] a.example.test from ${C}`,
    'dnsmasq[12]: started, version 2.91 cachesize 1000',
    `dnsmasq[12]: 7 ${C}/1 query[A] b.example.test from ${C}`,
    `xdnsmasq[1]: 8 ${C}/1 query[A] c.example.test from ${C}`,
    'dnsmasq[1]: x overflow: 3 log entries lost',
    'dnsmasq[1]: overflow: 3 log entries lost extra',
    'dnsmasq[1]: restarted, version 2.91'
  ]));
  const keys = Object.fromEntries(ql.rows(st).map((r) => [r.domain, r.key]));
  assert.deepEqual(keys, { 'a.example.test': `0:12:7:${C}/1`, 'b.example.test': `1:12:7:${C}/1` });
  assert.equal(ql.stats(st).dnsmasq_lost, 0);
  assert.equal(ql.rows(st).find((r) => r.domain === 'a.example.test').decision, 'no-answer');
});

test('the next request is sized by the new entries of the last reply, not the overlap', () => {
  const st = ql.create();
  const filler = (n, id) => reply(Array.from({ length: n }, () => 'kernel: x'), { id });
  ql.ingest(st, filler(10, 1));
  ql.ingest(st, filler(10, 5));                                    // ids 5..14: 4 new
  assert.equal(ql.nextRequest(st).lines, Math.ceil(1.2 * 4) + 16);
});

test('create() clamps its options', () => {
  for (const bad of [0, -5, 'x', null]) {
    const st = ql.create({ max_rows: bad, pending_ttl_s: bad });
    assert.deepEqual([st.maxRows, st.ttlMs], [500, 10_000], String(bad));
  }
  assert.equal(ql.create({ max_rows: 9000 }).maxRows, 500);
  assert.equal(ql.create({ max_rows: 7.9 }).maxRows, 7);
  assert.deepEqual(ql.create({ local_domains: ['LAN', 7] }).localDomains, ['lan']);
});
