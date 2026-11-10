#!/usr/bin/ucode
// TEST-ONLY stand-in for WU1's monitord.uc (docs/CONTRACT.md §4.6). Never
// shipped. Installed by test/browser/fixtures/stub/install.sh only when the
// browser suite runs with ABFM_UI_STUB=1, before the real backends exist.
// It follows the published wire shapes; it is not a reference implementation.
'use strict';

import * as uloop from 'uloop';
import * as io from 'io';
import { connect } from 'ubus';
import { popen } from 'fs';
import { cursor } from 'uci';

function clamp(v, d, lo, hi) {
	if (v == null || !match(v, /^[0-9]+$/)) return d;
	v = +v;
	return v < lo ? lo : (v > hi ? hi : int(v));
}

const uc = cursor();
const opt = (k) => uc.get('adblock-fast-monitor', 'config', k);
const RECENT = clamp(opt('recent_size'), 500, 50, 2000);
const TOP = clamp(opt('top_size'), 256, 32, 1024);
const PSIZE = clamp(opt('pending_size'), 512, 64, 4096);
const TTL = clamp(opt('pending_ttl'), 10, 2, 60);
const RECORD = opt('record_clients') == '1';
const EXCL = opt('exclude_router') != '0';

let started = time(), since = started, purged = null, last_event = null;
let C, recent, tops, pending;
function reset() {
	C = { queries: 0, blocked: 0, allowed: 0, other: 0, expired: 0, pending: 0,
		dropped: { input_overflow: 0, pending_evicted: 0, dnsmasq_reported: 0 }, rejected_lines: 0, orphan_lines: 0 };
	recent = {}; tops = { top_blocked: {}, top_allowed: {} }; pending = {};
}
reset();

const RE_PREFIX = regexp('^[A-Z][a-z]{2} [A-Z][a-z]{2} [ 0-9][0-9] [0-9]{2}:[0-9]{2}:[0-9]{2} [0-9]{4} [a-z0-9]+\\.[a-z]+ dnsmasq\\[([0-9]+)\\]: (.*)$');
const RE_BODY = regexp('^(TCP |UDP )?([0-9]+) ([^ /]+)/([0-9]+) ([^ ]+) ([a-z0-9_.-]+) (from|is|to) ([^ ]+)( \\([^()]*\\))?$');
const SINK = { 'NXDOMAIN': 1, 'NODATA': 1, 'NODATA-IPv4': 1, 'NODATA-IPv6': 1, '0.0.0.0': 1, '::': 1, '127.0.0.1': 1 };

function bump(map, d) {
	if (map[d]) { map[d].count++; return; }
	let keys = keys_(map);
	if (length(keys) >= TOP) {
		let min = null;
		for (let k in keys) if (min == null || map[k].count < map[min].count) min = k;
		let m = map[min]; delete map[min];
		map[d] = { count: m.count + 1, error: m.count };
	}
	else map[d] = { count: 1, error: 0 };
}
function keys_(o) { return keys(o); }

function decide(p, decision, source) {
	delete pending[p.key];
	C[decision]++;
	let r = recent[p.name];
	if (!r) {
		if (length(keys(recent)) >= RECENT) {
			let old = null;
			for (let k in keys(recent)) if (old == null || recent[k].last_seen < recent[old].last_seen) old = k;
			delete recent[old];
		}
		r = recent[p.name] = { domain: p.name, count: 0, blocked: 0, allowed: 0, first_seen: time(), qtypes: [] };
	}
	r.decision = decision; r.source = source; r.count++; r.last_seen = time();
	if (decision == 'blocked') r.blocked++;
	if (decision == 'allowed') r.allowed++;
	if (index(r.qtypes, p.qtype) < 0 && length(r.qtypes) < 8) push(r.qtypes, p.qtype);
	if (RECORD) r.client = p.client;
	if (decision == 'blocked') bump(tops.top_blocked, p.name);
	if (decision == 'allowed') bump(tops.top_allowed, p.name);
	last_event = time();
}

