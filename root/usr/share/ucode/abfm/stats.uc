// SPDX-License-Identifier: Apache-2.0
// Bounded in-RAM statistics for the monitor daemon (docs/CONTRACT.md §4.5,
// §4.6). Pure: the caller passes `now` (epoch seconds) everywhere.
//
// ucode objects iterate in insertion order and delete in O(1), so an object
// is an LRU/FIFO when entries are re-inserted on update and the first key is
// evicted. All operations on the hot path are O(1); only the `domains` read
// sorts (at most recent_size or top_size rows).
'use strict';

const logparse = require('abfm.logparse');

const LIMITS = {
	recent_size: [ 500, 50, 2000 ],
	top_size: [ 256, 32, 1024 ],
	pending_size: [ 512, 64, 4096 ],
	pending_ttl: [ 10, 2, 60 ]
};
const QTYPES_MAX = 8;
const REASON_WINDOW = 60;

const DECISIONS = { blocked: true, allowed: true, other: true };
const VIEWS = { recent: true, top_blocked: true, top_allowed: true };
const Q_RE = /^[a-z0-9_.-]{1,64}$/;

function first_key(obj) {
	for (let k in obj)
		return k;
	return null;
}

function zero_counters() {
	return {
		queries: 0, blocked: 0, allowed: 0, other: 0, expired: 0, pending: 0,
		dropped: { input_overflow: 0, pending_evicted: 0, dnsmasq_reported: 0 },
		rejected_lines: 0, orphan_lines: 0
	};
}

// Space-Saving with count buckets ("stream summary"): O(1) increment and
// O(1) replacement of a minimum entry.
function ss_new(size) {
	return { size, n: 0, min: 0, items: {}, buckets: {} };
}

function ss_bucket_del(ss, c, key) {
	let b = ss.buckets[c];
	delete b[key];
	if (first_key(b) == null)
		delete ss.buckets[c];
}

function ss_bucket_add(ss, c, key) {
	(ss.buckets[c] ??= {})[key] = true;
}

function ss_touch(ss, key) {
	let it = ss.items[key];

	if (it) {
		let c = it.count;
		ss_bucket_del(ss, c, key);
		it.count = c + 1;
		ss_bucket_add(ss, c + 1, key);
		if (c == ss.min && !ss.buckets[c])
			ss.min = c + 1;
		return it;
	}

	if (ss.n < ss.size) {
		it = ss.items[key] = { count: 1, error: 0 };
		ss.n++;
		ss_bucket_add(ss, 1, key);
		ss.min = 1;
		return it;
	}

	let min = ss.min;
	let victim = first_key(ss.buckets[min]);
	delete ss.items[victim];
	ss_bucket_del(ss, min, victim);
	it = ss.items[key] = { count: min + 1, error: min };
	ss_bucket_add(ss, min + 1, key);
	if (!ss.buckets[min])
		ss.min = min + 1;
	return it;
}

function clamp_int(v, def, lo, hi) {
	if (type(v) == 'string' && match(v, /^[0-9]+$/))
		v = +v;
	if (type(v) != 'int')
		return def;
	return v < lo ? lo : (v > hi ? hi : v);
}

// Normalises daemon options with the §3 clamping rules.
function limits(opts) {
	let out = {};
	for (let k, spec in LIMITS)
		out[k] = clamp_int(opts?.[k], spec[0], spec[1], spec[2]);
	return out;
}

function reset(st, now) {
	st.counters = zero_counters();
	st.pending = {};
	st.settled = {};
	st.settled_n = 0;
	st.recent = {};
	st.recent_n = 0;
	st.top_blocked = ss_new(st.limits.top_size);
	st.top_allowed = ss_new(st.limits.top_size);
	st.stats_since = now;
	st.purged_at = now;
	st.last_event_at = null;
	st.marks = { input_overflow: null, pending_evicted: null, dnsmasq_reported: null };
}

function create(opts, now) {
	let st = {
		limits: limits(opts),
		record_clients: !!opts?.record_clients,
		counters: null, pending: null, settled: null, settled_n: 0,
		recent: null, recent_n: 0, top_blocked: null, top_allowed: null,
		stats_since: now, purged_at: null, last_event_at: null,
		marks: { input_overflow: null, pending_evicted: null, dnsmasq_reported: null }
	};
	reset(st, now);
	st.purged_at = null;
	return st;
}

