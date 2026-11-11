// SPDX-License-Identifier: Apache-2.0
// Property and fuzz tests of the real querylog.js (docs/CONTRACT.md §8.1-§8.3):
// seeded random `log read` replies, valid and hostile, checked against the
// module's invariants. A failure prints the seed; rerun one case with
// ABFM_FUZZ_SEED=<seed> (and ABFM_FUZZ_RUNS to change the number of cases).
import assert from 'node:assert/strict';
import test from 'node:test';
import { ql } from './querylog-load.mjs';

const RUNS = Number(process.env.ABFM_FUZZ_RUNS || 300);
const SEED = process.env.ABFM_FUZZ_SEED ? Number(process.env.ABFM_FUZZ_SEED) : null;

// mulberry32: small, fast, deterministic.
function rng(seed) {
  let a = seed >>> 0;
  const next = () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  const int = (n) => Math.floor(next() * n);
  return { next, int, pick: (list) => list[int(list.length)], chance: (p) => next() < p };
}

const NAMES = ['ads.example.test', 'www.up.example.test', 'cdn.example.org', 'printer.lan', 'wpad', 'x.internal',
  '5.113.0.203.in-addr.arpa', 'a-b_c.example.net', '__proto__', 'constructor', 'x.local', '2001:db8::1'];
const CLIENTS = ['192.0.2.10', '192.0.2.11', '198.51.100.7', '2001:db8::10', '127.0.0.1', '::1', '__proto__', 'constructor'];
const ANSWERS = ['192.0.2.1', '2001:db8::1', 'NXDOMAIN', 'NODATA', 'NODATA-IPv6', '0.0.0.0', '::', '<CNAME>',
  'SERVFAIL', 'REFUSED', '15', 'duplicate', '<img/src=x/onerror=alert(1)>', '"><svg/onload=x>', "'&amp;'"];
const SOURCES = ['reply', 'cached', 'cached-stale', 'config', '/var/run/adblock-fast/dnsmasq.addnhosts',
  '/tmp/hosts/dhcp.cfg01411c', 'DHCP', 'auth', 'forwarded', '__proto__', 'constructor'];
const QTYPES = ['A', 'AAAA', 'PTR', 'HTTPS', 'TXT', 'type=65'];
const HOSTILE = ['\u0000', '\n', '\t', ' ', '\u2028', '\u202e', '<', '>', '"', "'", '&', 'é', 'İ', '\uffff'];

function mutate(r, s) {
  switch (r.int(8)) {
  case 0: return s.toUpperCase();
  case 1: { const i = r.int(s.length + 1); return s.slice(0, i) + r.pick(HOSTILE) + s.slice(i); }
  case 2: return s.replace(/\d+/, r.pick(['18446744073709551616', '0007', '-1', '']));
  case 3: return s + ' ' + r.pick(['is 0.0.0.0', 'x', '(EDE: blocked)', '(a) (b)']);
  case 4: return s.slice(0, r.int(s.length));
  case 5: return s + 'x'.repeat(1024 * (1 + r.int(64)));
  default: return s;
  }
}

// A plausible dnsmasq transaction: query line and 0..3 answer lines.
function transaction(r, serial) {
  const client = r.pick(CLIENTS), port = 1 + r.int(65535), name = r.pick(NAMES);
  const head = `dnsmasq[${r.chance(0.9) ? 1 : 2 + r.int(3)}]: ${r.chance(0.2) ? r.pick(['TCP ', 'UDP ']) : ''}${serial} ${client}/${port} `;
  const lines = [`${head}query[${r.pick(QTYPES)}] ${name} from ${client}`];
  let cur = name;
  for (let k = r.int(4); k > 0; k--) {
    const src = r.pick(SOURCES);
    if (src === 'forwarded') { lines.push(`${head}forwarded ${cur} to 192.0.2.53`); continue; }
    const ans = r.pick(ANSWERS);
    lines.push(`${head}${src} ${cur} is ${ans}${r.chance(0.1) ? ' (EDE: network error)' : ''}`);
    if (ans === '<CNAME>') cur = r.pick(NAMES);
  }
  return lines;
}

