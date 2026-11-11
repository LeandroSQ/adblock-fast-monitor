'use strict';
'require baseclass';

/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * Browser-side dnsmasq query log (docs/CONTRACT.md §8.1-§8.3):
 * turns replies of core `log read {lines, stream:false, oneshot:true}`
 * into a bounded list of recent queries. Pure logic: no DOM, no RPC, no
 * timers, so the same file is loaded unchanged by test/unit/querylog*.
 *
 *   create({max_rows=500 (<=500), pending_ttl_s=10, local_domains=[],
 *           hide_router=true}) -> state
 *   nextRequest(state) -> {lines}   900 first and after a gap or logd
 *       restart, the resume size once after resume(), else
 *       clamp(ceil(1.2 * last batch) + 16, 16, 900); never 0
 *   resume(state, polls) -> the page skipped `polls` polls (hidden or
 *       idle): the next request asks once for
 *       clamp(ceil(1.2 * last batch * polls) + 16, 16, 900) lines, and a gap
 *       that remains in that poll counts as `paused`, not `missed`.
 *   ingest(state, reply) -> {added, missed, paused, reset, refetch}
 *       reply: the `log read` result {log:[{msg, id, time (ms), ...}]}.
 *       added: query lines accepted; missed: log ids skipped (gap left after
 *       the refetch); paused: the same for the first poll after resume();
 *       reset: logd restarted (ids went backwards), rows kept, queries
 *       still waiting for an answer become no-answer; refetch: {lines} when
 *       a gap may be closed: nothing was taken from this reply, call
 *       `log read` once with these lines and ingest it.
 *   rows(state, {show_router}) -> newest first, at most max_rows:
 *       {key, time (epoch s), domain, qtype, answers (<=4), decision,
 *        source, client, router}
 *       decision: blocked | allowed | other | no-answer | pending;
 *       source: §8.3 attribution or null. key is opaque and unique
 *       (`epoch:pid:serial:client/port`, epoch = dnsmasq restarts seen).
 *       show_router defaults to !hide_router.
 *   stats(state, {show_router}) -> {kept, blocked, allowed, other,
 *       no_answer, pending, blocked_pct (null if blocked+allowed = 0),
 *       span_s, missed_total (gaps + dnsmasq_lost), dnsmasq_lost,
 *       paused_total, rejected,
 *       since_open: {queries, blocked, allowed}}  (since_open excludes
 *       router clients when hide_router)
 *
 * Every string in a row is the raw text dnsmasq logged; the UI must render
 * it as text only (PTR answers can carry HTML, §8).
 */

const LINES_MIN = 16;
const LINES_MAX = 900;          // keeps 1 KiB lines under ubus's 1 MiB cap
const ANSWERS_MAX = 4;
const ADDNHOSTS = '/var/run/adblock-fast/dnsmasq.addnhosts';

// §8.3: logd keeps the `dnsmasq[pid]: ` tag in `msg`; there is no ctime /
// facility prefix in `log read` replies.
const PREFIX = /^dnsmasq\[([0-9]+)\]: (.*)$/;
const BODY = /^(TCP |UDP )?([0-9]+) ([^ /]+)\/([0-9]+) ([^ ]+) ([a-z0-9_.:-]+) (from|is|to) ([^ ]+)( \([^()]*\))?$/;
const LOST = /^overflow: ([0-9]+) log entries lost$/;
const QUERY_LOG = /^(TCP |UDP )?[0-9]+ /;
const STARTED = /^started, version /;
const DIGITS = /^[0-9]+$/;
const ADDRESS = /^[0-9.]+$/;

// Special-use TLDs OpenWrt answers locally (rfc6761.conf); `test` is
// deliberately absent (fixtures use it for listed ad domains), §8.3.
const SPECIAL = { localhost: true, local: true, invalid: true, onion: true, bind: true, arpa: true };
const ROUTER = { '127.0.0.1': true, '::1': true };
const CONFIG_BLOCK = {
	'NXDOMAIN': true, 'NODATA': true, 'NODATA-IPv4': true, 'NODATA-IPv6': true,
	'0.0.0.0': true, '::': true, '127.0.0.1': true
};
const REPLY_ERROR = { 'SERVFAIL': true, 'REFUSED': true, 'FORMERR': true };

