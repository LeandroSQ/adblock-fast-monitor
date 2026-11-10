// T01-T03 (docs/CONTRACT.md §4.2-4.4): grammar, rejection, classification
// and input framing of the real abfm.logparse module.
'use strict';

push(REQUIRE_SEARCH_PATH, sourcepath(0, true) + '/../../../root/usr/share/ucode/*.uc');

const parse_line = require('abfm.logparse').parse_line;
const classify = require('abfm.logparse').classify;
const is_local = require('abfm.logparse').is_local;
const framer = require('abfm.logparse').framer;
const LINE_MAX = require('abfm.logparse').LINE_MAX;

let t = require('testlib');
const P = 'Tue Nov 10 01:09:19 2026 daemon.info dnsmasq[1234]: ';

function counters() {
	return { rejected_lines: 0, dropped: { dnsmasq_reported: 0 } };
}

function ev(serial, client, port, source, name, verb, answer) {
	return { pid: 1234, serial, client, port, source, name, verb, answer };
}

// Every example line of §4.3, verbatim, plus the address form dnsmasq logs
// for reverse lookups.
const EXAMPLES = [
	[ '41 192.168.1.10/53211 query[A] ads.example.com from 192.168.1.10',
	  ev(41, '192.168.1.10', 53211, 'query[A]', 'ads.example.com', 'from', '192.168.1.10') ],
	[ '41 192.168.1.10/53211 config ads.example.com is NXDOMAIN',
	  ev(41, '192.168.1.10', 53211, 'config', 'ads.example.com', 'is', 'NXDOMAIN') ],
	[ '42 192.168.1.10/53212 query[AAAA] ads.example.com from 192.168.1.10',
	  ev(42, '192.168.1.10', 53212, 'query[AAAA]', 'ads.example.com', 'from', '192.168.1.10') ],
	[ '42 192.168.1.10/53212 /var/run/adblock-fast/dnsmasq.addnhosts ads.example.com is ::',
	  ev(42, '192.168.1.10', 53212, '/var/run/adblock-fast/dnsmasq.addnhosts', 'ads.example.com', 'is', '::') ],
	[ '43 192.168.1.10/53213 query[A] tracker.example.net from 192.168.1.10',
	  ev(43, '192.168.1.10', 53213, 'query[A]', 'tracker.example.net', 'from', '192.168.1.10') ],
	[ '43 192.168.1.10/53213 /var/run/adblock-fast/dnsmasq.addnhosts tracker.example.net is 127.0.0.1',
	  ev(43, '192.168.1.10', 53213, '/var/run/adblock-fast/dnsmasq.addnhosts', 'tracker.example.net', 'is', '127.0.0.1') ],
	[ '44 192.168.1.10/53214 query[A] www.example.org from 192.168.1.10',
	  ev(44, '192.168.1.10', 53214, 'query[A]', 'www.example.org', 'from', '192.168.1.10') ],
	[ '44 192.168.1.10/53214 forwarded www.example.org to 1.1.1.1',
	  ev(44, '192.168.1.10', 53214, 'forwarded', 'www.example.org', 'to', '1.1.1.1') ],
	[ '44 192.168.1.10/53214 reply www.example.org is <CNAME>',
	  ev(44, '192.168.1.10', 53214, 'reply', 'www.example.org', 'is', '<CNAME>') ],
	[ '44 192.168.1.10/53214 reply cdn.example.org is 93.184.216.34',
	  ev(44, '192.168.1.10', 53214, 'reply', 'cdn.example.org', 'is', '93.184.216.34') ],
	[ '45 192.168.1.10/53215 query[HTTPS] www.example.org from 192.168.1.10',
	  ev(45, '192.168.1.10', 53215, 'query[HTTPS]', 'www.example.org', 'from', '192.168.1.10') ],
	[ '45 192.168.1.10/53215 cached www.example.org is NODATA-IPv6',
	  ev(45, '192.168.1.10', 53215, 'cached', 'www.example.org', 'is', 'NODATA-IPv6') ],
	[ '46 192.168.1.10/53216 query[A] router.lan from 192.168.1.10',
	  ev(46, '192.168.1.10', 53216, 'query[A]', 'router.lan', 'from', '192.168.1.10') ],
	[ '46 192.168.1.10/53216 /tmp/hosts/dhcp.cfg01411c router.lan is 192.168.1.1',
	  ev(46, '192.168.1.10', 53216, '/tmp/hosts/dhcp.cfg01411c', 'router.lan', 'is', '192.168.1.1') ],
	[ '47 fd00::10/40000 query[type=65] x.example.com from fd00::10',
	  ev(47, 'fd00::10', 40000, 'query[type=65]', 'x.example.com', 'from', 'fd00::10') ],
	[ '47 fd00::10/40000 reply x.example.com is SERVFAIL (EDE: network error)',
	  ev(47, 'fd00::10', 40000, 'reply', 'x.example.com', 'is', 'SERVFAIL') ],
	[ '48 192.168.1.10/53218 reply query is duplicate',
	  ev(48, '192.168.1.10', 53218, 'reply', 'query', 'is', 'duplicate') ],
	[ 'TCP 49 192.168.1.10/53219 query[A] tcp.example.com from 192.168.1.10',
	  ev(49, '192.168.1.10', 53219, 'query[A]', 'tcp.example.com', 'from', '192.168.1.10') ],
	[ '50 10.0.2.2/32792 config fd00::1 is NXDOMAIN',
	  ev(50, '10.0.2.2', 32792, 'config', 'fd00::1', 'is', 'NXDOMAIN') ]
];

