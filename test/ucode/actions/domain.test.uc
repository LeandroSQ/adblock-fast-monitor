// T12 (docs/CONTRACT.md §6.4-6.5): grammar, normalization, protected set and
// public-suffix guard of the real abfm.domain module.
push(REQUIRE_SEARCH_PATH, '/src/root/usr/share/ucode/*.uc');
let t = require('testlib');
let d = require('abfm.domain');

t.test('normalize trims, lower-cases and strips exactly one trailing dot', () => {
	t.eq(d.normalize('  Ads.Example.COM.  '), 'ads.example.com');
	t.eq(d.normalize('a.example.com..'), 'a.example.com.');
	t.eq(d.normalize(42), null);
});

t.test('grammar accepts valid names', () => {
	for (let n in [ 'a.b', 'ads.example.com', '_dmarc.example.com', 'x_y.example.com', 'xn--bcher-kva.example',
		'a-b.example.com', '9gag.com', 'example.c0m' ])
		t.ok(d.valid(n), n);
	let l63 = '', l64;
	for (let i = 0; i < 63; i++) l63 += 'a';
	l64 = l63 + 'a';
	t.ok(d.valid(l63 + '.com'), '63-char label');
	t.ok(!d.valid(l64 + '.com'), '64-char label');
	let long = l63 + '.' + l63 + '.' + l63 + '.' + substr(l63, 0, 61);
	t.eq(length(long), 253);
	t.ok(d.valid(long), '253 chars');
	t.ok(!d.valid(long + 'a'), '254 chars');
	let labels = [];
	for (let i = 0; i < 127; i++) push(labels, 'a');
	t.ok(d.valid(join('.', labels)), '127 labels');
	push(labels, 'a');
	t.ok(!d.valid(join('.', labels)), '128 labels');
});

t.test('grammar rejects invalid names', () => {
	for (let n in [ '', 'com', 'localhost', '-a.example.com', 'a-.example.com', 'a..b', '.a.b', '1.2.3.4',
		'example.123', '*.example.com', 'a/b.com', 'a:b.com', 'a b.com', 'bücher.example', 'Ads.example.com',
		'a.example.com.', 'ads.example.com;rm', null ])
		t.ok(!d.valid(n), `${n}`);
});

t.test('public-suffix guard (b): generic second-level labels', () => {
	for (let n in [ 'co.uk', 'com.au', 'ac.jp', 'gov.br', 'org.nz', 'ne.jp', 'gouv.fr', 'mod.uk' ])
		t.ok(d.public_suffix(n), n);
	for (let n in [ 'example.com', 'bbc.co.uk', 'abc.com.au', 'co.example.com', 'coo.uk' ])
		t.ok(!d.public_suffix(n), n);
});

t.test('public-suffix guard (c): every ABFM_PRIVATE_SUFFIXES_V1 entry, exact only', () => {
	let list = split('github.io gitlab.io blogspot.com appspot.com herokuapp.com cloudfront.net amazonaws.com s3.amazonaws.com azurewebsites.net azureedge.net cloudapp.net trafficmanager.net windows.net pages.dev workers.dev vercel.app netlify.app firebaseapp.com web.app duckdns.org dyndns.org no-ip.org ddns.net myqnapcloud.com synology.me fastly.net akamaized.net edgekey.net edgesuite.net googleusercontent.com fbcdn.net cdn.cloudflare.net r2.dev ngrok.io ngrok-free.app onrender.com fly.dev', ' ');
	t.eq(length(keys(d.PRIVATE_SUFFIXES)), length(list));
	for (let n in list) {
		t.ok(d.public_suffix(n), n);
		t.ok(!d.public_suffix('user.' + n), 'user.' + n);
	}
	t.ok(!d.public_suffix('pvt.k12.ma.us'), 'documented limitation: unlisted 3-label suffix passes');
});

t.test('url_host extracts the host of list URLs', () => {
	t.eq(d.url_host('https://cdn.jsdelivr.net/gh/x/y.txt'), 'cdn.jsdelivr.net');
	t.eq(d.url_host('http://user:pw@Lists.Example.org:8080/a?b#c'), 'lists.example.org');
	t.eq(d.url_host('http://10.0.2.2:35907/fixtures/actions/block.txt'), '10.0.2.2');
	t.eq(d.url_host('not a url'), null);
	t.eq(d.url_host(null), null);
});

let ctx = d.protect_context([ 'lan', '/lan/', '/home.example/', 'OpenWrt', 'heartbeat.mossdef.org', null ],
	[ d.url_host('https://big.oisd.nl/'), d.url_host('https://cdn.jsdelivr.net/gh/a/b') ]);