function clampLines(n) {
	return n < LINES_MIN ? LINES_MIN : (n > LINES_MAX ? LINES_MAX : n);
}

function under(name, domain) {
	return name === domain ||
		(name.length > domain.length && name.endsWith(domain) &&
		 name.charAt(name.length - domain.length - 1) === '.');
}

// §8.3 "local": single label, an address, a special-use TLD, or equal to /
// under a dhcp `domain` / `local` value (passed in by the UI from `info`).
function isLocal(name, localDomains) {
	const dot = name.lastIndexOf('.');
	if (dot < 0 || SPECIAL[name.substring(dot + 1)] === true || name.indexOf(':') >= 0)
		return true;
	if (ADDRESS.test(name))
		return true;
	for (let i = 0; i < localDomains.length; i++)
		if (localDomains[i] !== '' && under(name, localDomains[i]))
			return true;
	return false;
}

// Returns {pid, serial, client, port, source, name, verb, answer}, or a
// {lost:N} / {started:true} marker, or null (ignored); rejected query-log
// lines bump state.rejected (§8.3).
function parse(st, msg) {
	const m = PREFIX.exec(msg);
	if (!m)
		return null;
	const body = m[2];
	const b = BODY.exec(body);
	if (!b) {
		const lost = LOST.exec(body);
		if (lost)
			return { lost: +lost[1] };
		if (STARTED.test(body))
			return { started: true };
		if (QUERY_LOG.test(body))
			st.rejected++;
		return null;
	}
	return {
		pid: m[1], serial: b[2], client: b[3], port: b[4],
		source: b[5], name: b[6], verb: b[7], answer: b[8]
	};
}

// §8.3 table for terminal (`is`) lines: [decision, source] or null.
function classify(ev, qname, localDomains) {
	const src = ev.source, ans = ev.answer;

	if (src === 'config') {
		if (isLocal(qname, localDomains))
			return [ 'other', 'local' ];
		return [ CONFIG_BLOCK[ans] === true ? 'blocked' : 'other', 'config' ];
	}
	if (src === ADDNHOSTS)
		return [ 'blocked', 'addnhosts' ];
	if (src.charAt(0) === '/')
		return [ 'other', 'hosts' ];

	switch (src) {
	case 'DHCP':
		return [ 'other', 'dhcp' ];
	case 'reply':
		if (ans === 'duplicate')
			return null;
		if (REPLY_ERROR[ans] === true || DIGITS.test(ans))
			return [ 'other', 'error' ];
		return [ 'allowed', 'upstream' ];
	case 'cached':
	case 'cached-stale':
		return [ 'allowed', 'cache' ];
	case 'auth':
		return [ 'other', 'auth' ];
	}
	return null;
}

function count(st, e, decision) {
	if (e.router && st.hideRouter)
		return;
	if (decision === 'blocked')
		st.sinceOpen.blocked++;
	else if (decision === 'allowed')
		st.sinceOpen.allowed++;
}

// Pending entries older than the TTL (log time) get no answer.
function expire(st, timeMs) {
	const limit = timeMs - st.ttlMs;
	for (const [ k, e ] of st.pending) {
		if (e.timeMs > limit)
			break;
		st.pending.delete(k);
		e.decision = 'no-answer';
	}
}

// dnsmasq restarted (serials start again) or logd restarted (§8.1): nothing
// pending will be answered.
function dropPending(st) {
	for (const e of st.pending.values())
		e.decision = 'no-answer';
	st.pending.clear();
}

function restartDnsmasq(st) {
	dropPending(st);
	st.epoch++;
}

function addAnswer(e, value) {
	if (e.answers.length < ANSWERS_MAX && value !== e.domain && e.answers.indexOf(value) < 0)
		e.answers.push(value);
}

