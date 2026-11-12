'use strict';
'require baseclass';

/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * Pure UI logic for the Adblock Fast Monitor views (docs/CONTRACT.md §8):
 * RPC error mapping, the page state (§8.5), view options from `info`, the
 * client-side staging reducer (§8.4) and display formatting. No DOM, no
 * RPC, no timers, so the same file is loaded unchanged by the host unit tests.
 */

const STORAGE_KEY = 'adblock-fast-monitor.pending.v2';
const STORAGE_VERSION = 2;
const MAX_PENDING = 64;
/* The UI stages only allow and block; plan() maps them to UCI changes (§6.6). */
const OPS = [ 'allow', 'block' ];
/* Row button per decision: Allow on blocked rows, Block on allowed rows. */
const ROW_OP = { blocked: 'allow', allowed: 'block' };
const TERMINAL_JOB = { applied: true, partial: true, failed: true };
/* §8.1: the page polls `log read` every 2 s while visible (fixed, no option). */
const POLL_INTERVAL = 2;
/*
 * §6.5 names the server always refuses to block. The server's full list
 * (plus dhcp names, hostname, heartbeat) comes as info.protected_suffixes.
 */
const BUILTIN_PROTECTED = [ 'localhost', 'arpa', 'local', 'internal', 'invalid', 'onion', 'bind' ];
/* adblock-fast `dns` modes whose block decisions the log cannot show (§8.3). */
const FIREWALL_DNS = { 'dnsmasq.ipset': true, 'dnsmasq.nftset': true };
const UNSUPPORTED_DNS = /^(smartdns|unbound)\./;
/* After n failed `log read`s in a row the next try waits 2^n polls (4, 8, 16, then 32 s). */
const BACKOFF_MAX_SKIP = 15;
const LEAVES_PENDING = { ok: true, skipped: true };
const ACCESS_DENIED = -32002;

function isObject(value) {
	return value != null && typeof(value) == 'object' && !Array.isArray(value);
}

function int(value, fallback) {
	const n = Number(value);
	return (typeof(value) != 'boolean' && value !== '' && value != null && isFinite(n)) ? Math.floor(n) : fallback;
}

/*
 * LuCI's rpc.js rejects with an Error whose message carries the JSON-RPC or
 * ubus code ("... failed with error -32002: Access denied",
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

function settle(data) {
	return { ok: true, data: data };
}

function failure(err) {
	const e = rpcError(err);
	return { ok: false, rpc: e.rpc, ubus: e.ubus, message: e.message };
}

function infoData(infoResult) {
	return (infoResult && infoResult.ok && isObject(infoResult.data)) ? infoResult.data : null;
}

/*
 * §8.5 page state, first match wins. infoResult and logResult are
 * settle()/failure() shapes or null (not loaded yet); hasRows tells whether
 * an earlier `log read` delivered data. Returns {state, reason}.
 */
function pageState(infoResult, logResult, hasRows) {
	if (infoResult && !infoResult.ok && infoResult.rpc === ACCESS_DENIED)
		return { state: 'access-denied', reason: null };
	const info = infoData(infoResult);
	if (info) {
		if (isObject(info.adblock_fast) && info.adblock_fast.installed === false)
			return { state: 'adblock-fast-missing', reason: null };
		const mon = isObject(info.monitor) ? info.monitor : {};
		const dnsmasq = isObject(info.dnsmasq) ? info.dnsmasq : {};
		const instances = Array.isArray(dnsmasq.instances) ? dnsmasq.instances.filter(isObject) : [];
		if (mon.query_logging === false && !instances.some(i => i.uci_logqueries === true))
			return { state: 'logging-off', reason: null };
		if (dnsmasq.running === false)
			return { state: 'logging-unavailable', reason: 'dnsmasq-not-running' };
		if (instances.some(i => i.logfacility_file === true))
			return { state: 'logging-unavailable', reason: 'dnsmasq-logs-to-file' };
		if (!instances.some(i => i.uci_logqueries === true || i.dropin === true))
			return { state: 'logging-unavailable',
				reason: instances.some(i => typeof(i.confdir) != 'string' || i.confdir.charAt(0) != '/')
					? 'confdir-invalid' : 'logging-not-active' };
	}
	if (logResult && !logResult.ok && !hasRows)
		return { state: 'error', reason: null };
	if (!logResult)
		return { state: 'loading', reason: null };
	return { state: 'healthy', reason: null };
}