function settle(st, key, now) {
	let ttl = st.limits.pending_ttl;
	for (let k, t in st.settled) {
		if (st.settled_n < st.limits.pending_size && now - t < ttl)
			break;
		delete st.settled[k];
		st.settled_n--;
	}
	st.settled[key] = now;
	st.settled_n++;
}

// A query line: starts a pending entry. Returns true when counted.
function query(st, key, name, qtype, client, now) {
	let c = st.counters;
	if (st.pending[key] || st.settled[key] != null)
		return false;

	if (c.pending >= st.limits.pending_size) {
		delete st.pending[first_key(st.pending)];
		c.pending--;
		c.dropped.pending_evicted++;
		st.marks.pending_evicted = now;
	}

	st.pending[key] = { name, qtype, client, t: now };
	c.pending++;
	c.queries++;
	st.last_event_at = now;
	return true;
}

function recent_update(st, p, decision, source, now) {
	let name = p.name;
	let row = st.recent[name];

	if (row) {
		delete st.recent[name];
	}
	else {
		if (st.recent_n >= st.limits.recent_size) {
			delete st.recent[first_key(st.recent)];
			st.recent_n--;
		}
		row = { domain: name, decision, source, count: 0, blocked: 0, allowed: 0,
		        first_seen: now, last_seen: now, qtypes: [] };
		st.recent_n++;
	}

	row.decision = decision;
	row.source = source;
	row.count++;
	if (decision == 'blocked')
		row.blocked++;
	else if (decision == 'allowed')
		row.allowed++;
	row.last_seen = now;
	if (length(row.qtypes) < QTYPES_MAX && index(row.qtypes, p.qtype) < 0)
		push(row.qtypes, p.qtype);
	if (st.record_clients)
		row.client = p.client;

	st.recent[name] = row;
}

// A terminal line. The first one for a key decides; later ones are ignored.
// Returns 'decided', 'ignored' (already settled) or 'orphan'.
function decide(st, key, decision, source, now) {
	let c = st.counters;
	let p = st.pending[key];

	if (!p) {
		if (st.settled[key] != null)
			return 'ignored';
		c.orphan_lines++;
		return 'orphan';
	}

	delete st.pending[key];
	c.pending--;
	settle(st, key, now);

	c[decision]++;
	recent_update(st, p, decision, source, now);
	if (decision == 'blocked')
		ss_touch(st.top_blocked, p.name);
	else if (decision == 'allowed')
		ss_touch(st.top_allowed, p.name);

	st.last_event_at = now;
	return 'decided';
}

// Correlation key: serials are per dnsmasq instance, and every jailed
// instance logs as dnsmasq[1], so the client address/port is part of it.
function event_key(ev) {
	return `${ev.pid}:${ev.serial}:${ev.client}/${ev.port}`;
}

// Classifies (abfm.logparse) and applies one parsed event. Returns null
// (line ignored), 'pending', 'duplicate', 'decided', 'ignored' or 'orphan'.
function ingest(st, ev, ctx, now) {
	let key = event_key(ev);
	ctx.qname = st.pending[key]?.name;
	let cls = logparse.classify(ev, ctx);
	ctx.qname = null;
	if (!cls)
		return null;
	if (cls.kind == 'query')
		return query(st, key, ev.name, cls.qtype, ev.client, now) ? 'pending' : 'duplicate';
	return decide(st, key, cls.decision, cls.source, now);
}

// Removes pending entries whose age reached pending_ttl. Returns the number
// of seconds until the next expiry, or null when nothing is pending.
function sweep(st, now) {
	let c = st.counters, ttl = st.limits.pending_ttl;

	for (let k, p in st.pending) {
		let left = p.t + ttl - now;
		if (left > 0)
			return left;
		delete st.pending[k];
		c.pending--;
		c.expired++;
	}

	return null;
}

function input_overflow(st, now) {
	st.counters.dropped.input_overflow++;
	st.marks.input_overflow = now;
}