function line(l) {
	let m = match(l, RE_PREFIX);
	if (!m) return;
	let lost = match(m[2], /^overflow: ([0-9]+) log entries lost$/);
	if (lost) { C.dropped.dnsmasq_reported += +lost[1]; return; }
	let b = match(m[2], RE_BODY);
	if (!b) { C.rejected_lines++; return; }
	let key = m[1] + ':' + b[2], src = b[5], name = b[6], verb = b[7], ans = b[8];
	let q = match(src, /^query\[(.+)\]$/);
	if (q && verb == 'from') {
		if (EXCL && (b[3] == '127.0.0.1' || b[3] == '::1')) return;
		if (length(keys(pending)) >= PSIZE) {
			let old = null;
			for (let k in keys(pending)) if (old == null || pending[k].t < pending[old].t) old = k;
			delete pending[old]; C.dropped.pending_evicted++;
		}
		pending[key] = { key, name, qtype: q[1], client: b[3], t: time() };
		C.queries++;
		return;
	}
	if (verb != 'is') return;
	let p = pending[key];
	if (!p) { C.orphan_lines++; return; }
	if (src == 'config') decide(p, SINK[ans] ? 'blocked' : 'other', 'config');
	else if (src == '/var/run/adblock-fast/dnsmasq.addnhosts') decide(p, 'blocked', 'addnhosts');
	else if (substr(src, 0, 1) == '/') decide(p, 'other', 'hosts');
	else if (src == 'reply') {
		if (ans == 'duplicate') return;
		if (ans in [ 'SERVFAIL', 'REFUSED', 'FORMERR' ] || match(ans, /^[0-9]+$/)) decide(p, 'other', 'error');
		else decide(p, 'allowed', 'upstream');
	}
	else if (src == 'cached' || src == 'cached-stale') decide(p, 'allowed', 'cache');
	else if (src == 'DHCP') decide(p, 'other', 'dhcp');
	else if (src == 'auth') decide(p, 'other', 'auth');
}

function sweep() {
	let now = time();
	for (let k in keys(pending))
		if (now - pending[k].t >= TTL) { delete pending[k]; C.expired++; }
}

uloop.init();
const conn = connect();
const proc = popen("exec /sbin/logread -f -e '^dnsmasq\\['", 'r');
const rd = io.new(proc.fileno());
rd.fcntl(io.F_SETFL, rd.fcntl(io.F_GETFL) | io.O_NONBLOCK);
let buf = '';
uloop.handle(rd, () => {
	let chunk = rd.read(65536);
	if (chunk === '') { uloop.end(); return; }
	if (chunk == null) return;
	buf += chunk;
	let parts = split(buf, '\n');
	buf = pop(parts);
	for (let l in parts) line(l);
	sweep();
}, uloop.ULOOP_READ);
uloop.timer(2000, function() { sweep(); this.set(2000); });

function dnsmode() {
	let c = cursor();
	return c.get('adblock-fast', 'config', 'dns') ?? 'dnsmasq.servers';
}

function err(code, msg) { return { api: 1, ok: false, error: { code, message: msg } }; }

conn.publish('adblock-fast-monitor', {
	status: { args: {}, call: function() {
		try {
			let dns = dnsmode(), reasons = [];
			if (!(dns in [ 'dnsmasq.servers', 'dnsmasq.addnhosts', 'dnsmasq.conf' ])) push(reasons, 'dns-mode-unsupported');
			C.pending = length(keys(pending));
			let den = C.blocked + C.allowed;
			return { api: 1, ok: true, state: length(reasons) ? 'degraded' : 'running', reasons,
				daemon: { pid: getpid(), started_at: started, now: time(), stats_since: since, purged_at: purged },
				counters: C, block_pct: den ? round(1000 * C.blocked / den) / 10 : null, last_event_at: last_event,
				limits: { recent_size: RECENT, top_size: TOP, pending_size: PSIZE, pending_ttl: TTL },
				adblock_fast: { dns } };
		} catch (e) { return err('internal', '' + e); }
	} },
	domains: { args: { view: 'recent', decision: '', q: '', offset: 0, limit: 50 }, call: function(req) {
		try {
			let a = req.args, view = a.view ?? 'recent', q = a.q != null ? lc(a.q) : null;
			if (!(view in [ 'recent', 'top_blocked', 'top_allowed' ])) return err('invalid-argument', 'view');
			if (q != null && !match(q, /^[a-z0-9_.-]{1,64}$/)) return err('invalid-argument', 'q');
			let off = a.offset ?? 0, lim = a.limit ?? 50;
			lim = lim < 1 ? 1 : (lim > 100 ? 100 : lim);
			let items = [];
			if (view == 'recent') {
				for (let d, r in recent)
					if ((!a.decision || r.decision == a.decision) && (!q || index(d, q) >= 0)) push(items, r);
				items = sort(items, (x, y) => (y.last_seen - x.last_seen) || (x.domain < y.domain ? -1 : 1));
			}
			else {
				for (let d, r in tops[view])
					if (!q || index(d, q) >= 0) push(items, { domain: d, count: r.count, error: r.error });
				items = sort(items, (x, y) => (y.count - x.count) || (x.domain < y.domain ? -1 : 1));
			}
			return { api: 1, ok: true, view, total: length(items), offset: off, now: time(), stats_since: since,
				items: slice(items, off, off + lim) };
		} catch (e) { return err('internal', '' + e); }
	} },
	purge: { args: {}, call: function() {
		reset(); since = purged = time();
		return { api: 1, ok: true, stats_since: since };
	} }
});

uloop.run();
exit(1);
