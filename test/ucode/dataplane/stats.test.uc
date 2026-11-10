// T04/T05 (docs/CONTRACT.md §4.5-4.6): bounded structures, counters and the
// `domains` read of the real abfm.stats module.
'use strict';

push(REQUIRE_SEARCH_PATH, sourcepath(0, true) + '/../../../root/usr/share/ucode/*.uc');

const stats = require('abfm.stats');
const parse_line = require('abfm.logparse').parse_line;

let t = require('testlib');
const P = 'Tue Nov 10 01:09:19 2026 daemon.info dnsmasq[7]: ';
const CTX = { exclude_router: true, local_domains: [ 'lan' ] };

function feed(st, body, now) {
	let e = parse_line(P + body, st.counters);
	return e ? stats.ingest(st, e, CTX, now) : 'unparsed';
}

// One complete lookup: query plus terminal line.
function lookup(st, serial, name, qtype, terminal, now, client) {
	client ??= '10.0.0.2';
	feed(st, `${serial} ${client}/${1000 + serial} query[${qtype}] ${name} from ${client}`, now);
	return feed(st, `${serial} ${client}/${1000 + serial} ${terminal}`, now);
}

function invariant(st) {
	let c = st.counters;
	return c.queries == c.blocked + c.allowed + c.other + c.expired + c.pending + c.dropped.pending_evicted;
}

t.test('limits clamp to the §3 ranges and fall back to defaults', () => {
	t.eq(stats.limits({}), { recent_size: 500, top_size: 256, pending_size: 512, pending_ttl: 10 });
	t.eq(stats.limits({ recent_size: 10, top_size: 5000, pending_size: '100', pending_ttl: 'x' }),
		{ recent_size: 50, top_size: 1024, pending_size: 100, pending_ttl: 10 });
});

t.test('T04: query starts a pending entry; the first terminal line decides', () => {
	let st = stats.create({}, 100);
	t.eq(feed(st, '44 10.0.0.2/5 query[A] www.example.org from 10.0.0.2', 100), 'pending');
	t.eq(st.counters.pending, 1);
	t.eq(feed(st, '44 10.0.0.2/5 forwarded www.example.org to 1.1.1.1', 100), null);
	t.eq(feed(st, '44 10.0.0.2/5 reply www.example.org is <CNAME>', 101), 'decided');
	t.eq(feed(st, '44 10.0.0.2/5 reply cdn.example.org is 93.184.216.34', 101), 'ignored', 'CNAME follow-up');
	t.eq(feed(st, '44 10.0.0.2/5 reply cdn.example.org is 93.184.216.35', 101), 'ignored');
	let c = st.counters;
	t.eq([ c.queries, c.allowed, c.pending, c.orphan_lines ], [ 1, 1, 0, 0 ]);
	let row = stats.domains(st, {}, 101).items[0];
	t.eq([ row.domain, row.decision, row.source ], [ 'www.example.org', 'allowed', 'upstream' ], 'row uses the query name');
});

t.test('T04: lines with an unknown key are orphans; duplicate replies are ignored', () => {
	let st = stats.create({}, 100);
	t.eq(feed(st, '9 10.0.0.2/5 reply x.example is 1.2.3.4', 100), 'orphan');
	t.eq(feed(st, '9 10.0.0.2/5 reply query is duplicate', 100), null);
	t.eq(st.counters.orphan_lines, 1);
});

t.test('T04: the key includes client/port (jailed instances all log as dnsmasq[1])', () => {
	let st = stats.create({}, 100);
	feed(st, '1 10.0.0.2/5 query[A] a.example from 10.0.0.2', 100);
	feed(st, '1 10.0.0.3/6 query[A] b.example from 10.0.0.3', 100);
	feed(st, '1 10.0.0.3/6 config b.example is NXDOMAIN', 100);
	feed(st, '1 10.0.0.2/5 cached a.example is 1.2.3.4', 100);
	let d = {};
	for (let r in stats.domains(st, {}, 100).items)
		d[r.domain] = r.decision;
	t.eq(d, { 'a.example': 'allowed', 'b.example': 'blocked' });
});

