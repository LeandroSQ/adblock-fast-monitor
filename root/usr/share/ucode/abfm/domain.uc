// SPDX-License-Identifier: Apache-2.0
// abfm.domain: pure helpers for the actions backend (docs/CONTRACT.md
// §6.4-6.6, §7.2). No I/O: callers pass in UCI values, file lines and DNS
// answers, so every function runs under a bare ucode interpreter.
'use strict';

const MAX_OPS = 64;
const OPS = { allow: true, block: true };

// §6.5 (b): two-label names whose first label is one of these are suffixes.
const SLD_GENERIC = {};
for (let l in split('ac co com edu gob gouv gov gv go govt ltd mil net nic nom or org plc sch ne int mod', ' '))
	SLD_GENERIC[l] = true;

// §6.5 (c) ABFM_PRIVATE_SUFFIXES_V1.
const PRIVATE_SUFFIXES = {};
for (let s in split('github.io gitlab.io blogspot.com appspot.com herokuapp.com cloudfront.net amazonaws.com ' +
	's3.amazonaws.com azurewebsites.net azureedge.net cloudapp.net trafficmanager.net windows.net pages.dev ' +
	'workers.dev vercel.app netlify.app firebaseapp.com web.app duckdns.org dyndns.org no-ip.org ddns.net ' +
	'myqnapcloud.com synology.me fastly.net akamaized.net edgekey.net edgesuite.net googleusercontent.com ' +
	'fbcdn.net cdn.cloudflare.net r2.dev ngrok.io ngrok-free.app onrender.com fly.dev', ' '))
	PRIVATE_SUFFIXES[s] = true;

// §6.5: names that never get a block rule, equal or under. The same names the
// page treats as local (§8.3), plus `internal`.
const BUILTIN_PROTECTED = [ 'localhost', 'arpa', 'local', 'internal', 'invalid', 'onion', 'bind' ];

// adblock-fast `dns` mode -> output file (§10).
const DNSMASQ_MODES = {
	'dnsmasq.servers': '/var/run/adblock-fast/dnsmasq.servers',
	'dnsmasq.addnhosts': '/var/run/adblock-fast/dnsmasq.addnhosts',
	'dnsmasq.conf': '/var/run/adblock-fast/adblock-fast.dnsmasq',
	'dnsmasq.ipset': '/var/run/adblock-fast/adblock-fast.dnsmasq',
	'dnsmasq.nftset': '/var/run/adblock-fast/adblock-fast.dnsmasq',
};
const LISTED_MODES = { 'dnsmasq.servers': true, 'dnsmasq.conf': true, 'dnsmasq.addnhosts': true };
const SINKHOLES = { '0.0.0.0': true, '127.0.0.1': true, '::': true };
const DNS_ERRORS = { SERVFAIL: true, TIMEOUT: true, REFUSED: true };

function err(code, message, extra) {
	let e = { code, message };
	for (let k, v in extra)
		e[k] = v;
	return e;
}

// §6.4 normalization: trim, lower-case, strip one trailing dot.
function normalize(s) {
	if (type(s) != 'string')
		return null;
	s = lc(trim(s));
	if (substr(s, -1) == '.')
		s = substr(s, 0, length(s) - 1);
	return s;
}

// §6.4 grammar.
function valid(d) {
	if (type(d) != 'string' || length(d) < 1 || length(d) > 253)
		return false;
	let labels = split(d, '.');
	let n = length(labels);
	if (n < 2 || n > 127)
		return false;
	// No bounded repetition: musl's regex engine expands {m,n} into a large
	// automaton that takes milliseconds per match.
	for (let l in labels)
		if (length(l) > 63 || !match(l, /^[a-z0-9_]$|^[a-z0-9_][a-z0-9_-]*[a-z0-9_]$/))
			return false;
	return !match(labels[n - 1], /^[0-9]+$/);
}

// §7.1 job ids: ^j[0-9]{10}-[0-9a-f]{4}$
function valid_job_id(id) {
	return type(id) == 'string' && length(id) == 16 && substr(id, 11, 1) == '-' &&
		!!match(id, /^j[0-9]+-[0-9a-f]+$/);
}

function under(d, parent) {
	return d == parent ||
		(length(d) > length(parent) && substr(d, length(d) - length(parent) - 1) == '.' + parent);
}

// All suffixes of d, longest first: a.b.c -> [a.b.c, b.c, c].
function suffixes(d) {
	let labels = split(d, '.'), out = [];
	for (let i = 0; i < length(labels); i++)
		push(out, join('.', slice(labels, i)));
	return out;
}

function public_suffix(d) {
	let labels = split(d, '.');
	return (length(labels) < 2) ||
		(length(labels) == 2 && !!SLD_GENERIC[labels[0]]) ||
		!!PRIVATE_SUFFIXES[d];
}

