// T13 (docs/CONTRACT.md §6.6) plan table and mode selection, plus the pure
// halves of §6.2 (listed, rule view) and §7.2 (observed, verdict) that the
// plugin and job feed with real files and DNS answers.
push(REQUIRE_SEARCH_PATH, '/src/root/usr/share/ucode/*.uc');
let t = require('testlib');
let d = require('abfm.domain');

function plan(ops, state) {
	let v = d.validate_batch({ ops, rebuild: state?.rebuild }, d.protect_context([], []));
	if (v.error)
		return v;
	return d.plan(v.ops, state);
}

function one(op, dom, A, B) {
	let p = plan([ { op, domain: dom } ], { allowed: A, blocked: B, enabled: true });
	return [ p.items[0].effective_op, p.items[0].change ];
}

let D = 'x.example.com';

t.test('allow: allow:add unless allowed, block:remove when blocked', () => {
	t.eq(one('allow', D, [], []), [ 'allow', [ 'allow:add' ] ]);
	t.eq(one('allow', D, [], [ D ]), [ 'allow', [ 'allow:add', 'block:remove' ] ]);
	t.eq(one('allow', D, [ D ], []), [ 'allow', [] ]);
});

t.test('unblock of a manual block removes it; otherwise it becomes allow', () => {
	t.eq(one('unblock', D, [], [ D ]), [ 'unblock', [ 'block:remove' ] ]);
	t.eq(one('unblock', D, [], []), [ 'allow', [ 'allow:add' ] ], 'listed by a downloaded list');
	t.eq(one('unblock', D, [], [ 'example.com' ]), [ 'allow', [ 'allow:add' ] ], 'blocked by a parent rule');
	t.eq(one('unblock', D, [ D ], []), [ 'allow', [] ]);
});

t.test('block: allow:remove when allowed, block:add unless blocked', () => {
	t.eq(one('block', D, [], []), [ 'block', [ 'block:add' ] ]);
	t.eq(one('block', D, [ D ], []), [ 'block', [ 'allow:remove', 'block:add' ] ]);
	t.eq(one('block', D, [], [ D ]), [ 'block', [] ]);
});

t.test('unallow: allow:remove or noop; membership is exact', () => {
	t.eq(one('unallow', D, [ D ], []), [ 'unallow', [ 'allow:remove' ] ]);
	t.eq(one('unallow', D, [], []), [ 'unallow', [] ]);
	t.eq(one('unallow', D, [ 'example.com' ], []), [ 'unallow', [] ]);
});

t.test('expectations per op', () => {
	let p = plan([ { op: 'allow', domain: 'a.example.com' }, { op: 'unblock', domain: 'b.example.com' },
		{ op: 'block', domain: 'c.example.com' }, { op: 'unallow', domain: 'd.example.com' } ],
		{ allowed: [ 'd.example.com' ], blocked: [], enabled: true });
	t.eq(map(p.items, (i) => i.expect), [ 'allowed', 'allowed', 'blocked', 'any' ]);
	t.eq(d.plan_view(p.items)[1], { op: 'unblock', domain: 'b.example.com', effective_op: 'allow', change: [ 'allow:add' ] });
});

t.test('allow-overrides: blocking under an allowed entry that stays', () => {
	let p = plan([ { op: 'block', domain: 'ads.cdn.example.com' } ], { allowed: [ 'cdn.example.com' ], blocked: [], enabled: true });
	t.eq([ p.error.code, p.error.index, p.error.domain ], [ 'allow-overrides', 0, 'ads.cdn.example.com' ]);
	p = plan([ { op: 'unallow', domain: 'cdn.example.com' }, { op: 'block', domain: 'ads.cdn.example.com' } ],
		{ allowed: [ 'cdn.example.com' ], blocked: [], enabled: true });
	t.ok(!p.error, 'the parent allow is removed in the same batch');
	p = plan([ { op: 'allow', domain: 'example.com' }, { op: 'block', domain: 'ads.example.com' } ],
		{ allowed: [], blocked: [], enabled: true });
	t.eq([ p.error.code, p.error.index ], [ 'allow-overrides', 1 ], 'allowed in the same batch');
	p = plan([ { op: 'block', domain: D } ], { allowed: [ D ], blocked: [], enabled: true });
	t.ok(!p.error, 'block of an exactly allowed name removes the allow');
});