/* Query logging is on but was not turned on by this app (dnsmasq `logqueries`). */
function loggingElsewhere(infoResult) {
	const info = infoData(infoResult);
	const instances = (info && isObject(info.dnsmasq) && Array.isArray(info.dnsmasq.instances)) ? info.dnsmasq.instances : [];
	return instances.some(i => isObject(i) && i.uci_logqueries === true);
}

/*
 * Names a `block` would be refused for (§6.5), matched equal-or-under: the
 * builtin list, info.local_domains and info.protected_suffixes. The exact
 * list hosts of §6.5 are not included; the server still refuses those.
 */
function protectedNames(infoResult) {
	const info = infoData(infoResult);
	const out = BUILTIN_PROTECTED.slice();
	const add = list => (Array.isArray(list) ? list : []).forEach(d => {
		if (typeof(d) == 'string' && d.length > 0 && out.indexOf(d.toLowerCase()) < 0)
			out.push(d.toLowerCase());
	});
	if (info) {
		add(info.local_domains);
		add(info.protected_suffixes);
	}
	return out;
}

function under(name, parent) {
	return name == parent || (name.length > parent.length &&
		name.substring(name.length - parent.length - 1) == '.' + parent);
}

/* True when the server would refuse to block this (normalized) name. */
function isProtected(names, domain) {
	return Array.isArray(names) && typeof(domain) == 'string' && names.some(p => under(domain, p));
}

/*
 * What the page must say about adblock-fast's DNS mode: 'firewall' (ipset /
 * nftset: blocking happens in the firewall, the log shows every answer as
 * allowed), 'unsupported' (smartdns / unbound: dnsmasq does not see the
 * rules), or null.
 */
function dnsModeNote(infoResult) {
	const info = infoData(infoResult);
	const dns = (info && isObject(info.adblock_fast) && typeof(info.adblock_fast.dns) == 'string') ? info.adblock_fast.dns : null;
	if (dns == null)
		return null;
	if (FIREWALL_DNS[dns] === true)
		return 'firewall';
	if (UNSUPPORTED_DNS.test(dns))
		return 'unsupported';
	return null;
}

/* Polls to skip after `failures` failed `log read`s in a row: 0, 1, 3, 7, 15 (cap). */
function backoffSkip(failures) {
	const n = int(failures, 0);
	return n <= 0 ? 0 : Math.min(BACKOFF_MAX_SKIP, Math.pow(2, Math.min(n, 5) - 1) * 2 - 1);
}

const LOG_STALL_GRACE = 20;

function hasDnsmasqLine(reply) {
	const log = (isObject(reply) && Array.isArray(reply.log)) ? reply.log : [];
	for (let i = 0; i < log.length; i++)
		if (isObject(log[i]) && typeof(log[i].msg) == 'string' && log[i].msg.indexOf('dnsmasq[') == 0)
			return true;
	return false;
}

/*
 * Tracks whether dnsmasq has logged anything since logd restarted (ingest
 * reported `reset`). replies: the `log read` replies of one poll (the
 * refetch included); now: epoch s. Returns the new watch {resetAt}; resetAt
 * is null when no restart is pending. Replies are scanned only right after a
 * reset or while one is pending, so normal polls cost nothing.
 */
function logWatch(prev, replies, reset, now) {
	const pending = isObject(prev) && prev.resetAt != null;
	if (!reset && !pending)
		return { resetAt: null };
	const seen = (Array.isArray(replies) ? replies : []).some(hasDnsmasqLine);
	if (seen)
		return { resetAt: null };
	return { resetAt: reset ? now : prev.resetAt };
}

/* logd restarted at least LOG_STALL_GRACE s ago and dnsmasq has been silent since. */
function logStalled(watch, now) {
	return isObject(watch) && watch.resetAt != null && (now - watch.resetAt) >= LOG_STALL_GRACE;
}

/* dhcp `domain`/`local` names from `info.local_domains`, for querylog.create(). */
function localDomains(infoResult) {
	const info = infoData(infoResult);
	const list = (info && Array.isArray(info.local_domains)) ? info.local_domains : [];
	return list.filter(d => typeof(d) == 'string' && d.length > 0);
}