t.test('T04: router queries are not counted with exclude_router', () => {
	let st = stats.create({}, 100);
	lookup(st, 1, 'a.example', 'A', 'cached a.example is 1.2.3.4', 100, '127.0.0.1');
	lookup(st, 2, 'a.example', 'A', 'cached a.example is 1.2.3.4', 100, '::1');
	t.eq([ st.counters.queries, st.counters.orphan_lines ], [ 0, 0 ]);
});

t.test('T04: pending TTL expiry counts expired and reports the next deadline', () => {
	let st = stats.create({ pending_ttl: 5 }, 100);
	feed(st, '1 10.0.0.2/5 query[A] a.example from 10.0.0.2', 100);
	feed(st, '2 10.0.0.2/6 query[A] b.example from 10.0.0.2', 103);
	t.eq(stats.sweep(st, 104), 1, 'oldest expires at 105');
	t.eq(stats.sweep(st, 105), 3, 'a expired; b expires at 108');
	t.eq([ st.counters.expired, st.counters.pending ], [ 1, 1 ]);
	t.eq(stats.sweep(st, 200), null, 'nothing pending');
	t.eq([ st.counters.expired, st.counters.pending ], [ 2, 0 ]);
	t.eq(feed(st, '1 10.0.0.2/5 reply a.example is 1.2.3.4', 200), 'orphan', 'late answer after expiry');
	t.ok(invariant(st));
});

t.test('T04: a full pending map evicts its oldest entry', () => {
	let st = stats.create({ pending_size: 64 }, 100);
	for (let i = 1; i <= 70; i++)
		feed(st, `${i} 10.0.0.2/${i} query[A] h${i}.example from 10.0.0.2`, 100 + i);
	let c = st.counters;
	t.eq([ c.queries, c.pending, c.dropped.pending_evicted ], [ 70, 64, 6 ]);
	t.eq(feed(st, '1 10.0.0.2/1 reply h1.example is 1.2.3.4', 200), 'orphan', 'h1 was evicted');
	t.eq(feed(st, '7 10.0.0.2/7 reply h7.example is 1.2.3.4', 200), 'decided', 'h7 survived');
	t.eq(stats.reasons(st, 200), [ 'pending-overflow' ]);
	t.eq(stats.reasons(st, 170 + 60), [], 'reason clears 60 s after the last eviction');
	t.ok(invariant(st));
});

t.test('T04: counter invariant over a mixed stream', () => {
	let st = stats.create({ pending_size: 64, pending_ttl: 2 }, 0);
	let n = 0;
	for (let i = 1; i <= 400; i++) {
		let name = `d${i % 37}.example`;
		feed(st, `${i} 10.0.0.${i % 5}/${i} query[${[ 'A', 'AAAA', 'HTTPS' ][i % 3]}] ${name} from 10.0.0.${i % 5}`, i / 10);
		switch (i % 6) {
		case 0: feed(st, `${i} 10.0.0.${i % 5}/${i} config ${name} is NXDOMAIN`, i / 10); break;
		case 1: feed(st, `${i} 10.0.0.${i % 5}/${i} reply ${name} is 1.2.3.4`, i / 10); break;
		case 2: feed(st, `${i} 10.0.0.${i % 5}/${i} cached ${name} is 1.2.3.4`, i / 10); break;
		case 3: feed(st, `${i} 10.0.0.${i % 5}/${i} reply ${name} is SERVFAIL`, i / 10); break;
		}
		if (i % 50 == 0)
			stats.sweep(st, i / 10);
		t.ok(invariant(st), `invariant after line ${i}`);
	}
	let c = st.counters;
	t.ok(c.expired > 0 && c.blocked > 0 && c.allowed > 0 && c.other > 0, sprintf('%J', c));
});

