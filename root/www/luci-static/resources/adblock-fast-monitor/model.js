'use strict';
'require baseclass';

/*
 * Pure UI logic for the Adblock Fast Monitor views (docs/CONTRACT.md §8):
 * RPC error mapping, UI state derivation (§8.1), the client-side staging
 * reducer (§8.2) and display formatting. No DOM, no RPC, no timers, so the
 * same file is loaded unchanged by the host unit tests.
 */

const STORAGE_KEY = 'adblock-fast-monitor.pending.v1';
const MAX_PENDING = 64;
const OPS = [ 'allow', 'unblock', 'block', 'unallow' ];
const INVERSE = { allow: 'unallow', unallow: 'allow', block: 'unblock', unblock: 'block' };
const TERMINAL_JOB = { applied: true, partial: true, failed: true };
const LEAVES_PENDING = { ok: true, skipped: true };
const STARTING_GRACE = 15;
const OBJECT_MISSING = -32000;
const ACCESS_DENIED = -32002;

function isObject(value) {
	return value != null && typeof(value) == 'object' && !Array.isArray(value);
}

function int(value, fallback) {
	const n = Number(value);
	return (typeof(value) != 'boolean' && value !== '' && value != null && isFinite(n)) ? Math.floor(n) : fallback;
}

/* §3: out-of-range values clamp, unparsable values fall back to the default. */
function clampOption(value, def, min, max) {
	const n = int(value, null);
	if (n == null)
		return def;
	return Math.min(max, Math.max(min, n));
}

function pollInterval(value) {
	return clampOption(value, 5, 2, 60);
}

/*
 * LuCI's rpc.js rejects with an Error whose message carries the JSON-RPC or
 * ubus code ("... failed with error -32000: Object not found",
 * "... failed with ubus code 7: ..."). Returns {rpc, ubus, message}.
 */
function rpcError(err) {
	const message = (err && err.message != null) ? String(err.message) : String(err);
	let m = /failed with error (-?\d+)/.exec(message);
	const out = { rpc: null, ubus: null, message: message };
	if (m)
		out.rpc = +m[1];
	else if ((m = /failed with ubus code (\d+)/.exec(message)) != null)
		out.ubus = +m[1];
	return out;
}

/*
 * §6.4 normalization and grammar. Returns the normalized name or null.
 * The server re-validates everything; this keeps junk out of storage.
 */
function normalizeDomain(input) {
	if (typeof(input) != 'string')
		return null;
	let d = input.trim().toLowerCase();
	if (d.length && d.charAt(d.length - 1) == '.')
		d = d.substring(0, d.length - 1);
	if (!d.length || d.length > 253)
		return null;
	const labels = d.split('.');
	if (labels.length < 2 || labels.length > 127)
		return null;
	for (let i = 0; i < labels.length; i++)
		if (!/^[a-z0-9_]([a-z0-9_-]{0,61}[a-z0-9_])?$/.test(labels[i]))
			return null;
	if (/^[0-9]+$/.test(labels[labels.length - 1]))
		return null;
	return d;
}

/* §4.6 `q`: lower-cased, ^[a-z0-9_.-]{1,64}$. '' means no filter, null invalid. */
function searchQuery(input) {
	const q = String(input == null ? '' : input).trim().toLowerCase();
	if (q == '')
		return '';
	return /^[a-z0-9_.-]{1,64}$/.test(q) ? q : null;
}

/* ---- §8.1 state derivation ---------------------------------------------- */

/*
 * Wraps an RPC promise outcome into a plain result:
 *   {ok:true, data}  or  {ok:false, rpc, ubus, message}
 */
function settle(data) {
	return { ok: true, data: data };
}

function failure(err) {
	const e = rpcError(err);
	return { ok: false, rpc: e.rpc, ubus: e.ubus, message: e.message };
}

/*
 * Tracks when the monitor object was first seen missing, so `starting` can
 * time out. Returns the epoch (s) of the first -32000 in the current run of
 * missing results, or null when the object is present.
 */
function missingSince(previousSince, statusResult, now) {
	if (statusResult && !statusResult.ok && statusResult.rpc === OBJECT_MISSING)
		return (previousSince != null) ? previousSince : now;
	return null;
}