t.test('T01: every §4.3 example line parses to the expected fields', () => {
	for (let ex in EXAMPLES) {
		let c = counters();
		t.eq(parse_line(P + ex[0], c), ex[1], ex[0]);
		t.eq(c, counters(), `no counter change for ${ex[0]}`);
	}
});

t.test('T01: integers for pid, serial and port', () => {
	let e = parse_line(P + EXAMPLES[0][0]);
	t.eq([ type(e.pid), type(e.serial), type(e.port) ], [ 'int', 'int', 'int' ]);
});

t.test('T01: LOST adds its count to dropped.dnsmasq_reported', () => {
	let c = counters();
	t.eq(parse_line(P + 'overflow: 12 log entries lost', c), null);
	t.eq(parse_line(P + 'overflow: 3 log entries lost', c), null);
	t.eq(c.dropped.dnsmasq_reported, 15);
	t.eq(c.rejected_lines, 0);
});

t.test('T01: works without a counters object', () => {
	t.eq(parse_line(P + 'overflow: 12 log entries lost'), null);
	t.eq(parse_line(P + '1 1.2.3.4/5 query[A] UPPER.example from 1.2.3.4'), null);
});

t.test('T02: spoofed, unprintable, extra-token, uppercase and "not implemented" lines are rejected', () => {
	for (let body in [
		'23 10.0.2.2/40992 query[A] victim.example.com is 0.0.0.0.example.test from 10.0.2.2',
		'23 10.0.2.2/40992 config victim.example.com is 0.0.0.0.example.test is NXDOMAIN',
		'24 10.0.2.2/59730 query[A] <name unprintable> from 10.0.2.2',
		'24 10.0.2.2/59730 config <name unprintable> is NXDOMAIN',
		'25 10.0.2.2/1 reply victim.com is 0.0.0.0 extra',
		'26 10.0.2.2/1 query[A] UPPER.example.com from 10.0.2.2',
		'27 10.0.2.2/1 reply x.example.com is not implemented',
		'28 10.0.2.2/1 reply x.example.com is SERVFAIL (unbalanced',
		'29 10.0.2.2 reply x.example.com is 1.2.3.4',
		'UDP 30 10.0.2.2/1 reply x.example.com'
	]) {
		let c = counters();
		t.eq(parse_line(P + body, c), null, body);
		t.eq(c.rejected_lines, 1, `rejected_lines for ${body}`);
	}
});

t.test('T02: non-dnsmasq and informational dnsmasq lines are ignored silently', () => {
	let c = counters();
	for (let line in [
		'Tue Nov 10 01:09:19 2026 daemon.info dnsmasq-dhcp[1234]: DHCPACK(br-lan) 192.168.1.10',
		'Tue Nov 10 01:09:19 2026 daemon.info other[1]: 1 1.2.3.4/5 query[A] x.example from 1.2.3.4',
		'garbage',
		'',
		'Tue Nov 10 01:09:19 2026 daemon.info dnsmasq[1]: started, version 2.93 cachesize 1000',
		'Tue Nov 10 01:09:19 2026 daemon.info dnsmasq[1]: read /etc/hosts - 12 names',
		'Tue Nov 10 01:09:19 2026 daemon.warn dnsmasq[1]: possible DNS-rebind attack detected: x.example'
	])
		t.eq(parse_line(line, c), null, line);
	t.eq(c.rejected_lines, 0);
	t.eq(parse_line('Tue Nov 10 01:09:19 2026 daemon.info dnsmasq[1]: 1 1.2.3.4/5 query[A] x.example from 1.2.3.4 ', c), null);
	t.eq(c.rejected_lines, 1, 'a query-log line with a trailing space is rejected');
});

const CTX = { exclude_router: true, local_domains: [ 'lan', 'home.arpa', 'corp.example' ] };

function cls(body, ctx) {
	let e = parse_line(P + body);
	t.ok(e, `parses: ${body}`);
	return classify(e, ctx ?? CTX);
}