t.test('T04: recent LRU deduplicates A/AAAA/HTTPS by query name', () => {
	let st = stats.create({ record_clients: true }, 100);
	lookup(st, 1, 'ads.example.com', 'A', 'config ads.example.com is NXDOMAIN', 100);
	lookup(st, 2, 'ads.example.com', 'AAAA', 'config ads.example.com is NXDOMAIN', 101);
	lookup(st, 3, 'ads.example.com', 'HTTPS', 'config ads.example.com is NXDOMAIN', 102);
	lookup(st, 4, 'ads.example.com', 'A', 'reply ads.example.com is 1.2.3.4', 103, '10.0.0.9');
	let r = stats.domains(st, {}, 104);
	t.eq(r.total, 1);
	t.eq(r.items[0], {
		domain: 'ads.example.com', decision: 'allowed', source: 'upstream', count: 4, blocked: 3, allowed: 1,
		first_seen: 100, last_seen: 103, qtypes: [ 'A', 'AAAA', 'HTTPS' ], client: '10.0.0.9'
	});
});

t.test('T04: per-row qtypes keep at most 8 distinct types', () => {
	let st = stats.create({}, 100);
	let i = 0;
	for (let q in [ 'A', 'AAAA', 'HTTPS', 'MX', 'TXT', 'SRV', 'PTR', 'NS', 'SOA', 'CAA', 'A' ])
		lookup(st, ++i, 'x.example', q, 'reply x.example is NXDOMAIN', 100);
	t.eq(stats.domains(st, {}, 100).items[0].qtypes, [ 'A', 'AAAA', 'HTTPS', 'MX', 'TXT', 'SRV', 'PTR', 'NS' ]);
});

t.test('T04: recent LRU evicts the least recently seen domain', () => {
	let st = stats.create({ recent_size: 50 }, 0);
	for (let i = 1; i <= 50; i++)
		lookup(st, i, `d${i}.example`, 'A', `cached d${i}.example is 1.2.3.4`, i);
	lookup(st, 51, 'd1.example', 'A', 'cached d1.example is 1.2.3.4', 51);   // d1 becomes newest
	lookup(st, 52, 'new.example', 'A', 'cached new.example is 1.2.3.4', 52); // evicts d2
	let r = stats.domains(st, { limit: 100 }, 53);
	let names = map(r.items, (x) => x.domain);
	t.eq(r.total, 50);
	t.ok(index(names, 'd2.example') < 0, 'd2 evicted');
	t.ok(index(names, 'd1.example') >= 0, 'd1 kept');
	t.eq(slice(names, 0, 2), [ 'new.example', 'd1.example' ]);
	t.eq(st.counters.dropped, { input_overflow: 0, pending_evicted: 0, dnsmasq_reported: 0 }, 'LRU eviction is not a drop');
});

t.test('T04: Space-Saving replaces the minimum with count=min+1, error=min', () => {
	let ss = { size: 3, n: 0, min: 0, items: {}, buckets: {} };
	for (let k in [ 'a', 'a', 'a', 'b', 'b', 'c' ])
		stats.ss_touch(ss, k);
	t.eq(stats.ss_touch(ss, 'd'), { count: 2, error: 1 }, 'c (count 1) replaced');
	t.ok(!ss.items.c);
	t.eq(ss.min, 2);
	t.eq(stats.ss_touch(ss, 'e'), { count: 3, error: 2 }, 'a min-count (2) entry replaced');
	t.ok(!ss.items.b, 'b was the oldest entry at the minimum');
	t.eq(length(keys(ss.items)), 3);
	t.eq(ss.items.a, { count: 3, error: 0 });
	t.eq(ss.items.d, { count: 2, error: 1 });
	t.eq(ss.min, 2);
});