function loggingReason(info) {
	const dnsmasq = isObject(info) ? info.dnsmasq : null;
	if (!isObject(dnsmasq))
		return null;
	if (dnsmasq.running === false)
		return 'dnsmasq-not-running';
	const instances = Array.isArray(dnsmasq.instances) ? dnsmasq.instances : [];
	if (instances.some(i => isObject(i) && i.logfacility_file === true))
		return 'dnsmasq-logs-to-file';
	if (!instances.some(i => isObject(i) && (i.dropin === true || i.uci_logqueries === true))) {
		if (instances.some(i => isObject(i) && (typeof(i.confdir) != 'string' || i.confdir.charAt(0) != '/')))
			return 'confdir-invalid';
		return 'logging-not-active';
	}
	return null;
}

/*
 * deriveState(uciEnabled, infoResult, statusResult, now, since)
 *   infoResult / statusResult: settle()/failure() shapes (or null if not yet
 *   loaded); since: missingSince() value. Returns {state, reasons, message}.
 *   The first matching row of §8.1 wins.
 */
function deriveState(uciEnabled, infoResult, statusResult, now, since) {
	const info = (infoResult && infoResult.ok && isObject(infoResult.data)) ? infoResult.data : null;
	const status = (statusResult && statusResult.ok && isObject(statusResult.data)) ? statusResult.data : null;

	if (infoResult && !infoResult.ok && infoResult.rpc === ACCESS_DENIED)
		return { state: 'access-denied', reasons: [] };

	if (info && isObject(info.adblock_fast) && info.adblock_fast.installed === false)
		return { state: 'adblock-fast-missing', reasons: [] };

	if (!uciEnabled)
		return { state: 'disabled', reasons: [] };

	if (statusResult && !statusResult.ok && statusResult.rpc === OBJECT_MISSING) {
		const svc = (info && isObject(info.monitor) && isObject(info.monitor.service)) ? info.monitor.service : null;
		const first = (since != null) ? since : now;
		if (svc && svc.running === true && (now - first) < STARTING_GRACE)
			return { state: 'starting', reasons: [] };
		return { state: 'not-running', reasons: [] };
	}

	if (status) {
		const reason = loggingReason(info);
		if (reason)
			return { state: 'logging-unavailable', reasons: [ reason ] };
		if (status.state == 'degraded')
			return { state: 'degraded', reasons: Array.isArray(status.reasons) ? status.reasons.map(String) : [] };
		return { state: 'healthy', reasons: [] };
	}

	if (statusResult && !statusResult.ok)
		return { state: 'error', reasons: [], message: statusResult.message };

	return { state: 'loading', reasons: [] };
}

/* Overlay: the last successful status is older than 3 × poll_interval. */
function isStale(lastOkAt, now, interval) {
	return lastOkAt != null && (now - lastOkAt) > 3 * pollInterval(interval);
}

function stateSeverity(state) {
	switch (state) {
	case 'healthy': return 'success';
	case 'disabled':
	case 'starting':
	case 'loading': return 'notice';
	case 'logging-unavailable':
	case 'degraded': return 'warning';
	default: return 'danger';
	}
}

/* Rows show actions only for a known rule, in contract order (§6.2). */
function rowActions(rule) {
	if (!isObject(rule) || !Array.isArray(rule.actions))
		return [];
	return OPS.filter(op => rule.actions.indexOf(op) >= 0);
}

/* ---- §8.2 staging reducer ------------------------------------------------ */

function emptyPending() {
	return { v: 1, items: [], inflight: null };
}

function cleanItem(item) {
	if (!isObject(item) || OPS.indexOf(item.op) < 0)
		return null;
	const domain = normalizeDomain(item.domain);
	if (!domain)
		return null;
	const out = { op: item.op, domain: domain, ts: int(item.ts, 0) };
	if (typeof(item.reason) == 'string' && item.reason.length)
		out.reason = item.reason.substring(0, 64);
	return out;
}

function cleanList(list, limit) {
	const out = [], seen = {};
	for (let i = 0; Array.isArray(list) && i < list.length && out.length < limit; i++) {
		const item = cleanItem(list[i]);
		if (item && !seen[item.domain]) {
			seen[item.domain] = true;
			out.push(item);
		}
	}
	return out;
}

/* Parses stored JSON; anything malformed degrades to an empty list. */
function parsePending(json) {
	let raw = null;
	try { raw = (typeof(json) == 'string') ? JSON.parse(json) : json; }
	catch (e) { raw = null; }
	if (!isObject(raw) || raw.v !== 1)
		return emptyPending();
	const state = emptyPending();
	state.items = cleanList(raw.items, MAX_PENDING);
	if (isObject(raw.inflight) && typeof(raw.inflight.job_id) == 'string' && /^j[0-9]{10}-[0-9a-f]{4}$/.test(raw.inflight.job_id))
		state.inflight = { job_id: raw.inflight.job_id, items: cleanList(raw.inflight.items, MAX_PENDING) };
	return state;
}