function decide(decision, source) {
	return { kind: 'decide', decision, source };
}

t.test('T03: §4.4 table rows', () => {
	let rows = [
		[ '1 10.0.0.2/1 query[A] a.example from 10.0.0.2', { kind: 'query', qtype: 'A' } ],
		[ '1 10.0.0.2/1 query[type=65] a.example from 10.0.0.2', { kind: 'query', qtype: 'type=65' } ],
		[ '1 127.0.0.1/1 query[A] a.example from 127.0.0.1', null ],
		[ '1 ::1/1 query[A] a.example from ::1', null ],
		[ '1 ::1/1 cached a.example is 1.2.3.4', null ],
		[ '1 10.0.0.2/1 forwarded a.example to 1.1.1.1', null ],
		[ '1 10.0.0.2/1 config a.lan is NXDOMAIN', decide('other', 'local') ],
		[ '1 10.0.0.2/1 config lan is NXDOMAIN', decide('other', 'local') ],
		[ '1 10.0.0.2/1 config wpad is NXDOMAIN', decide('other', 'local') ],
		[ '1 10.0.0.2/1 config 1.0.0.10.in-addr.arpa is NXDOMAIN', decide('other', 'local') ],
		[ '1 10.0.0.2/1 config localhost is 127.0.0.1', decide('other', 'local') ],
		[ '1 10.0.0.2/1 config printer.local is NXDOMAIN', decide('other', 'local') ],
		[ '1 10.0.0.2/1 config x.corp.example is NXDOMAIN', decide('other', 'local') ],
		[ '1 10.0.0.2/1 config 10.0.0.1 is NXDOMAIN', decide('other', 'local') ],
		[ '1 10.0.0.2/1 config fd00::1 is NXDOMAIN', decide('other', 'local') ],
		[ '1 10.0.0.2/1 config ads.example.com is NXDOMAIN', decide('blocked', 'config') ],
		[ '1 10.0.0.2/1 config ads.example.com is NODATA', decide('blocked', 'config') ],
		[ '1 10.0.0.2/1 config ads.example.com is NODATA-IPv4', decide('blocked', 'config') ],
		[ '1 10.0.0.2/1 config ads.example.com is NODATA-IPv6', decide('blocked', 'config') ],
		[ '1 10.0.0.2/1 config ads.example.com is 0.0.0.0', decide('blocked', 'config') ],
		[ '1 10.0.0.2/1 config ads.example.com is ::', decide('blocked', 'config') ],
		[ '1 10.0.0.2/1 config ads.example.com is 127.0.0.1', decide('blocked', 'config') ],
		[ '1 10.0.0.2/1 config ads.example.com is 192.0.2.7', decide('other', 'config') ],
		[ '1 10.0.0.2/1 config ads.example.com is <CNAME>', decide('other', 'config') ],
		[ '1 10.0.0.2/1 /var/run/adblock-fast/dnsmasq.addnhosts ads.example.com is 127.0.0.1', decide('blocked', 'addnhosts') ],
		[ '1 10.0.0.2/1 /var/run/adblock-fast/dnsmasq.addnhosts ads.example.com is ::', decide('blocked', 'addnhosts') ],
		[ '1 10.0.0.2/1 /etc/hosts localhost is 127.0.0.1', decide('other', 'hosts') ],
		[ '1 10.0.0.2/1 /tmp/hosts/dhcp.cfg01411c router.lan is 192.168.1.1', decide('other', 'hosts') ],
		[ '1 10.0.0.2/1 DHCP pc.lan is 192.168.1.5', decide('other', 'dhcp') ],
		[ '1 10.0.0.2/1 reply query is duplicate', null ],
		[ '1 10.0.0.2/1 reply a.example is SERVFAIL', decide('other', 'error') ],
		[ '1 10.0.0.2/1 reply error is REFUSED', decide('other', 'error') ],
		[ '1 10.0.0.2/1 reply a.example is FORMERR', decide('other', 'error') ],
		[ '1 10.0.0.2/1 reply a.example is 9', decide('other', 'error') ],
		[ '1 10.0.0.2/1 reply a.example is 93.184.216.34', decide('allowed', 'upstream') ],
		[ '1 10.0.0.2/1 reply a.example is 2001:db8::10', decide('allowed', 'upstream') ],
		[ '1 10.0.0.2/1 reply a.example is <CNAME>', decide('allowed', 'upstream') ],
		[ '1 10.0.0.2/1 reply a.example is <HTTPS>', decide('allowed', 'upstream') ],
		[ '1 10.0.0.2/1 reply a.example is NXDOMAIN', decide('allowed', 'upstream') ],
		[ '1 10.0.0.2/1 reply a.example is NODATA-IPv6', decide('allowed', 'upstream') ],
		[ '1 10.0.0.2/1 cached a.example is 93.184.216.34', decide('allowed', 'cache') ],
		[ '1 10.0.0.2/1 cached-stale a.example is 93.184.216.34', decide('allowed', 'cache') ],
		[ '1 10.0.0.2/1 auth a.example is 192.0.2.1', decide('other', 'auth') ],
		[ '1 10.0.0.2/1 dnssec-query[DS] a.example to 1.1.1.1', null ],
		[ '1 10.0.0.2/1 validation a.example is BOGUS', null ],
		[ '1 10.0.0.2/1 query[A] a.example is 1.2.3.4', null ]
	];
	for (let r in rows)
		t.eq(cls(r[0]), r[1], r[0]);
});