// One answer line of an entry: the first decides (§8.3); every line adds to
// the displayed answer. A `<CNAME>` answer is shown as the next name in the
// chain (the following line's name).
function answer(e, ev) {
	if (e.cname)
		addAnswer(e, ev.name);
	e.cname = ev.answer === '<CNAME>';
	if (!e.cname)
		addAnswer(e, ev.answer);
}

// logd always sends objects with numeric ids; anything else is skipped.
function idOf(entry) {
	return (entry !== null && typeof entry === 'object') ? +entry.id : NaN;
}

function line(st, entry) {
	if (entry === null || typeof entry !== 'object')
		return 0;
	const timeMs = +entry.time;
	if (timeMs === timeMs)
		expire(st, timeMs);

	const ev = parse(st, String(entry.msg));
	if (ev === null)
		return 0;
	if (ev.lost !== undefined) {
		// §8.3: dnsmasq's own lost lines are missed entries too.
		st.dnsmasqLost += ev.lost;
		st.missedTotal += ev.lost;
		return 0;
	}
	if (ev.started) {
		restartDnsmasq(st);
		return 0;
	}

	const key = st.epoch + ':' + ev.pid + ':' + ev.serial + ':' + ev.client + '/' + ev.port;

	if (ev.verb === 'from') {
		const src = ev.source, n = src.length;
		if (n < 8 || src.substring(0, 6) !== 'query[' || src.charAt(n - 1) !== ']')
			return 0;
		const qtype = src.substring(6, n - 1);
		if (qtype.indexOf(']') >= 0 || st.entries.has(key))
			return 0;
		const e = {
			key, timeMs, domain: ev.name, qtype, answers: [], cname: false,
			decision: 'pending', source: null, client: ev.client,
			router: ROUTER[ev.client] === true
		};
		st.entries.set(key, e);
		st.pending.set(key, e);
		if (st.entries.size > st.maxRows) {
			const oldest = st.entries.keys().next().value;
			st.entries.delete(oldest);
			st.pending.delete(oldest);
		}
		if (!(e.router && st.hideRouter))
			st.sinceOpen.queries++;
		return 1;
	}

	if (ev.verb !== 'is')
		return 0;
	const e = st.entries.get(key);
	if (e === undefined || e.decision === 'no-answer')
		return 0;      // orphan, or answered after the TTL
	const cls = classify(ev, e.domain, st.localDomains);
	if (cls === null)
		return 0;
	if (e.decision === 'pending') {
		e.decision = cls[0];
		e.source = cls[1];
		st.pending.delete(key);
		count(st, e, cls[0]);
	}
	answer(e, ev);
	return 0;
}

function visible(st, opts) {
	const show = opts && opts.show_router != null ? !!opts.show_router : !st.hideRouter;
	const out = [];
	for (const e of st.entries.values())
		if (show || !e.router)
			out.push(e);
	return out;
}