t.test('T04/T05: top views through the daemon structures', () => {
	let st = stats.create({ top_size: 32 }, 0);
	let s = 0;
	for (let i = 0; i < 5; i++)
		lookup(st, ++s, 'big.example', 'A', 'config big.example is NXDOMAIN', 1);
	for (let i = 0; i < 2; i++)
		lookup(st, ++s, 'mid.example', 'A', 'config mid.example is NXDOMAIN', 1);
	lookup(st, ++s, 'alpha.example', 'A', 'config alpha.example is NXDOMAIN', 1);
	lookup(st, ++s, 'beta.example', 'A', 'config beta.example is NXDOMAIN', 1);
	lookup(st, ++s, 'ok.example', 'A', 'cached ok.example is 1.2.3.4', 1);
	let r = stats.domains(st, { view: 'top_blocked' }, 2);
	t.eq(r.items, [
		{ domain: 'big.example', count: 5, error: 0 }, { domain: 'mid.example', count: 2, error: 0 },
		{ domain: 'alpha.example', count: 1, error: 0 }, { domain: 'beta.example', count: 1, error: 0 }
	]);
	t.eq(stats.domains(st, { view: 'top_allowed' }, 2).items, [ { domain: 'ok.example', count: 1, error: 0 } ]);
	t.eq(stats.domains(st, { view: 'top_blocked', q: 'ALP' }, 2).total, 1, 'q is lower-cased first');
	t.eq(stats.domains(st, { view: 'top_blocked', decision: 'allowed' }, 2).total, 4, 'decision ignored outside recent');
});

t.test('T04: Space-Saving under churn keeps exactly top_size entries and the true heavy hitter', () => {
	let st = stats.create({ top_size: 32 }, 0);
	let s = 0;
	for (let i = 0; i < 2000; i++) {
		lookup(st, ++s, `u${i}.example`, 'A', `config u${i}.example is NXDOMAIN`, 1);
		if (i % 4 == 0)
			lookup(st, ++s, 'heavy.example', 'A', 'config heavy.example is NXDOMAIN', 1);
	}
	let r = stats.domains(st, { view: 'top_blocked', limit: 100 }, 2);
	t.eq(r.total, 32);
	t.eq(r.items[0].domain, 'heavy.example');
	t.ok(r.items[0].count >= 500 && r.items[0].count - r.items[0].error <= 500, sprintf('%J', r.items[0]));
});

t.test('block_pct', () => {
	t.eq(stats.block_pct({ blocked: 0, allowed: 0 }), null);
	t.eq(stats.block_pct({ blocked: 180, allowed: 990 }), 15.4);
	t.eq(stats.block_pct({ blocked: 1, allowed: 2 }), 33.3);
	t.eq(stats.block_pct({ blocked: 5, allowed: 0 }), 100.0);
	t.eq(stats.block_pct({ blocked: 0, allowed: 5 }), 0.0);
});

t.test('reasons: input-overflow and dnsmasq-log-overflow within 60 s', () => {
	let st = stats.create({}, 0);
	stats.input_overflow(st, 10);
	let before = st.counters.dropped.dnsmasq_reported;
	parse_line(P + 'overflow: 4 log entries lost', st.counters);
	stats.note_lost(st, before, 20);
	t.eq(stats.reasons(st, 30), [ 'input-overflow', 'dnsmasq-log-overflow' ]);
	t.eq(stats.reasons(st, 75), [ 'dnsmasq-log-overflow' ]);
	t.eq(stats.reasons(st, 80), []);
	t.eq(st.counters.dropped, { input_overflow: 1, pending_evicted: 0, dnsmasq_reported: 4 });
});

function sample(record_clients) {
	let st = stats.create({ record_clients }, 0);
	let s = 0;
	lookup(st, ++s, 'b-blocked.example', 'A', 'config b-blocked.example is NXDOMAIN', 10);
	lookup(st, ++s, 'a-blocked.example', 'A', 'config a-blocked.example is NXDOMAIN', 10);
	lookup(st, ++s, 'allowed.example', 'A', 'cached allowed.example is 1.2.3.4', 12);
	lookup(st, ++s, 'other.lan', 'A', 'config other.lan is NXDOMAIN', 11);
	lookup(st, ++s, 'under_score.example', 'TXT', 'reply under_score.example is NXDOMAIN', 9);
	return st;
}

t.test('T05: recent view sort order (last_seen desc, then domain asc) and response shape', () => {
	let r = stats.domains(sample(false), {}, 20);
	t.eq(map(r.items, (x) => x.domain),
		[ 'allowed.example', 'other.lan', 'a-blocked.example', 'b-blocked.example', 'under_score.example' ]);
	t.eq([ r.api, r.ok, r.view, r.total, r.offset, r.now, r.stats_since ], [ 1, true, 'recent', 5, 0, 20, 0 ]);
	t.ok(!exists(r.items[0], 'client'), 'no client without record_clients');
	t.eq(r.items[1].source, 'local');
});