function serializePending(state) {
	const out = { v: 1, items: state.items };
	if (state.inflight)
		out.inflight = state.inflight;
	return JSON.stringify(out);
}

/*
 * Adds op for domain: replaces any pending op for that domain, and the
 * inverse of a pending op cancels it. Returns {state, change, error}.
 * change: 'added' | 'replaced' | 'cancelled' | 'unchanged'.
 */
function stage(state, op, domain, ts) {
	if (OPS.indexOf(op) < 0)
		return { state: state, error: 'invalid-op' };
	const d = normalizeDomain(domain);
	if (!d)
		return { state: state, error: 'invalid-domain' };
	const items = state.items.slice();
	const idx = items.findIndex(i => i.domain == d);
	let change;
	if (idx >= 0) {
		if (items[idx].op == op)
			return { state: state, change: 'unchanged' };
		if (INVERSE[items[idx].op] == op) {
			items.splice(idx, 1);
			change = 'cancelled';
		}
		else {
			items[idx] = { op: op, domain: d, ts: ts };
			change = 'replaced';
		}
	}
	else {
		if (items.length >= MAX_PENDING)
			return { state: state, error: 'too-many' };
		items.push({ op: op, domain: d, ts: ts });
		change = 'added';
	}
	return { state: Object.assign({}, state, { items: items }), change: change };
}

function unstage(state, domain) {
	return Object.assign({}, state, { items: state.items.filter(i => i.domain != domain) });
}

function discard(state) {
	return Object.assign({}, state, { items: [] });
}

function pendingOp(state, domain) {
	const item = state.items.find(i => i.domain == domain);
	return item ? item.op : null;
}

function toOps(state) {
	return state.items.map(i => ({ op: i.op, domain: i.domain }));
}

/* Marks the item named by an apply error (error.domain) with its code. */
function markError(state, error) {
	if (!isObject(error) || typeof(error.domain) != 'string')
		return state;
	const d = normalizeDomain(error.domain);
	return Object.assign({}, state, {
		items: state.items.map(i => (i.domain == d) ? Object.assign({}, i, { reason: String(error.code || 'error') }) : i)
	});
}

/* After `apply` returns queued: the whole batch moves to inflight{job_id}. */
function beginInflight(state, jobId) {
	return Object.assign({}, state, {
		items: [],
		inflight: { job_id: jobId, items: state.items.map(i => ({ op: i.op, domain: i.domain, ts: i.ts })) }
	});
}

/* A noop apply: nothing changes on the router, every item leaves. */
function settleNoop(state) {
	return Object.assign({}, state, { items: [] });
}

function isTerminal(job) {
	return isObject(job) && TERMINAL_JOB[job.state] === true;
}

/*
 * Applies a terminal job to the inflight batch. Items whose result is ok or
 * skipped (or whose job ended applied without a per-item entry) leave;
 * everything else returns to pending with a reason, unless the user staged
 * something newer for the same domain meanwhile.
 * Returns {state, done:[domain], returned:[domain]}.
 */
function settleJob(state, job) {
	const inflight = state.inflight;
	if (!inflight || !isTerminal(job) || job.id !== inflight.job_id)
		return { state: state, done: [], returned: [] };
	const byDomain = {};
	(Array.isArray(job.items) ? job.items : []).forEach(it => {
		if (isObject(it) && typeof(it.domain) == 'string')
			byDomain[it.domain] = it;
	});
	const items = state.items.slice();
	const done = [], returned = [];
	const jobError = isObject(job.error) ? String(job.error.code || 'failed') : null;
	inflight.items.forEach(item => {
		const it = byDomain[item.domain];
		let ok, reason = null;
		if (job.state == 'failed') {
			ok = false;
			reason = jobError || 'failed';
		}
		else if (it) {
			ok = LEAVES_PENDING[it.result] === true;
			reason = it.reason || it.result || 'failed';
		}
		else {
			ok = (job.state == 'applied');
			reason = job.state;
		}
		if (ok) {
			done.push(item.domain);
		}
		else {
			returned.push(item.domain);
			if (!items.some(i => i.domain == item.domain) && items.length < MAX_PENDING)
				items.push({ op: item.op, domain: item.domain, ts: item.ts, reason: String(reason) });
		}
	});
	return { state: Object.assign({}, state, { items: items, inflight: null }), done: done, returned: returned };
}