return baseclass.extend({
	LINES_MIN,
	LINES_MAX,
	ANSWERS_MAX,

	create(opts) {
		opts = opts || {};
		const maxRows = +opts.max_rows > 0 ? Math.min(+opts.max_rows | 0, 500) : 500;
		const ttl = +opts.pending_ttl_s > 0 ? +opts.pending_ttl_s : 10;
		return {
			maxRows, ttlMs: ttl * 1000,
			localDomains: Array.isArray(opts.local_domains)
				? opts.local_domains.filter((d) => typeof d === 'string').map((d) => d.toLowerCase())
				: [],
			hideRouter: opts.hide_router !== false,
			cursor: null,          // highest log id ingested
			lastBatch: null,       // new entries in the last reply; null before the first
			wantFull: false,       // ask for LINES_MAX after a gap or logd restart
			resumeLines: null,     // size of the first request after resume()
			refetching: false,     // the next reply answers a refetch
			epoch: 0,
			entries: new Map(),    // key -> entry, oldest first, at most maxRows
			pending: new Map(),    // subset of entries without an answer, oldest first
			missedTotal: 0, dnsmasqLost: 0, pausedTotal: 0, rejected: 0,
			sinceOpen: { queries: 0, blocked: 0, allowed: 0 }
		};
	},

	nextRequest(st) {
		if (st.lastBatch === null || st.wantFull)
			return { lines: LINES_MAX };
		if (st.resumeLines !== null)
			return { lines: st.resumeLines };
		return { lines: clampLines(Math.ceil(1.2 * st.lastBatch) + LINES_MIN) };
	},

	resume(st, polls) {
		const p = +polls > 1 ? +polls : 1;
		const n = st.lastBatch === null ? LINES_MAX : Math.ceil(1.2 * st.lastBatch * p) + LINES_MIN;
		st.resumeLines = clampLines(n === n ? n : LINES_MAX);
	},

	ingest(st, reply) {
		const log = reply && Array.isArray(reply.log) ? reply.log : [];
		const result = { added: 0, missed: 0, paused: 0, reset: false, refetch: null };
		const requested = st.refetching ? LINES_MAX : this.nextRequest(st).lines;
		const wasRefetch = st.refetching;
		const resuming = st.resumeLines !== null;
		st.refetching = false;

		if (log.length === 0) {
			st.lastBatch = 0;
			st.wantFull = false;
			st.resumeLines = null;
			return result;
		}

		const firstId = idOf(log[0]), lastId = idOf(log[log.length - 1]);
		let from = 0;

		if (st.cursor !== null && lastId < st.cursor) {
			// logd restarted (ids start again at 0): take the whole reply.
			result.reset = true;
			dropPending(st);
		}
		else if (st.cursor !== null) {
			if (firstId > st.cursor + 1) {
				if (!wasRefetch && requested < LINES_MAX) {
					st.refetching = true;
					result.refetch = { lines: Math.min(LINES_MAX, lastId - st.cursor + LINES_MIN) };
					return result;
				}
				const gap = firstId - st.cursor - 1;
				if (resuming) {
					result.paused = gap;
					st.pausedTotal += gap;
				}
				else {
					result.missed = gap;
					st.missedTotal += gap;
				}
			}
			while (from < log.length && idOf(log[from]) <= st.cursor)
				from++;
		}

		for (let i = from; i < log.length; i++)
			result.added += line(st, log[i]);

		if (lastId === lastId)
			st.cursor = lastId;
		st.lastBatch = log.length - from;
		st.wantFull = result.missed > 0 || result.reset;
		st.resumeLines = null;
		return result;
	},

	rows(st, opts) {
		const list = visible(st, opts);
		const out = new Array(list.length);
		for (let i = list.length - 1, j = 0; i >= 0; i--, j++) {
			const e = list[i];
			out[j] = {
				key: e.key,
				time: Math.floor(e.timeMs / 1000),
				domain: e.domain,
				qtype: e.qtype,
				answers: e.answers.length === 0 && e.cname ? [ '<CNAME>' ] : e.answers.slice(),
				decision: e.decision,
				source: e.source,
				client: e.client,
				router: e.router
			};
		}
		return out;
	},

	stats(st, opts) {
		const list = visible(st, opts);
		const s = {
			kept: list.length, blocked: 0, allowed: 0, other: 0, no_answer: 0, pending: 0,
			blocked_pct: null, span_s: 0,
			missed_total: st.missedTotal, dnsmasq_lost: st.dnsmasqLost, paused_total: st.pausedTotal,
			rejected: st.rejected,
			since_open: {
				queries: st.sinceOpen.queries, blocked: st.sinceOpen.blocked, allowed: st.sinceOpen.allowed
			}
		};
		for (const e of list) {
			if (e.decision === 'no-answer')
				s.no_answer++;
			else
				s[e.decision]++;
		}
		const d = s.blocked + s.allowed;
		if (d > 0)
			s.blocked_pct = Math.round(1000 * s.blocked / d) / 10;
		if (list.length > 1)
			s.span_s = Math.max(0, Math.round((list[list.length - 1].timeMs - list[0].timeMs) / 1000));
		return s;
	}
});