t.test('protected set: built-ins, dhcp domain/local, hostname, heartbeat (equal or under)', () => {
	for (let n in [ 'localhost', 'x.localhost', 'in-addr.arpa', '1.168.192.in-addr.arpa', 'printer.local',
		'svc.internal', 'home.arpa', 'nas.home.arpa', 'router.lan', 'pc.home.example', 'x.openwrt',
		'heartbeat.mossdef.org', 'a.heartbeat.mossdef.org' ])
		t.ok(d.protected_domain(n, ctx), n);
	for (let n in [ 'mossdef.org', 'example.com', 'lan.example.com', 'arpa.example.com', 'oisd.nl' ])
		t.ok(!d.protected_domain(n, ctx), n);
});

t.test('protected set: list hosts match exactly', () => {
	t.ok(d.protected_domain('big.oisd.nl', ctx));
	t.ok(d.protected_domain('cdn.jsdelivr.net', ctx));
	t.ok(!d.protected_domain('x.big.oisd.nl', ctx));
});

t.test('check_domain: protected applies to block and unallow only; public-suffix to all ops', () => {
	t.eq(d.check_domain('block', 'heartbeat.mossdef.org', ctx), 'protected-domain');
	t.eq(d.check_domain('unallow', 'cdn.jsdelivr.net', ctx), 'protected-domain');
	t.eq(d.check_domain('allow', 'heartbeat.mossdef.org', ctx), null);
	t.eq(d.check_domain('unblock', 'router.lan', ctx), null);
	for (let op in [ 'allow', 'unblock', 'block', 'unallow' ]) {
		t.eq(d.check_domain(op, 'github.io', ctx), 'public-suffix', op);
		t.eq(d.check_domain(op, 'co.uk', ctx), 'public-suffix', op);
		t.eq(d.check_domain(op, 'bad_domain-.com', ctx), 'invalid-domain', op);
	}
});

t.test('validate_batch normalizes and reports index and domain', () => {
	let r = d.validate_batch({ ops: [ { op: 'allow', domain: ' Ads.Example.com. ' }, { op: 'block', domain: 'co.uk' } ] }, ctx);
	t.eq(r.error, { code: 'public-suffix', message: 'refusing a rule for a public suffix', index: 1, domain: 'co.uk' });
	r = d.validate_batch({ ops: [ { op: 'allow', domain: ' Ads.Example.com. ' } ] }, ctx);
	t.eq(r.ops, [ { op: 'allow', domain: 'ads.example.com', index: 0 } ]);
	r = d.validate_batch({ ops: [ { op: 'unallow', domain: 'nas.home.arpa' } ] }, ctx);
	t.eq([ r.error.code, r.error.index, r.error.domain ], [ 'protected-domain', 0, 'nas.home.arpa' ]);
	r = d.validate_batch({ ops: [ { op: 'allow', domain: '1.2.3.4' } ] }, ctx);
	t.eq(r.error.code, 'invalid-domain');
});

t.test('validate_batch shape errors', () => {
	t.eq(d.validate_batch({}, ctx).error.code, 'batch-empty');
	t.eq(d.validate_batch({ ops: [] }, ctx).error.code, 'batch-empty');
	t.eq(d.validate_batch({ ops: [], rebuild: true }, ctx).ops, []);
	t.eq(d.validate_batch({ ops: 'x' }, ctx).error.code, 'invalid-request');
	t.eq(d.validate_batch({ ops: [ { op: 'nuke', domain: 'a.example.com' } ] }, ctx).error, {
		code: 'invalid-request', message: 'each op needs op (allow|unblock|block|unallow) and domain', index: 0 });
	t.eq(d.validate_batch({ ops: [ 'a.example.com' ] }, ctx).error.code, 'invalid-request');
	let ops = [];
	for (let i = 0; i < 64; i++) push(ops, { op: 'allow', domain: `d${i}.example.com` });
	t.eq(length(d.validate_batch({ ops }, ctx).ops), 64);
	push(ops, { op: 'allow', domain: 'd64.example.com' });
	t.eq(d.validate_batch({ ops }, ctx).error.code, 'batch-too-large');
});

t.test('validate_batch: identical ops collapse, different ops conflict', () => {
	let r = d.validate_batch({ ops: [ { op: 'allow', domain: 'a.example.com' }, { op: 'allow', domain: 'A.example.com.' } ] }, ctx);
	t.eq(length(r.ops), 1);
	r = d.validate_batch({ ops: [ { op: 'allow', domain: 'a.example.com' }, { op: 'unallow', domain: 'a.example.com' } ] }, ctx);
	t.eq([ r.error.code, r.error.index, r.error.domain ], [ 'conflict', 1, 'a.example.com' ]);
});

t.done();