function note_lost(st, before, now) {
	if (st.counters.dropped.dnsmasq_reported != before)
		st.marks.dnsmasq_reported = now;
}

function block_pct(c) {
	let d = c.blocked + c.allowed;
	return d ? int(1000.0 * c.blocked / d + 0.5) / 10.0 : null;
}

// Degraded reasons owned by the statistics (§4.6), oldest first.
function reasons(st, now) {
	let out = [];
	for (let pair in [ [ 'input_overflow', 'input-overflow' ],
	                   [ 'pending_evicted', 'pending-overflow' ],
	                   [ 'dnsmasq_reported', 'dnsmasq-log-overflow' ] ]) {
		let t = st.marks[pair[0]];
		if (t != null && now - t < REASON_WINDOW)
			push(out, pair[1]);
	}
	return out;
}

function bad(message) {
	return { api: 1, ok: false, error: { code: 'invalid-argument', message } };
}

function by_recent(a, b) {
	if (a.last_seen != b.last_seen)
		return b.last_seen - a.last_seen;
	return a.domain < b.domain ? -1 : (a.domain > b.domain ? 1 : 0);
}

function by_count(a, b) {
	if (a.count != b.count)
		return b.count - a.count;
	return a.domain < b.domain ? -1 : (a.domain > b.domain ? 1 : 0);
}

// The `domains` read (§4.6). req fields are optional; wrong types or values
// give invalid-argument.
function domains(st, req, now) {
	req ??= {};
	let view = req.view ?? 'recent';
	if (type(view) != 'string' || !VIEWS[view])
		return bad('view must be one of recent, top_blocked, top_allowed');

	let decision = req.decision;
	if (decision != null && (type(decision) != 'string' || !DECISIONS[decision]))
		return bad('decision must be one of blocked, allowed, other');

	let q = req.q;
	if (q === '')
		q = null;
	if (q != null) {
		if (type(q) != 'string' || !match(lc(q), Q_RE))
			return bad('q must match ^[a-z0-9_.-]{1,64}$');
		q = lc(q);
	}

	let offset = req.offset ?? 0;
	if (type(offset) != 'int' || offset < 0)
		return bad('offset must be an integer >= 0');

	let limit = req.limit ?? 50;
	if (type(limit) != 'int')
		return bad('limit must be an integer');
	limit = limit < 1 ? 1 : (limit > 100 ? 100 : limit);

	let rows = [];
	if (view == 'recent') {
		for (let name, row in st.recent) {
			if (decision != null && row.decision != decision)
				continue;
			if (q != null && index(name, q) < 0)
				continue;
			push(rows, row);
		}
		sort(rows, by_recent);
	}
	else {
		let ss = view == 'top_blocked' ? st.top_blocked : st.top_allowed;
		for (let name, it in ss.items)
			if (q == null || index(name, q) >= 0)
				push(rows, { domain: name, count: it.count, error: it.error });
		sort(rows, by_count);
	}

	let items = [];
	for (let i = offset; i < length(rows) && i < offset + limit; i++) {
		let r = rows[i];
		if (view == 'recent') {
			let item = { domain: r.domain, decision: r.decision, source: r.source,
			             count: r.count, blocked: r.blocked, allowed: r.allowed,
			             first_seen: r.first_seen, last_seen: r.last_seen,
			             qtypes: [ ...r.qtypes ] };
			if (st.record_clients && r.client != null)
				item.client = r.client;
			push(items, item);
		}
		else {
			push(items, r);
		}
	}

	return { api: 1, ok: true, view, total: length(rows), offset, now,
	         stats_since: st.stats_since, items };
}

function snapshot_counters(st) {
	let c = st.counters;
	return {
		queries: c.queries, blocked: c.blocked, allowed: c.allowed, other: c.other,
		expired: c.expired, pending: c.pending,
		dropped: { ...c.dropped },
		rejected_lines: c.rejected_lines, orphan_lines: c.orphan_lines
	};
}

return {
	LIMITS,
	QTYPES_MAX,
	REASON_WINDOW,
	ss_touch,
	limits,
	reset,
	create,
	query,
	decide,
	event_key,
	ingest,
	sweep,
	input_overflow,
	note_lost,
	block_pct,
	reasons,
	domains,
	snapshot_counters
};