t.test('noop batches', () => {
	let p = plan([ { op: 'allow', domain: D }, { op: 'unallow', domain: 'y.example.com' } ], { allowed: [ D ], blocked: [], enabled: true });
	t.ok(p.noop);
	p = plan([], { allowed: [], blocked: [], enabled: true, rebuild: true });
	t.ok(!p.noop, 'rebuild:true with ops:[] is not a noop');
	t.eq([ p.mode, p.items ], [ 'rebuild', [] ]);
	p = plan([ { op: 'allow', domain: D } ], { allowed: [ D ], blocked: [], enabled: true, rebuild: true });
	t.ok(!p.noop);
});

t.test('mode selection: persist-only when adblock-fast is disabled, otherwise one rebuild', () => {
	t.eq(plan([ { op: 'allow', domain: D } ], { allowed: [], blocked: [], enabled: false }).mode, 'persist-only');
	for (let op in [ 'allow', 'unblock', 'block', 'unallow' ]) {
		let p = plan([ { op, domain: D } ], { allowed: [ D ], blocked: [ D ], enabled: true });
		t.eq([ p.mode, p.may_escalate ], [ 'rebuild', false ], op);
	}
});

const SERVERS = [ 'server=/cdn.jsdelivr.net/#', 'server=/ads.example.com/', 'server=/parent.example.com/',
	'server=/ok.parent.example.com/#', 'server=/both.example.com/', 'server=/both.example.com/#', 'server=/com/#' ];

t.test('grep patterns cover every suffix and select a superset', () => {
	let pats = d.grep_patterns([ 'a.parent.example.com' ], 'dnsmasq.servers');
	t.eq(sort(pats), sort([ '/a.parent.example.com/', '/parent.example.com/', '/example.com/', '/com/' ]));
	t.eq(d.grep_patterns([ 'ads.example.com' ], 'dnsmasq.addnhosts'), [ ' ads.example.com' ]);
	t.eq(d.grep_command('/f', [ "a'b.com" ], 'dnsmasq.addnhosts'), "grep -F -e ' a'\\''b.com' -- '/f' 2>/dev/null");
});

t.test('listed (servers): longest suffix wins, # is not a block, block beats # for one name', () => {
	let r = d.listed([ 'ads.example.com', 'x.ads.example.com', 'a.parent.example.com', 'ok.parent.example.com',
		'x.ok.parent.example.com', 'www.example.com', 'both.example.com', 'cdn.jsdelivr.net' ], SERVERS, 'dnsmasq.servers');
	t.eq(r['ads.example.com'], { listed: true, by: 'ads.example.com' });
	t.eq(r['x.ads.example.com'], { listed: true, by: 'ads.example.com' });
	t.eq(r['a.parent.example.com'], { listed: true, by: 'parent.example.com' });
	t.eq(r['ok.parent.example.com'], { listed: false, by: 'ok.parent.example.com' });
	t.eq(r['x.ok.parent.example.com'], { listed: false, by: 'ok.parent.example.com' });
	t.eq(r['www.example.com'], { listed: false, by: 'com' });
	t.eq(r['both.example.com'], { listed: true, by: 'both.example.com' });
	t.eq(r['cdn.jsdelivr.net'], { listed: false, by: 'cdn.jsdelivr.net' });
});

t.test('listed (conf, addnhosts, other modes)', () => {
	let r = d.listed([ 'a.ads.example.com', 'b.example.com' ], [ 'local=/ads.example.com/', 'server=/b.example.com/' ], 'dnsmasq.conf');
	t.eq([ r['a.ads.example.com'].listed, r['b.example.com'].listed ], [ true, false ]);
	r = d.listed([ 'ads.example.com', 'x.ads.example.com', 'v6.example.com', 'xads.example.com' ],
		[ '127.0.0.1 ads.example.com', ':: v6.example.com', '127.0.0.1 ads.example.com.evil' ], 'dnsmasq.addnhosts');
	t.eq(map([ 'ads.example.com', 'x.ads.example.com', 'v6.example.com', 'xads.example.com' ], (n) => r[n].listed),
		[ true, false, true, false ]);
	r = d.listed([ 'ads.example.com' ], [ 'nftset=/ads.example.com/4#inet#fw4#adb4' ], 'dnsmasq.nftset');
	t.eq(r['ads.example.com'], { listed: null, by: null });
});