// A stream of syslog messages: transactions interleaved, plus restarts, LOST and noise.
function messages(r, count) {
  const open = [];
  const out = [];
  let serial = 1 + r.int(1000);
  while (out.length < count) {
    const roll = r.next();
    if (roll < 0.45 || open.length === 0) open.push(transaction(r, serial++));
    else if (roll < 0.9) {
      const t = open[r.int(open.length)];
      out.push(t.shift());
      if (!t.length) open.splice(open.indexOf(t), 1);
    } else if (roll < 0.92) out.push('dnsmasq[1]: started, version 2.91 cachesize 1000');
    else if (roll < 0.94) out.push(`dnsmasq[1]: overflow: ${r.int(50)} log entries lost`);
    else if (roll < 0.97) out.push(r.pick(['netifd: up', 'dnsmasq-dhcp[1]: DHCPACK(br-lan) 192.0.2.10', 'kernel: x']));
    else out.push(`dnsmasq[1]: ${r.int(9999)} junk line ${r.pick(HOSTILE)}`);
  }
  return out;
}

const entry = (msg, id, timeMs) => ({ msg, id, priority: 30, source: 1, time: timeMs });

// The log as logd holds it: consecutive ids, non-decreasing time in ms.
function cleanLog(r, count) {
  let t = 1794354461000 + r.int(1e6);
  return messages(r, count).map((m, i) => entry(m, 1000 + i, (t += r.int(1500))));
}

// Arbitrary hostile entries/replies.
function hostileReply(r) {
  const k = r.int(10);
  if (k === 0) return r.pick([null, undefined, {}, { log: {} }, { log: 'x' }, { log: null }, 7, 'log']);
  const log = [];
  const n = r.int(60);
  let id = r.int(5000) - 100;
  for (let i = 0; i < n; i++) {
    const msgs = messages(r, 1);
    let msg = r.chance(0.5) ? mutate(r, msgs[0]) : msgs[0];
    if (r.chance(0.05)) msg = r.pick([null, 7, {}, ['dnsmasq[1]: x'], undefined]);
    id = r.pick([id + 1, id + 1, id + 1, id, id - 3, id + 500, -1, NaN, String(id + 1), '0x10']);
    const time = r.pick([1794354461000 + i * 100, NaN, -5, '12', null, 1794354461000 - i * 100]);
    log.push(r.chance(0.02) ? r.pick([null, 5, 'x']) : { msg, id, priority: 30, source: 1, time });
  }
  return { log };
}

function stringsOf(row) {
  return [row.domain, row.qtype, row.client, ...row.answers];
}

function checkInvariants(st, ingested, prev, ctx) {
  const rows = ql.rows(st, { show_router: true });
  const shown = ql.rows(st);
  const s = ql.stats(st, { show_router: true });
  assert.ok(rows.length <= 500 && st.entries.size <= 500 && st.pending.size <= 500, ctx);
  assert.equal(s.kept, rows.length, ctx);
  assert.equal(s.blocked + s.allowed + s.other + s.no_answer + s.pending, s.kept, ctx);
  assert.equal(ql.stats(st).kept, shown.length, ctx);
  assert.equal(new Set(rows.map((x) => x.key)).size, rows.length, ctx);
  const n = ql.nextRequest(st).lines;
  assert.ok(Number.isInteger(n) && n >= 16 && n <= 900, `${ctx}: lines ${n}`);
  for (const row of rows) {
    assert.ok(row.answers.length <= ql.ANSWERS_MAX, ctx);
    assert.match(row.domain, /^[a-z0-9_.:-]+$/, ctx);
    assert.ok(['blocked', 'allowed', 'other', 'no-answer', 'pending'].includes(row.decision), ctx);
    for (const str of stringsOf(row)) {
      assert.equal(typeof str, 'string', ctx);
      assert.ok(ingested.some((m) => m.includes(str)), `${ctx}: "${str}" is not raw log text`);
    }
  }
  if (prev) {
    assert.ok(s.missed_total >= prev.missed_total, ctx);
    assert.ok(s.paused_total >= prev.paused_total, ctx);
    for (const k of ['queries', 'blocked', 'allowed']) assert.ok(s.since_open[k] >= prev.since_open[k], ctx);
  }
  return s;
}

function seeds(base) {
  return SEED != null ? [SEED] : Array.from({ length: RUNS }, (_, i) => base + i);
}

