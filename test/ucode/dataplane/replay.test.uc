// Replays real dnsmasq 2.93 logs captured on an OpenWrt 25.12.6 guest
// (test/fixtures/dnsmasq/capture.sh) through the daemon's pipeline:
// framer -> parse_line -> stats.ingest. Covers T01-T04 on real input.
'use strict';

push(REQUIRE_SEARCH_PATH, sourcepath(0, true) + '/../../../root/usr/share/ucode/*.uc');

const fs = require('fs');
const parse_line = require('abfm.logparse').parse_line;
const framer = require('abfm.logparse').framer;
const stats = require('abfm.stats');

let t = require('testlib');
const FIXTURES = sourcepath(0, true) + '/../../fixtures/dnsmasq';
const CTX = { exclude_router: true, local_domains: [ 'lan' ] };

function replay(file, chunk, opts) {
	let data = fs.readfile(`${FIXTURES}/${file}`);
	t.ok(data, `fixture ${file}`);
	let st = stats.create(opts ?? { record_clients: true }, 1000);
	let f = framer(() => stats.input_overflow(st, 1000));
	for (let off = 0; off < length(data); off += chunk)
		for (let line in f.feed(substr(data, off, chunk))) {
			let e = parse_line(line, st.counters);
			if (e)
				stats.ingest(st, e, CTX, 1000);
		}
	return st;
}

function rows(st) {
	let out = {};
	for (let r in stats.domains(st, { limit: 100 }, 1000).items)
		out[r.domain] = r;
	return out;
}

function summary(r) {
	return [ r.decision, r.source, r.count, r.blocked, r.allowed, r.qtypes ];
}

for (let chunk in [ 4096, 7 ]) {
	t.test(`servers.log (chunk ${chunk}): counters`, () => {
		let st = replay('servers.log', chunk);
		t.eq(stats.snapshot_counters(st), {
			queries: 19, blocked: 7, allowed: 4, other: 7, expired: 0, pending: 1,
			dropped: { input_overflow: 0, pending_evicted: 0, dnsmasq_reported: 0 },
			rejected_lines: 4, orphan_lines: 0
		});
		t.eq(stats.sweep(st, 1010), null, 'err.example.test (no answer) expires');
		t.eq([ st.counters.expired, st.counters.pending ], [ 1, 0 ]);
	});
}

t.test('servers.log: rows and sources', () => {
	let r = rows(replay('servers.log', 4096));
	t.eq(summary(r['ads.example.test']), [ 'blocked', 'config', 3, 3, 0, [ 'A', 'AAAA', 'HTTPS' ] ]);
	t.eq(summary(r['sub.ads.example.test']), [ 'blocked', 'config', 1, 1, 0, [ 'A' ] ]);
	t.eq(summary(r['mixed.example.test']), [ 'blocked', 'config', 1, 1, 0, [ 'A' ] ], 'dnsmasq lower-cased MiXeD');
	t.eq(summary(r['www.up.example.test']), [ 'other', 'error', 4, 0, 3, [ 'A', 'AAAA', 'HTTPS' ] ],
		'reply, cached, reply; last outcome HTTPS REFUSED');
	t.eq(summary(r['nx.example.test']), [ 'allowed', 'upstream', 1, 0, 1, [ 'A' ] ], 'upstream NXDOMAIN is not a block');
	t.eq(summary(r['localhost']), [ 'other', 'hosts', 1, 0, 0, [ 'A' ] ]);
	for (let n in [ 'openwrt.lan', 'wpad', 'printer.local', '1.0.0.10.in-addr.arpa',
	                '1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.d.f.ip6.arpa' ])
		t.eq(r[n]?.source, 'local', n);
	t.ok(!r['err.example.test'], 'unanswered query has no row');
	t.eq(r['ads.example.test'].client, '10.0.2.2');
	for (let n in keys(r))
		t.ok(index(n, ' ') < 0 && index(n, '<') < 0, `no spoofed row: ${n}`);
});

t.test('servers.log: top_blocked and top_allowed', () => {
	let st = replay('servers.log', 4096);
	let top = stats.domains(st, { view: 'top_blocked' }, 1000).items;
	t.eq(top[0], { domain: 'ads.example.test', count: 3, error: 0 });
	t.eq(length(top), 5);
	t.eq(stats.domains(st, { view: 'top_allowed' }, 1000).items,
		[ { domain: 'www.up.example.test', count: 3, error: 0 }, { domain: 'nx.example.test', count: 1, error: 0 } ]);
});

t.test('servers.log with exclude_router=0 counts the router queries', () => {
	let data = fs.readfile(`${FIXTURES}/servers.log`);
	let st = stats.create({}, 1000);
	let ctx = { exclude_router: false, local_domains: [ 'lan' ] };
	for (let line in split(data, '\n')) {
		let e = parse_line(line, st.counters);
		if (e)
			stats.ingest(st, e, ctx, 1000);
	}
	t.eq([ st.counters.queries, st.counters.blocked, st.counters.allowed ], [ 23, 9, 6 ]);
});

t.test('addnhosts.log: counters and sources', () => {
	let st = replay('addnhosts.log', 4096);
	t.eq(stats.snapshot_counters(st), {
		queries: 19, blocked: 7, allowed: 4, other: 7, expired: 0, pending: 1,
		dropped: { input_overflow: 0, pending_evicted: 0, dnsmasq_reported: 0 },
		rejected_lines: 4, orphan_lines: 0
	});
	let r = rows(st);
	t.eq(summary(r['ads.example.test']), [ 'blocked', 'config', 3, 3, 0, [ 'A', 'AAAA', 'HTTPS' ] ],
		'A from the addnhosts path, then NODATA-IPv6 / NODATA from config');
	t.eq(summary(r['telemetry.example.test']), [ 'blocked', 'addnhosts', 1, 1, 0, [ 'A' ] ]);
	t.eq(summary(r['metrics.example.test']), [ 'blocked', 'addnhosts', 1, 1, 0, [ 'A' ] ]);
});

t.test('restart-heartbeat.log: informational lines and router heartbeat leave no trace', () => {
	let st = replay('restart-heartbeat.log', 4096);
	t.eq(stats.snapshot_counters(st), {
		queries: 0, blocked: 0, allowed: 0, other: 0, expired: 0, pending: 0,
		dropped: { input_overflow: 0, pending_evicted: 0, dnsmasq_reported: 0 },
		rejected_lines: 0, orphan_lines: 0
	});
});

t.test('restart-heartbeat.log with exclude_router=0: duplicate replies are ignored', () => {
	let data = fs.readfile(`${FIXTURES}/restart-heartbeat.log`);
	let st = stats.create({}, 1000);
	for (let line in split(data, '\n')) {
		let e = parse_line(line, st.counters);
		if (e)
			stats.ingest(st, e, { exclude_router: false }, 1000);
	}
	let c = st.counters;
	t.eq([ c.queries, c.allowed, c.pending, c.orphan_lines, c.rejected_lines ], [ 4, 2, 2, 0, 0 ]);
});

t.done();