/* The staging op a row offers for its decision, or null. */
function rowOp(decision) {
	return Object.prototype.hasOwnProperty.call(ROW_OP, decision) ? ROW_OP[decision] : null;
}

/* ---- §8.2 staging reducer ------------------------------------------------ */

function emptyPending() {
	return { v: STORAGE_VERSION, items: [], inflight: null };
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
	let raw;
	try {
		raw = (typeof(json) == 'string') ? JSON.parse(json) : json;
	}
	catch (e) {
		raw = null;
	}
	if (!isObject(raw) || raw.v !== STORAGE_VERSION)
		return emptyPending();
	const state = emptyPending();
	state.items = cleanList(raw.items, MAX_PENDING);
	if (isObject(raw.inflight) && typeof(raw.inflight.job_id) == 'string' && /^j[0-9]{10}-[0-9a-f]{4}$/.test(raw.inflight.job_id))
		state.inflight = { job_id: raw.inflight.job_id, items: cleanList(raw.inflight.items, MAX_PENDING) };
	return state;
}

function serializePending(state) {
	const out = { v: STORAGE_VERSION, items: state.items };
	if (state.inflight)
		out.inflight = state.inflight;
	return JSON.stringify(out);
}

/*
 * Adds op for domain: replaces any pending op for that domain; the same op
 * again removes it (§8.4). names (protectedNames()) refuses a block the
 * server would refuse. Returns {state, change, error};
 * change: 'added' | 'replaced' | 'cancelled'.
 */