t.test('rule_info: manual, manual_parent, effective and actions', () => {
	t.eq(d.rule_info('ads.example.com', [], [ 'ads.example.com' ], true),
		{ manual: 'block', manual_parent: null, listed: true, effective: 'blocked', actions: [ 'allow', 'unblock' ] });
	t.eq(d.rule_info('www.example.org', [], [], false),
		{ manual: null, manual_parent: null, listed: false, effective: 'allowed', actions: [ 'block' ] });
	t.eq(d.rule_info('x.cdn.example.com', [ 'cdn.example.com' ], [ 'example.com' ], null),
		{ manual: null, manual_parent: { list: 'allow', domain: 'cdn.example.com' }, listed: null, effective: 'unknown',
		  actions: [ 'allow', 'block' ] });
	t.eq(d.rule_info('a.example.com', [ 'a.example.com' ], [], null).effective, 'allowed');
	t.eq(d.rule_info('a.example.com', [ 'a.example.com' ], [], true).actions, [ 'allow', 'unallow' ]);
});

t.test('answer_of follows CNAMEs; observe classifies answers', () => {
	let res = {
		'www.example.org': { CNAME: [ 'cdn.example.net' ] }, 'cdn.example.net': { A: [ '93.184.215.14' ] },
		'ads.example.com': { rcode: 'NXDOMAIN' }, 'sink.example.com': { A: [ '0.0.0.0' ], AAAA: [ '::' ] },
		'lo.example.com': { A: [ '127.0.0.1' ] }, 'down.example.com': { rcode: 'TIMEOUT' },
	};
	let a = d.answer_of(res, 'www.example.org');
	t.eq(a, { rcode: 'NOERROR', a: [ '93.184.215.14' ], aaaa: [], cname: true });
	t.eq(d.observe(a, true), 'allowed');
	t.eq(d.observe(d.answer_of(res, 'sink.example.com'), false), 'blocked');
	t.eq(d.observe(d.answer_of(res, 'lo.example.com'), null), 'blocked');
	t.eq(d.observe(d.answer_of(res, 'ads.example.com'), true), 'blocked');
	t.eq(d.observe(d.answer_of(res, 'ads.example.com'), false), 'allowed');
	t.eq(d.observe(d.answer_of(res, 'ads.example.com'), null), 'unknown');
	t.eq(d.observe(d.answer_of(res, 'empty.example.com'), true), 'blocked', 'NOERROR-empty and listed');
	t.eq(d.observe(d.answer_of(res, 'empty.example.com'), false), 'unknown');
	t.eq(d.observe(d.answer_of(res, 'down.example.com'), false), 'unknown');
	let loop = d.answer_of({ 'a.example.com': { CNAME: [ 'b.example.com' ] }, 'b.example.com': { CNAME: [ 'a.example.com' ] } }, 'a.example.com');
	t.eq(loop.cname, true, 'CNAME loops terminate');
});

t.test('verdict: ok, mismatch reasons, unverified', () => {
	let allow = { domain: 'a.example.com', change: [ 'allow:add' ], expect: 'allowed' };
	let block = { domain: 'b.example.com', change: [ 'block:add' ], expect: 'blocked' };
	let nx = { rcode: 'NXDOMAIN' };
	t.eq(d.verdict(allow, 'allowed', nx, null, 'dnsmasq.servers'), { result: 'ok', reason: null });
	t.eq(d.verdict(allow, 'blocked', nx, { listed: true, by: 'example.com' }, 'dnsmasq.conf'), { result: 'mismatch', reason: 'parent-blocked' });
	t.eq(d.verdict(allow, 'blocked', nx, { listed: true, by: 'a.example.com' }, 'dnsmasq.servers'), { result: 'mismatch', reason: 'still-listed' });
	t.eq(d.verdict(block, 'allowed', nx, { listed: false }, 'dnsmasq.servers'), { result: 'mismatch', reason: 'not-blocked' });
	t.eq(d.verdict(block, 'unknown', { rcode: 'SERVFAIL' }, null, 'dnsmasq.servers'), { result: 'unverified', reason: 'dns-error' });
	t.eq(d.verdict(block, 'unknown', { rcode: 'TIMEOUT' }, null, 'dnsmasq.servers'), { result: 'unverified', reason: 'dns-error' });
	t.eq(d.verdict(block, 'unknown', { rcode: 'NOERROR' }, null, 'dnsmasq.servers'), { result: 'mismatch', reason: null });
	t.eq(d.verdict(block, 'allowed', nx, null, 'dnsmasq.nftset'), { result: 'unverified', reason: 'dns-mode-unsupported' });
	t.eq(d.verdict({ ...block, change: [] }, 'allowed', nx, null, 'dnsmasq.servers'), { result: 'ok', reason: null }, 'noop');
	t.eq(d.verdict({ ...block, expect: 'any' }, 'allowed', nx, null, 'dnsmasq.servers'), { result: 'ok', reason: null }, 'unallow');
});

t.done();