/* Drops the inflight batch back into pending (e.g. user dismisses a failed job). */
function returnInflight(state, reason) {
	if (!state.inflight)
		return state;
	const items = state.items.slice();
	state.inflight.items.forEach(item => {
		if (!items.some(i => i.domain == item.domain) && items.length < MAX_PENDING)
			items.push({ op: item.op, domain: item.domain, ts: item.ts, reason: reason || 'failed' });
	});
	return Object.assign({}, state, { items: items, inflight: null });
}

/* Dry-run reply → what the confirmation must say (§6.6, §8.2 step 1). */
function applyPlan(reply) {
	const mode = isObject(reply) ? reply.mode : null;
	const plan = (isObject(reply) && Array.isArray(reply.plan)) ? reply.plan : [];
	const noop = isObject(reply) && (reply.noop === true ||
		(plan.length > 0 && plan.every(p => Array.isArray(p.change) && p.change.length == 0)));
	return {
		mode: mode || null,
		mayEscalate: isObject(reply) && reply.may_escalate === true,
		needsConfirm: !noop && (mode == 'rebuild' || (isObject(reply) && reply.may_escalate === true)),
		noop: noop,
		plan: plan
	};
}

/* ---- display formatting --------------------------------------------------- */

function formatCount(n) {
	n = int(n, 0);
	return String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ',');
}

function formatPct(pct) {
	return (typeof(pct) == 'number' && isFinite(pct)) ? pct.toFixed(1) + ' %' : '—';
}

/* Humanized duration: "45 s", "3 min", "2 h 5 min", "3 d 4 h". */
function formatDuration(seconds) {
	let s = Math.max(0, int(seconds, 0));
	if (s < 60) return s + ' s';
	const m = Math.floor(s / 60);
	if (m < 60) return m + ' min';
	const h = Math.floor(m / 60);
	if (h < 24) return (m % 60) ? h + ' h ' + (m % 60) + ' min' : h + ' h';
	const d = Math.floor(h / 24);
	return (h % 24) ? d + ' d ' + (h % 24) + ' h' : d + ' d';
}

/* Local wall-clock time of an epoch (s): "2026-11-10 12:03:04". */
function formatTime(epoch) {
	const n = int(epoch, null);
	if (n == null || n <= 0)
		return '—';
	const d = new Date(n * 1000);
	const p = v => (v < 10 ? '0' : '') + v;
	return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()) + ' ' +
		p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds());
}

function sumDrops(counters) {
	const d = (isObject(counters) && isObject(counters.dropped)) ? counters.dropped : {};
	return int(d.input_overflow, 0) + int(d.pending_evicted, 0) + int(d.dnsmasq_reported, 0);
}

/* "21–40 of 137" style paging info for offset/limit/total. */
function pageInfo(total, offset, limit) {
	total = Math.max(0, int(total, 0));
	offset = Math.max(0, int(offset, 0));
	limit = Math.max(1, int(limit, 1));
	return {
		first: total ? offset + 1 : 0,
		last: Math.min(total, offset + limit),
		total: total,
		hasPrev: offset > 0,
		hasNext: offset + limit < total,
		prevOffset: Math.max(0, offset - limit),
		nextOffset: offset + limit
	};
}

return baseclass.extend({
	STORAGE_KEY: STORAGE_KEY,
	MAX_PENDING: MAX_PENDING,
	OPS: OPS,
	INVERSE: INVERSE,
	OBJECT_MISSING: OBJECT_MISSING,
	ACCESS_DENIED: ACCESS_DENIED,
	clampOption: clampOption,
	pollInterval: pollInterval,
	rpcError: rpcError,
	normalizeDomain: normalizeDomain,
	searchQuery: searchQuery,
	settle: settle,
	failure: failure,
	missingSince: missingSince,
	loggingReason: loggingReason,
	deriveState: deriveState,
	isStale: isStale,
	stateSeverity: stateSeverity,
	rowActions: rowActions,
	emptyPending: emptyPending,
	parsePending: parsePending,
	serializePending: serializePending,
	stage: stage,
	unstage: unstage,
	discard: discard,
	pendingOp: pendingOp,
	toOps: toOps,
	markError: markError,
	beginInflight: beginInflight,
	settleNoop: settleNoop,
	isTerminal: isTerminal,
	settleJob: settleJob,
	returnInflight: returnInflight,
	applyPlan: applyPlan,
	formatCount: formatCount,
	formatPct: formatPct,
	formatDuration: formatDuration,
	formatTime: formatTime,
	sumDrops: sumDrops,
	pageInfo: pageInfo
});