t.test('T03: exclude_router=0 keeps router queries', () => {
	t.eq(cls('1 127.0.0.1/1 query[A] a.example from 127.0.0.1', { exclude_router: false }), { kind: 'query', qtype: 'A' });
	t.eq(cls('1 ::1/1 cached a.example is 1.2.3.4', {}), decide('allowed', 'cache'));
});

t.test('T03: locality is judged on the pending query name when given', () => {
	let e = parse_line(P + '21 10.0.2.2/44146 config 10.0.0.1 is NXDOMAIN');
	t.eq(classify(e, { qname: '1.0.0.10.in-addr.arpa' }), decide('other', 'local'));
	e = parse_line(P + '21 10.0.2.2/44146 config cdn.example.com is NXDOMAIN');
	t.eq(classify(e, { qname: 'www.lan', local_domains: [ 'lan' ] }), decide('other', 'local'));
	t.eq(classify(e, { qname: 'www.example.com', local_domains: [ 'lan' ] }), decide('blocked', 'config'));
});

t.test('T03: local_domains may be a function, called only for config lines', () => {
	let calls = 0;
	let ctx = { local_domains: () => { calls++; return [ 'lan' ]; } };
	cls('1 10.0.0.2/1 reply a.example is 1.2.3.4', ctx);
	cls('1 10.0.0.2/1 query[A] a.example from 10.0.0.2', ctx);
	t.eq(calls, 0);
	t.eq(cls('1 10.0.0.2/1 config a.lan is NXDOMAIN', ctx), decide('other', 'local'));
	t.eq(calls, 1);
});

t.test('T03: is_local edge cases', () => {
	t.ok(is_local('lan', [ 'lan' ]));
	t.ok(!is_local('notlan.example', [ 'lan' ]), 'suffix must be label-aligned');
	t.ok(!is_local('xlan.example', [ 'lan.example' ]), 'suffix must be label-aligned');
	t.ok(!is_local('example.com', [ '' ]), 'empty domain values are ignored');
	t.ok(is_local('x.onion', []) && is_local('x.invalid', []) && is_local('version.bind', []));
	t.ok(!is_local('ads.example.test', []), '.test is not special (fixtures use it)');
	t.ok(!is_local('arpa.example.com', []));
});

t.test('§4.2 framing: splits chunks across reads', () => {
	let n = 0;
	let f = framer(() => n++);
	t.eq(f.feed('abc'), []);
	t.eq(f.feed('def\nghi\n\njk'), [ 'abcdef', 'ghi', '' ]);
	t.eq(f.buffered(), 2);
	t.eq(f.feed('l\n'), [ 'jkl' ]);
	t.eq(n, 0);
});

t.test('§4.2 framing: a line over 1024 bytes is discarded up to the next newline', () => {
	let n = 0;
	let f = framer(() => n++);
	let long = '';
	for (let i = 0; i < LINE_MAX + 1; i++)
		long += 'x';
	t.eq(f.feed('ok\n' + long + '\nnext\n'), [ 'ok', 'next' ], 'complete over-long line');
	t.eq(n, 1);
	t.eq(f.feed(long), [], 'partial over-long line');
	t.eq(n, 2);
	t.eq(f.feed('still the same line'), [], 'rest of it is skipped');
	t.eq(f.feed(' end\nafter\n'), [ 'after' ]);
	t.eq(n, 2);
	let exact = substr(long, 0, LINE_MAX);
	t.eq(f.feed(exact + '\n'), [ exact ], 'exactly 1024 bytes is kept');
});

t.test('§4.2 framing: more than 64 KiB buffered is discarded entirely', () => {
	let n = 0;
	let f = framer(() => n++);
	let big = '';
	while (length(big) <= 65536)
		big += 'short line\n';
	t.eq(f.feed(big + 'cut'), []);
	t.eq(n, 1);
	t.eq(f.feed(' tail\nnext\n'), [ 'next' ], 'the cut line is skipped');
});

t.done();