test('fuzz: hostile replies never throw and keep every invariant', () => {
  for (const seed of seeds(1)) {
    const r = rng(seed);
    const st = ql.create({ max_rows: 1 + r.int(500), hide_router: r.chance(0.5), local_domains: ['lan', 7, null] });
    const ingested = [];
    let prev = null;
    for (let p = 0; p < 1 + r.int(12); p++) {
      const rep = hostileReply(r);
      if (rep && Array.isArray(rep.log)) for (const e of rep.log) if (e && e.msg != null) ingested.push(String(e.msg));
      if (r.chance(0.1)) ql.resume(st, r.pick([0, 1, 30, -2, NaN, 'x', 1e9]));
      let res;
      assert.doesNotThrow(() => { res = ql.ingest(st, rep); }, `seed ${seed}`);
      assert.ok(res && typeof res === 'object', `seed ${seed}`);
      prev = checkInvariants(st, ingested, prev, `seed ${seed} poll ${p}`);
    }
  }
});

test('property: polling with random overlapping windows yields the rows of one ingest', () => {
  for (const seed of seeds(10_001)) {
    const r = rng(seed);
    const log = cleanLog(r, 1 + r.int(700));
    const opts = { max_rows: 500, hide_router: true, local_domains: ['lan'] };
    const once = ql.create(opts);
    ql.ingest(once, { log });
    const st = ql.create(opts);
    const msgs = log.map((e) => e.msg);
    let head = 0, prev = null;
    while (head < log.length) {
      // logd returns the newest N entries up to the current head; the page asks per nextRequest
      head = Math.min(log.length, head + 1 + r.int(120));
      const want = ql.nextRequest(st).lines;
      let res = ql.ingest(st, { log: log.slice(Math.max(0, head - want), head) });
      if (res.refetch) res = ql.ingest(st, { log: log.slice(Math.max(0, head - res.refetch.lines), head) });
      assert.equal(res.missed, 0, `seed ${seed}: no entry is lost when every window overlaps`);
      prev = checkInvariants(st, msgs, prev, `seed ${seed}`);
    }
    assert.deepEqual(ql.rows(st, { show_router: true }), ql.rows(once, { show_router: true }), `seed ${seed}`);
    assert.deepEqual(ql.stats(st, { show_router: true }), ql.stats(once, { show_router: true }), `seed ${seed}`);
  }
});

test('property: a window that skips entries reports exactly the skipped ids as missed', () => {
  for (const seed of seeds(20_001)) {
    const r = rng(seed);
    const log = cleanLog(r, 50 + r.int(900)).map((e) => ({ ...e, msg: 'kernel: filler' }));
    const st = ql.create();
    let head = 1 + r.int(20), skipped = 0;
    ql.ingest(st, { log: log.slice(0, head) });
    let cursor = head - 1;
    while (head < log.length) {
      const next = Math.min(log.length, head + 1 + r.int(400));
      const want = ql.nextRequest(st).lines;
      let from = Math.max(0, next - want);
      const res = ql.ingest(st, { log: log.slice(from, next) });
      if (res.refetch) {
        from = Math.max(0, next - res.refetch.lines);
        ql.ingest(st, { log: log.slice(from, next) });
      }
      if (from > cursor + 1) skipped += from - cursor - 1;
      cursor = next - 1;
      head = next;
    }
    assert.equal(ql.stats(st).missed_total, skipped, `seed ${seed}`);
  }
});

test('performance: 900 hostile lines ingest in bounded time (no catastrophic backtracking)', () => {
  const r = rng(424242);
  const nasty = [];
  for (let i = 0; i < 900; i++) {
    const base = `dnsmasq[1]: ${i} 192.0.2.10/1 reply ${'a.'.repeat(400)}example.test is `;
    nasty.push(entry(r.chance(0.5) ? base + ' ('.repeat(300) + ')' : base + `${'1 '.repeat(300)}x`, i + 1, 1794354461000));
  }
  nasty.push(entry(`dnsmasq[1]: ${'9'.repeat(5000)} ${'/'.repeat(5000)}`, 901, 1794354461000));
  const st = ql.create();
  const t0 = process.hrtime.bigint();
  ql.ingest(st, { log: nasty });
  ql.rows(st);
  ql.stats(st);
  const ms = Number(process.hrtime.bigint() - t0) / 1e6;
  assert.ok(ms < 250, `took ${ms.toFixed(1)} ms`);
});