// Host part of a URL, lower-cased, or null.
function url_host(url) {
	let m = match(type(url) == 'string' ? trim(url) : '', /^[A-Za-z][A-Za-z0-9+.-]*:\/\/([^\/?#@]*@)?([^\/?#:]+)/);
	return m ? normalize(m[2]) : null;
}

// §6.5 protected set: names match equal-or-under, hosts match exactly.
function protect_context(names, hosts) {
	let ctx = { names: [], hosts: [] };
	for (let n in [ ...BUILTIN_PROTECTED, ...(names ?? []) ]) {
		n = normalize(replace(n ?? '', /\//g, ''));
		if (n && index(ctx.names, n) < 0)
			push(ctx.names, n);
	}
	for (let h in hosts ?? []) {
		h = normalize(h);
		if (h && index(ctx.hosts, h) < 0)
			push(ctx.hosts, h);
	}
	return ctx;
}

function protected_domain(d, ctx) {
	for (let n in ctx?.names ?? BUILTIN_PROTECTED)
		if (under(d, n))
			return true;
	return index(ctx?.hosts ?? [], d) >= 0;
}

// Validates one normalized domain for an op; returns an error code or null.
function check_domain(op, d, ctx) {
	if (!valid(d))
		return 'invalid-domain';
	if (public_suffix(d))
		return 'public-suffix';
	if (op == 'block' && protected_domain(d, ctx))
		return 'protected-domain';
	return null;
}

const MESSAGES = {
	'invalid-domain': 'not a valid domain name',
	'public-suffix': 'refusing a rule for a public suffix',
	'protected-domain': 'refusing to block a protected domain',
};

// §6.3 steps 1-3. args: the apply request. Returns { ops } or { error }.
function validate_batch(args, ctx) {
	let ops = args?.ops ?? [];
	if (type(ops) != 'array')
		return { error: err('invalid-request', 'ops must be an array') };
	if (length(ops) > MAX_OPS)
		return { error: err('batch-too-large', `at most ${MAX_OPS} ops per batch`) };
	if (!length(ops) && args?.rebuild !== true)
		return { error: err('batch-empty', 'nothing to apply') };

	let out = [], by_domain = {};
	for (let i = 0; i < length(ops); i++) {
		let o = ops[i];
		if (type(o) != 'object' || type(o.op) != 'string' || !OPS[o.op] || type(o.domain) != 'string')
			return { error: err('invalid-request', 'each op needs op (allow|block) and domain', { index: i }) };
		let d = normalize(o.domain);
		let code = check_domain(o.op, d, ctx);
		if (code)
			return { error: err(code, MESSAGES[code], { index: i, domain: d }) };
		let prev = by_domain[d];
		if (prev) {
			if (prev.op != o.op)
				return { error: err('conflict', `conflicting ops for ${d}`, { index: i, domain: d }) };
			continue;
		}
		by_domain[d] = { op: o.op, domain: d, index: i };
		push(out, by_domain[d]);
	}
	return { ops: out };
}

const EXPECT = { allow: 'allowed', block: 'blocked' };

// §6.6. state: { allowed, blocked, enabled, rebuild }.
// Returns { items, mode, noop } or { error }.
function plan(ops, state) {
	let A = {}, B = {};
	for (let d in state?.allowed ?? []) A[d] = true;
	for (let d in state?.blocked ?? []) B[d] = true;

	let items = [], after_allow = { ...A }, changed = false;
	for (let o in ops) {
		let D = o.domain, change = [];
		switch (o.op) {
		case 'allow':
			if (!A[D]) push(change, 'allow:add');
			if (B[D]) push(change, 'block:remove');
			break;
		case 'block':
			if (A[D]) push(change, 'allow:remove');
			if (!B[D]) push(change, 'block:add');
			break;
		}
		for (let c in change) {
			if (c == 'allow:add') after_allow[D] = true;
			if (c == 'allow:remove') delete after_allow[D];
		}
		if (length(change)) changed = true;
		push(items, { op: o.op, domain: D, change, expect: EXPECT[o.op], index: o.index });
	}

	// The rebuild removes allowed names after it adds blocks (§6.3 step 5).
	for (let it in items) {
		if (it.op != 'block')
			continue;
		for (let s in suffixes(it.domain))
			if (after_allow[s])
				return { error: err('allow-overrides',
					`${s} is in allowed_domain, which overrides blocking ${it.domain}`,
					{ index: it.index, domain: it.domain }) };
	}
	for (let it in items)
		delete it.index;

	return {
		items,
		mode: state?.enabled ? 'rebuild' : 'persist-only',
		noop: !changed && state?.rebuild !== true,
	};
}

// Public plan entries (§6.3 response).
function plan_view(items) {
	return map(items, (it) => ({ op: it.op, domain: it.domain, change: it.change }));
}

// grep -F patterns selecting every output line that can decide `listed` for
// the domains (a superset; listed() filters exactly).
function grep_patterns(domains, dns) {
	let pats = {};
	for (let d in domains) {
		if (dns == 'dnsmasq.addnhosts')
			pats[' ' + d] = true;
		else
			for (let s in suffixes(d))
				pats['/' + s + '/'] = true;
	}
	return keys(pats);
}

function shell_quote(s) {
	return "'" + replace(s, "'", "'\\''") + "'";
}

// Shell command printing those lines of `file`.
function grep_command(file, domains, dns) {
	return 'grep -F' + join('', map(grep_patterns(domains, dns), (p) => ' -e ' + shell_quote(p))) +
		' -- ' + shell_quote(file) + ' 2>/dev/null';
}

// One output-file line -> { domain, allow } or null.
function parse_line(line, dns) {
	let m;
	switch (dns) {
	case 'dnsmasq.servers':
		m = match(line, /^server=\/([^\/]+)\/(#?)$/);
		return m ? { domain: m[1], allow: m[2] == '#' } : null;
	case 'dnsmasq.conf':
		m = match(line, /^local=\/([^\/]+)\/$/);
		return m ? { domain: m[1], allow: false } : null;
	case 'dnsmasq.addnhosts':
		m = match(line, /^(127\.0\.0\.1|::) ([^ ]+)$/);
		return m ? { domain: m[2], allow: false } : null;
	}
	return null;
}

// §7.2 `listed` per domain: { listed: true|false|null, by: entry|null }.
// lines: output-file lines (any superset of the grep_patterns matches).
function listed(domains, lines, dns) {
	let out = {};
	if (!LISTED_MODES[dns]) {
		for (let d in domains) out[d] = { listed: null, by: null };
		return out;
	}
	let entries = {};
	for (let l in lines ?? []) {
		let p = parse_line(l, dns);
		// dnsmasq answers server=/D/ locally even when server=/D/# also exists.
		if (p && (!exists(entries, p.domain) || entries[p.domain]))
			entries[p.domain] = p.allow;
	}
	for (let d in domains) {
		let r = { listed: false, by: null };
		for (let s in (dns == 'dnsmasq.addnhosts') ? [ d ] : suffixes(d)) {
			if (exists(entries, s)) {
				r = { listed: !entries[s], by: s };
				break;
			}
		}
		out[d] = r;
	}
	return out;
}

// Folds a resolv.query() result for d (following CNAMEs) into
// { rcode, a, aaaa, cname }.
function answer_of(res, d) {
	let a = [], aaaa = [], cname = false, rcode = null, name = d, seen = {};
	for (let hop = 0; hop < 8 && name && !seen[name]; hop++) {
		seen[name] = true;
		let r = res?.[name];
		if (type(r) != 'object')
			break;
		if (hop == 0 && type(r.rcode) == 'string')
			rcode = r.rcode;
		for (let ip in r.A ?? []) push(a, ip);
		for (let ip in r.AAAA ?? []) push(aaaa, ip);
		if (!length(r.CNAME ?? []))
			break;
		cname = true;
		name = r.CNAME[0];
	}
	return { rcode: rcode ?? 'NOERROR', a, aaaa, cname };
}

// §7.2 step 4 `observed`.
function observe(ans, listed_value) {
	let sink = false, real = false;
	for (let ip in [ ...ans.a, ...ans.aaaa ]) {
		if (SINKHOLES[ip]) sink = true;
		else real = true;
	}
	if (sink)
		return 'blocked';
	if (real || ans.cname)
		return 'allowed';
	if (ans.rcode == 'NXDOMAIN')
		return (listed_value === true) ? 'blocked' : (listed_value === false) ? 'allowed' : 'unknown';
	if (ans.rcode == 'NOERROR' && listed_value === true)
		return 'blocked';
	return 'unknown';
}

// §7.1 item verdict: { result, reason }.
function verdict(item, observed, ans, lst, dns) {
	if (dns == 'dnsmasq.ipset' || dns == 'dnsmasq.nftset')
		return { result: 'unverified', reason: 'dns-mode-unsupported' };
	if (!length(item.change) || observed == item.expect)
		return { result: 'ok', reason: null };
	if (observed == 'unknown')
		return DNS_ERRORS[ans?.rcode]
			? { result: 'unverified', reason: 'dns-error' }
			: { result: 'mismatch', reason: null };
	if (item.expect == 'blocked')
		return { result: 'mismatch', reason: 'not-blocked' };
	if (lst?.listed === true && lst.by != item.domain)
		return { result: 'mismatch', reason: 'parent-blocked' };
	return { result: 'mismatch', reason: (lst?.listed === true) ? 'still-listed' : null };
}

return {
	MAX_OPS, DNSMASQ_MODES, PRIVATE_SUFFIXES,
	normalize, valid, valid_job_id, under, suffixes, public_suffix, url_host,
	protect_context, protected_domain, check_domain,
	validate_batch, plan, plan_view,
	grep_patterns, grep_command, shell_quote, parse_line, listed,
	answer_of, observe, verdict,
};