t.test('T05: client only with record_clients=1', () => {
	t.eq(stats.domains(sample(true), {}, 20).items[0].client, '10.0.0.2');
});

t.test('T05: decision filter and q substring', () => {
	let st = sample(false);
	t.eq(map(stats.domains(st, { decision: 'blocked' }, 20).items, (x) => x.domain), [ 'a-blocked.example', 'b-blocked.example' ]);
	t.eq(stats.domains(st, { decision: 'other' }, 20).total, 1);
	t.eq(stats.domains(st, { decision: 'allowed' }, 20).total, 2);
	let r = stats.domains(st, { q: 'Blocked' }, 20);
	t.eq([ r.total, r.items[0].domain ], [ 2, 'a-blocked.example' ]);
	t.eq(stats.domains(st, { q: 'under_' }, 20).total, 1);
	t.eq(stats.domains(st, { q: '' }, 20).total, 5, 'empty q means no filter');
});

t.test('T05: paging and limit clamp', () => {
	let st = stats.create({}, 0);
	for (let i = 1; i <= 120; i++)
		lookup(st, i, sprintf('d%03d.example', i), 'A', sprintf('cached d%03d.example is 1.2.3.4', i), 1000 - i);
	t.eq(length(stats.domains(st, {}, 0).items), 50, 'default limit 50');
	t.eq(length(stats.domains(st, { limit: 500 }, 0).items), 100, 'limit clamps to 100');
	t.eq(length(stats.domains(st, { limit: 0 }, 0).items), 1, 'limit clamps to 1');
	let r = stats.domains(st, { offset: 110, limit: 20 }, 0);
	t.eq([ r.total, r.offset, length(r.items), r.items[0].domain ], [ 120, 110, 10, 'd111.example' ]);
	t.eq(length(stats.domains(st, { offset: 500 }, 0).items), 0);
});

t.test('T05: invalid arguments give the error shape', () => {
	let st = sample(false);
	for (let req in [
		{ view: 'nope' }, { view: 5 }, { decision: 'maybe' }, { q: 'has space' }, { q: 'Ü' },
		{ q: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' }, { q: 7 },
		{ offset: -1 }, { offset: '1' }, { limit: 'x' }, { limit: 2.5 }
	]) {
		let r = stats.domains(st, req, 0);
		t.eq([ r.api, r.ok, r.error?.code ], [ 1, false, 'invalid-argument' ], sprintf('%J', req));
		t.ok(type(r.error.message) == 'string');
	}
	t.eq(stats.domains(st, { unknown: 1 }, 0).ok, true, 'unknown fields are ignored');
	t.eq(stats.domains(st, null, 0).ok, true);
});

t.test('purge resets counters, tables and stats_since', () => {
	let st = sample(false);
	feed(st, '99 10.0.0.2/1 query[A] p.example from 10.0.0.2', 30);
	stats.input_overflow(st, 30);
	stats.reset(st, 40);
	t.eq(stats.snapshot_counters(st), {
		queries: 0, blocked: 0, allowed: 0, other: 0, expired: 0, pending: 0,
		dropped: { input_overflow: 0, pending_evicted: 0, dnsmasq_reported: 0 }, rejected_lines: 0, orphan_lines: 0
	});
	t.eq([ st.stats_since, st.purged_at, st.last_event_at ], [ 40, 40, null ]);
	t.eq(stats.domains(st, {}, 41).total, 0);
	t.eq(stats.domains(st, { view: 'top_blocked' }, 41).total, 0);
	t.eq(stats.reasons(st, 41), []);
	t.eq(feed(st, '99 10.0.0.2/1 reply p.example is 1.2.3.4', 41), 'orphan', 'pending map cleared');
	t.eq(stats.create({}, 5).purged_at, null, 'a fresh state has purged_at null');
});

t.done();