function stage(state, op, domain, ts, names) {
	if (OPS.indexOf(op) < 0)
		return { state: state, error: 'invalid-op' };
	const d = normalizeDomain(domain);
	if (!d)
		return { state: state, error: 'invalid-domain' };
	if (op == 'block' && names && isProtected(names, d))
		return { state: state, error: 'protected-domain' };
	const items = state.items.slice();
	const idx = items.findIndex(i => i.domain == d);
	let change;
	if (idx >= 0) {
		if (items[idx].op == op) {
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

function sentOps(state, ops) {
	return Array.isArray(ops) ? ops.filter(o => isObject(o) && typeof(o.domain) == 'string') : toOps(state);
}

/* Pending items that are not exactly one of the sent ops stay pending. */
function withoutSent(items, sent) {
	return items.filter(i => !sent.some(o => o.domain == i.domain && o.op == i.op));
}

/*
 * After `apply` returns queued: exactly the ops that were sent move to
 * inflight{job_id}. Anything staged, replaced or added since the request
 * (in this tab or another one) stays pending. ops defaults to the whole list.
 */
function beginInflight(state, jobId, ops) {
	const sent = sentOps(state, ops);
	return Object.assign({}, state, {
		items: withoutSent(state.items, sent),
		inflight: { job_id: jobId, items: sent.map(o => {
			const it = state.items.find(i => i.domain == o.domain && i.op == o.op);
			return { op: o.op, domain: o.domain, ts: it ? it.ts : 0 };
		}) }
	});
}

/* A noop apply: nothing changes on the router; the sent items leave, newer ones stay. */
function settleNoop(state, ops) {
	return Object.assign({}, state, { items: withoutSent(state.items, sentOps(state, ops)) });
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
		let ok, reason;
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
		needsConfirm: !noop && mode == 'rebuild',
		noop: noop,
		plan: plan
	};
}

/* ---- display formatting --------------------------------------------------- */

/* %s and %% only; does not depend on LuCI's String.prototype.format. */
function fmt(template) {
	let i = 1;
	const args = arguments;
	return String(template).replace(/%(s|%)/g, (m, c) => (c == '%') ? '%' : String(args[i++]));
}

function formatCount(n) {
	n = int(n, 0);
	return String(n).replace(/\B(?=(\d{3})+(?!\d))/g, _(',', 'thousands separator'));
}

/* Whole percent ("33 %"); "<1 %" for a small non-zero share; "—" without data. */
function formatPct(pct) {
	if (typeof(pct) != 'number' || !isFinite(pct))
		return '—';
	return (pct > 0 && pct < 1) ? fmt(_('<%s %%'), 1) : fmt(_('%s %%'), Math.round(pct));
}

/* Humanized duration: "45 s", "3 min", "2 h 5 min", "3 d 4 h". */
function formatDuration(seconds) {
	let s = Math.max(0, int(seconds, 0));
	if (s < 60) return fmt(_('%s s'), s);
	const m = Math.floor(s / 60);
	if (m < 60) return fmt(_('%s min'), m);
	const h = Math.floor(m / 60);
	if (h < 24) return (m % 60) ? fmt(_('%s h %s min'), h, m % 60) : fmt(_('%s h'), h);
	const d = Math.floor(h / 24);
	return (h % 24) ? fmt(_('%s d %s h'), d, h % 24) : fmt(_('%s d'), d);
}

/* Local clock time of an epoch (s): "12:03:04"; the list only shows the last minutes. */
function formatClock(epoch) {
	const n = int(epoch, null);
	if (n == null || n <= 0)
		return '—';
	const d = new Date(n * 1000);
	const p = v => (v < 10 ? '0' : '') + v;
	return p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds());
}

/*
 * The statistics of the page and of the Status → Overview include, from
 * querylog.stats(): {pct (number or null), value ("33 %", or null when not
 * shown), label (the donut's accessible name, when shown), text}. dnsMode is dnsModeNote(): in the firewall modes the log
 * cannot show blocks, so no percentage is given.
 */
function summary(stats, dnsMode) {
	const s = isObject(stats) ? stats : {};
	const blocked = int(s.blocked, 0), allowed = int(s.allowed, 0);
	const answered = blocked + allowed;
	if (dnsMode)
		return { pct: null, value: null, text: dnsMode == 'firewall'
			? _('Not shown: adblock-fast blocks in the firewall in this DNS mode.')
			: _('Not shown: adblock-fast does not use dnsmasq in this DNS mode.') };
	if (!answered)
		return { pct: null, value: null, text: _('No queries yet.') };
	const pct = (typeof(s.blocked_pct) == 'number' && isFinite(s.blocked_pct)) ? s.blocked_pct : Math.round(1000 * blocked / answered) / 10;
	const value = formatPct(pct);
	return { pct: pct, value: value, label: fmt(_('%s of recent queries blocked'), value),
		text: fmt(_('%s of %s queries blocked in the last %s'), formatCount(blocked), formatCount(answered), formatDuration(s.span_s)) };
}

/*
 * Who turns query logging on (§3, §8.5): 'ours' (this app's drop-in),
 * 'elsewhere' (dnsmasq's own `logqueries`, e.g. luci-app-adblock-fast) or
 * 'off'; null without info.
 */
function loggingSource(infoResult) {
	const info = infoData(infoResult);
	if (!info)
		return null;
	if (loggingElsewhere(infoResult))
		return 'elsewhere';
	return (isObject(info.monitor) && info.monitor.query_logging === true) ? 'ours' : 'off';
}

/* info.warnings that make turning logging on a risk: the log leaves RAM. */
function loggingRisks(infoResult) {
	const info = infoData(infoResult);
	const w = (info && Array.isArray(info.warnings)) ? info.warnings : [];
	return [ 'logd-to-flash', 'logd-remote' ].filter(c => w.indexOf(c) >= 0);
}

return baseclass.extend({
	STORAGE_KEY: STORAGE_KEY,
	MAX_PENDING: MAX_PENDING,
	OPS: OPS,
	ACCESS_DENIED: ACCESS_DENIED,
	rpcError: rpcError,
	normalizeDomain: normalizeDomain,
	settle: settle,
	failure: failure,
	pageState: pageState,
	loggingElsewhere: loggingElsewhere,
	POLL_INTERVAL: POLL_INTERVAL,
	protectedNames: protectedNames,
	isProtected: isProtected,
	dnsModeNote: dnsModeNote,
	backoffSkip: backoffSkip,
	LOG_STALL_GRACE: LOG_STALL_GRACE,
	logWatch: logWatch,
	logStalled: logStalled,
	localDomains: localDomains,
	rowOp: rowOp,
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
	fmt: fmt,
	formatCount: formatCount,
	formatPct: formatPct,
	formatDuration: formatDuration,
	formatClock: formatClock,
	summary: summary,
	loggingSource: loggingSource,
	loggingRisks: loggingRisks
});
