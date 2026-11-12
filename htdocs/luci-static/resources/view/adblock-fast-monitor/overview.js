'use strict';
'require view';
'require rpc';
'require uci';
'require ui';
'require poll';
'require dom';
'require adblock-fast-monitor.model as model';
'require adblock-fast-monitor.querylog as querylog';
'require adblock-fast-monitor.chart as chart';

/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * The app's one page (docs/CONTRACT.md §8): statistics, the last DNS
 * queries read from the system log in the browser exactly like LuCI's
 * System Log page (`log read`) and parsed by querylog.js, a Block or Allow
 * button per row that stages the change in this browser, and one
 * "Apply and save" that writes adblock-fast's own Allowed/Blocked Domains
 * lists and rebuilds its block lists once (§6.3, §7).
 * Every dynamic value is inserted as a text node (arrays passed to E()/dom).
 */

/*
 * The polled calls are sent at once, not batched: LuCI flushes batched
 * calls from a requestAnimationFrame callback, and the frame that runs it
 * keeps the compositor on its frame clock while a `log read` reply is on
 * its way, so the frame that shows the reply would wait for the next frame
 * slot (P4). Each is the only call of its poll anyway.
 */
const callLogRead = rpc.declare({ object: 'log', method: 'read',
	params: [ 'lines', 'stream', 'oneshot' ], reject: true, nobatch: true });
const callInfo = rpc.declare({ object: 'luci.adblock-fast-monitor', method: 'info', reject: true, nobatch: true });
const callApply = rpc.declare({ object: 'luci.adblock-fast-monitor', method: 'apply',
	params: [ 'ops', 'confirm_rebuild', 'rebuild', 'dry_run' ], reject: true });
const callJob = rpc.declare({ object: 'luci.adblock-fast-monitor', method: 'job', params: [ 'job_id' ], reject: true });

const INFO_INTERVAL = 30;
/* LuCI's poll runs a function when its tick count is a multiple of the interval: check often, call rarely. */
const INFO_CHECK = 5;
const JOB_INTERVAL = 2;
const MAX_ROWS = 500;
/* Rows in the DOM: the poll's DOM cost stays bounded whatever the query rate (P4). */
const PAGE_SIZE = 50;
/* The list scrolls inside its box, under a header that stays in view. */
const LIST_STYLE = 'max-height:60vh;overflow-y:auto';
const HEAD_STYLE = 'position:sticky;top:0;z-index:1;background:var(--background-color-high, #fff)';
/* about 33 min of 2 s polls; then the old `abfm-poll` measures are dropped */
const MAX_MEASURES = 1000;
/* No keyboard, pointer or touch input for this long pauses polling (P0). */
const IDLE_PAUSE_MS = 15 * 60 * 1000;
const INPUT_EVENTS = [ 'pointerdown', 'pointermove', 'keydown', 'wheel', 'touchstart' ];

const OP_LABEL = { allow: _('Allow'), block: _('Block') };
/* per-row texts, translated once (P4: a poll rewrites up to 50 of them) */
const OP_ARIA = _('%s %s');
const UNDO_ARIA = _('Undo: %s %s');
/* a staged row offers one button that takes the change back */
const UNDO_LABEL = { allow: _('Undo allow'), block: _('Undo block') };
const OP_BUTTON_CLASS = { allow: 'cbi-button cbi-button-positive', block: 'cbi-button cbi-button-negative' };
const DECISION_LABEL = {
	blocked: _('Blocked'), allowed: _('Allowed'), other: _('Other'), 'no-answer': _('No answer'),
	pending: _('Waiting')
};
/* Where the answer came from, shown next to the decision (§8.3). */
const SOURCE_LABEL = {
	config: _('dnsmasq rule'), addnhosts: _('block list'), hosts: _('hosts file'),
	dhcp: _('DHCP lease'), local: _('local name'), error: _('upstream error'),
	upstream: _('upstream'), cache: _('cache'), auth: _('authoritative')
};
const STATE_TEXT = {
	'loading': _('Loading…'),
	'logging-off': _('DNS query logging is off, so no queries can be shown.'),
	'logging-unavailable': _('DNS query logging is not working.'),
	'adblock-fast-missing': _('adblock-fast is not installed. Install the adblock-fast package; this page only shows and changes its rules.'),
	'access-denied': _('This account may not read the monitor status.'),
	'error': _('The system log cannot be read.')
};
const STATE_SEVERITY = { 'loading': 'notice', 'logging-off': 'notice', 'logging-unavailable': 'warning' };
const DNS_MODE_TEXT = {
	'firewall': _('In this DNS mode (ipset/nftset) adblock-fast blocks in the firewall, so dnsmasq answers every query and the list shows blocked domains as allowed. Block and Allow still change adblock-fast\'s lists.'),
	'unsupported': _('In this DNS mode adblock-fast does not use dnsmasq, so its blocking is not visible here and changes cannot be applied from this page.')
};
const REASON_TEXT = {
	'dnsmasq-not-running': _('dnsmasq is not running.'),
	'logging-not-active': _('Query logging is on, but no dnsmasq instance logs queries yet.'),
	'dnsmasq-logs-to-file': _('dnsmasq writes its log to a file (log facility), so queries never reach the system log.'),
	'confdir-invalid': _('A dnsmasq instance has an invalid configuration directory, so query logging cannot be turned on for it.')
};
const RISK_TEXT = {
	'logd-to-flash': _('The system log is also written to a file on persistent storage, so every DNS query adds a write to that storage.'),
	'logd-remote': _('The system log is sent to a remote log server, so every DNS query, with the client address, is sent there.')
};
const JOB_TEXT = {
	queued: _('Saving and rebuilding the block lists… This can take a few minutes.'),
	applying: _('Saving and rebuilding the block lists… This can take a few minutes.'),
	verifying: _('Checking the new DNS answers…'),
	applied: _('Applied and saved.'),
	partial: _('Applied and saved, but some domains did not change as expected. They are back in the list of changes.'),
	failed: _('Not applied.')
};
const SAVED_ONLY_TEXT = _('Saved. adblock-fast is disabled, so the change takes effect when it is enabled.');
const RESULT_TEXT = {
	pending: _('checking…'), ok: _('done'), mismatch: _('did not change'), unverified: _('saved, not checked'),
	skipped: _('saved')
};
const ERROR_TEXT = {
	'invalid-domain': _('Invalid domain name'), 'protected-domain': _('Protected domain'),
	'public-suffix': _('Public suffix: rule would be too broad'), 'conflict': _('Conflicting changes'),
	'allow-overrides': _('An allow rule overrides this block'), 'adblock-fast-missing': _('adblock-fast is not installed'),
	'external-config': _('adblock-fast uses an external configuration file'),
	'unsupported-dns-mode': _('adblock-fast DNS mode is not supported'),
	'pending-uci-changes': _('the adblock-fast configuration has uncommitted changes made on the command line (uci) or by adblock-fast itself; commit or revert them (see "uci changes adblock-fast") and apply again'),
	'busy': _('Another change is being applied'), 'uci-error': _('Could not save the adblock-fast configuration'),
	'spawn-failed': _('Could not start the apply job'),
	'rebuild-failed': _('The block list rebuild failed; the domains are saved, apply again to retry'),
	'interrupted': _('The job was interrupted'), 'start-timeout': _('The job did not start'),
	'lock-failed': _('The job could not take its lock'), 'not-found': _('The job is no longer known (router restarted?)'),
	'still-listed': _('Still on a downloaded list; use Allow'), 'parent-blocked': _('A parent domain is still blocked'),
	'not-blocked': _('Still resolves'), 'dns-error': _('DNS lookup failed'),
	'dns-mode-unsupported': _('Not verifiable in this DNS mode'), 'mismatch': _('Did not change'),
	'unverified': _('Not checked'), 'partial': _('Partly applied'), 'failed': _('Failed'),
	'too-many': _('Too many pending changes (maximum 64)'), 'invalid-op': _('Invalid change')
};

function T(value) {
	return [ (value == null) ? '' : String(value) ];
}

/* An empty text node that later updates rewrite through .data. */
function textNode() {
	return document.createTextNode('');
}

function errorText(code, fallback) {
	return ERROR_TEXT[code] || fallback || code;
}

function cell(title, content, extraClass) {
	return E('td', { 'class': 'td' + (extraClass ? ' ' + extraClass : ''), 'data-title': title }, content);
}

function placeholderRow(colspan, text) {
	return E('tr', { 'class': 'tr placeholder' }, [ E('td', { 'class': 'td', 'colspan': colspan }, T(text)) ]);
}

function show(node, visible) {
	const display = visible ? '' : 'none';
	if (node.style.display != display)
		node.style.display = display;
}

function storageGet(key) {
	try {
		return window.localStorage.getItem(key);
	}
	catch (e) {
		return null;
	}
}

function storageSet(key, value) {
	try {
		window.localStorage.setItem(key, value);
		return true;
	}
	catch (e) {
		return false;
	}
}

return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	load() {
		return callInfo().then(model.settle, model.failure);
	},

	render(infoResult) {
		this.canWrite = L.hasViewPermission() === true;
		this.infoResult = infoResult;
		this.infoAt = Date.now();
		this.protect = model.protectedNames(infoResult);
		/* router queries (127.0.0.1, ::1; e.g. the job's own checks) are never listed */
		this.log = querylog.create({ max_rows: MAX_ROWS, pending_ttl_s: 10,
			local_domains: model.localDomains(infoResult), hide_router: true });
		this.logResult = null;
		this.hasRows = false;
		this.logWatch = null;
		this.measureCount = 0;
		this.keptRows = 0;
		this.job = null;
		this.jobKey = null;
		this.stateKey = null;
		this.notesKey = null;
		this.missedKey = null;
		this.statView = null;
		this.queryRows = new Map();
		this.querySlots = [];
		this.slotPool = [];
		this.rowTemplate = null;
		this.resultLabels = new Map();
		this.queryCreated = 0;
		this.queryLayout = null;
		this.pending = model.parsePending(storageGet(model.STORAGE_KEY));
		this.polling = false;
		this.logBusy = false;
		this.failures = 0;
		this.skipPolls = 0;
		this.stoppedAt = null;
		this.idlePaused = false;
		this.lastInput = Date.now();
		this.visibility = 0;
		this.ticks = { log: L.bind(this.pollLog, this), info: L.bind(this.pollInfo, this), job: L.bind(this.pollJob, this) };

		const node = E('div', { 'class': 'cbi-map', 'id': 'abfm-overview' }, [
			E('h2', {}, T(_('Adblock Fast Monitor'))),
			E('div', { 'class': 'cbi-map-descr' }, [
				E('span', {}, T(_('Recent DNS queries and whether adblock-fast blocked them. Block or allow a domain, then click "Apply and save".'))), ' ',
				E('span', { 'id': 'abfm-disclaimer' }, T(_('For administrators only: this page can read the whole system log.')))
			])
		]);

		this.stateNode = E('div', { 'id': 'abfm-state', 'role': 'status', 'aria-live': 'polite' });
		this.notesNode = E('div', { 'id': 'abfm-notes' });
		node.appendChild(this.stateNode);
		node.appendChild(this.notesNode);

		this.statsNode = E('div', { 'class': 'cbi-section', 'id': 'abfm-stats' });
		node.appendChild(this.statsNode);
		if (this.canWrite)
			node.appendChild(this.renderChanges());
		node.appendChild(this.renderQueriesSection());
		this.loggingNode = E('div', { 'class': 'cbi-section-descr', 'id': 'abfm-logging' });
		node.appendChild(this.loggingNode);

		this.updateState();
		this.updateStats();
		this.updatePending();
		this.updateQueries();

		document.addEventListener('visibilitychange', L.bind(this.handleVisibility, this));
		window.addEventListener('storage', L.bind(this.handleStorage, this));
		const onInput = L.bind(this.handleInput, this);
		INPUT_EVENTS.forEach(t => window.addEventListener(t, onInput, { passive: true, capture: true }));

		if (this.pending.inflight)
			this.watchJob(this.pending.inflight.job_id);
		else
			this.loadLatestJob();
		this.startPolling();

		return node;
	},

	/* ---- polling: only while the page is visible and in use (P0, CONTRACT §11 P2) ---- */

	startPolling() {
		if (this.polling || this.idlePaused || document.visibilityState != 'visible')
			return;
		this.polling = true;
		if (this.stoppedAt != null) {
			/* polls skipped while hidden or idle: fetch about that much once (§8.1) */
			const interval = model.POLL_INTERVAL * 1000;
			querylog.resume(this.log, Math.ceil((Date.now() - this.stoppedAt) / interval));
			this.stoppedAt = null;
		}
		poll.add(this.ticks.log, model.POLL_INTERVAL);
		poll.add(this.ticks.info, INFO_CHECK);
		if (this.watchedJob)
			poll.add(this.ticks.job, JOB_INTERVAL);
	},

	stopPolling() {
		if (!this.polling)
			return;
		this.polling = false;
		this.stoppedAt = Date.now();
		poll.remove(this.ticks.log);
		poll.remove(this.ticks.info);
		poll.remove(this.ticks.job);
	},

	handleVisibility() {
		this.visibility++;
		if (document.visibilityState == 'visible')
			this.startPolling();
		else
			this.stopPolling();
	},

	/* Passive listener: one timestamp per event, no timer. */
	handleInput() {
		this.lastInput = Date.now();
		if (this.idlePaused) {
			this.idlePaused = false;
			this.startPolling();
			this.updateState();
		}
	},

	handleStorage(ev) {
		if (ev.key != model.STORAGE_KEY)
			return;
		this.pending = model.parsePending(ev.newValue);
		/* another tab started a job: follow it here too */
		if (this.pending.inflight && this.watchedJob != this.pending.inflight.job_id)
			this.watchJob(this.pending.inflight.job_id);
		this.updatePending();
		this.updateQueries();
	},

	readLog(lines) {
		return callLogRead(lines, false, true);
	},

	/*
	 * One `log read`, plus at most one refetch when querylog sees a gap; never
	 * two in flight (a visibility flip re-adds the poll function, §8.1).
	 * Failed reads back off (model.backoffSkip); no input for IDLE_PAUSE_MS
	 * pauses polling until the next input event.
	 * P4 (docs/performance.md): `abfm-poll` spans from the arrival of the
	 * reply that is kept (network time excluded; with a refetch, its reply)
	 * through ingest, every DOM update, and the next rendered frame.
	 */
	pollLog() {
		if (this.logBusy)
			return Promise.resolve();
		if (this.skipPolls > 0) {
			this.skipPolls--;
			return Promise.resolve();
		}
		if (Date.now() - this.lastInput >= IDLE_PAUSE_MS) {
			this.idlePaused = true;
			this.stopPolling();
			this.updateState();
			return Promise.resolve();
		}
		this.logBusy = true;
		const now = () => Math.floor(Date.now() / 1000);
		let t0 = 0;
		return this.readLog(querylog.nextRequest(this.log).lines).then(reply => {
			t0 = performance.now();
			const r = querylog.ingest(this.log, reply) || {};
			if (!r.refetch)
				return { replies: [ reply ], kept: reply, reset: r.reset };
			return this.readLog(r.refetch.lines).then(again => {
				t0 = performance.now();
				const r2 = querylog.ingest(this.log, again) || {};
				return { replies: [ reply, again ], kept: again, reset: r.reset || r2.reset };
			});
		}).then(res => {
			this.logResult = model.settle(null);
			this.hasRows = true;
			this.failures = 0;
			this.logWatch = model.logWatch(this.logWatch, res.replies, res.reset === true, now());
			return res;
		}, err => {
			this.logResult = model.failure(err);
			this.skipPolls = model.backoffSkip(++this.failures);
			return null;
		}).then(res => {
			this.updateState();
			this.updateStats();
			const changed = this.updateQueries();
			if (res)
				this.measurePoll(t0, res.kept, changed);
		}).finally(() => {
			this.logBusy = false;
		});
	},

	/*
	 * One `abfm-poll` measure per kept reply, ended after the next frame has
	 * been rendered (requestAnimationFrame, then a task). Dropped when the
	 * page was hidden meanwhile (no frames run while hidden). Measures are
	 * capped (P0: bounded); no marks are left behind.
	 */
	measurePoll(t0, reply, changed) {
		if (typeof(performance) == 'undefined' || typeof(requestAnimationFrame) != 'function')
			return;
		const vis = this.visibility;
		const detail = {
			entries: (reply && Array.isArray(reply.log)) ? reply.log.length : 0,
			rows: this.keptRows || 0,
			shown: this.queryRows.size,
			changed: changed || 0,
			created: this.queryCreated || 0
		};
		requestAnimationFrame(() => setTimeout(() => {
			if (vis != this.visibility || document.visibilityState != 'visible')
				return;
			try {
				if (++this.measureCount > MAX_MEASURES) {
					performance.clearMeasures('abfm-poll');
					this.measureCount = 1;
				}
				performance.measure('abfm-poll', { start: t0, end: performance.now(), detail: detail });
			}
			catch (e) {}
		}, 0));
	},

	/* info at load and every 30 s while visible (§8.5) */
	pollInfo() {
		if (Date.now() - this.infoAt < INFO_INTERVAL * 1000)
			return Promise.resolve();
		this.infoAt = Date.now();
		return callInfo().then(model.settle, model.failure).then(res => {
			this.infoResult = res;
			if (res.ok) {
				this.protect = model.protectedNames(res);
				this.updateQueries();
			}
			this.updateState();
			this.updateStats();
		});
	},

	/* ---- state, notes and the query-logging line ----------------------------------- */

	infoData() {
		return (this.infoResult && this.infoResult.ok) ? this.infoResult.data : null;
	},

	/*
	 * §8.5 state. The healthy page shows no banner; every other state is
	 * one notice with what to do. Short notes (DNS mode, a stalled or
	 * unreadable log, paused updates) appear only while they apply.
	 * Re-rendered only on change, so the live region is not re-announced
	 * every poll.
	 */
	updateState() {
		const st = model.pageState(this.infoResult, this.logResult, this.hasRows);
		/* §8.5: no actions without adblock-fast */
		const noActions = (st.state == 'adblock-fast-missing' || st.state == 'access-denied');
		if (noActions != !!this.noActions) {
			this.noActions = noActions;
			this.updatePending();
			this.updateQueries();
		}
		const flags = {
			source: model.loggingSource(this.infoResult),
			risks: model.loggingRisks(this.infoResult),
			stalled: st.state == 'healthy' && model.logStalled(this.logWatch, Math.floor(Date.now() / 1000)),
			readError: (this.logResult && !this.logResult.ok) ? this.logResult.message : null,
			dnsMode: model.dnsModeNote(this.infoResult),
			paused: this.idlePaused,
			backoff: this.failures > 0 && this.hasRows
		};
		const key = JSON.stringify([ st, flags, this.canWrite ]);
		if (key == this.stateKey)
			return;
		this.stateKey = key;

		this.stateNode.setAttribute('data-state', st.state);
		this.stateNode.setAttribute('data-reason', st.reason || '');
		if (st.state == 'healthy') {
			this.stateNode.className = '';
			dom.content(this.stateNode, []);
		}
		else {
			const children = [ E('strong', {}, T(STATE_TEXT[st.state] || st.state)) ];
			if (st.reason)
				children.push(E('p', { 'data-reason': st.reason }, T(REASON_TEXT[st.reason] || st.reason)));
			if (st.state == 'logging-off') {
				if (this.canWrite)
					children.push(E('p', {}, [ E('button', { 'class': 'cbi-button cbi-button-action', 'id': 'abfm-logging-on',
						'click': ui.createHandlerFn(this, 'handleLoggingOn') }, T(_('Turn on query logging'))) ]));
				else
					children.push(E('p', {}, T(_('An administrator can turn it on on this page.'))));
			}
			if (flags.readError && st.state == 'error')
				children.push(E('p', { 'id': 'abfm-read-error' }, T(flags.readError)));
			this.stateNode.className = 'alert-message ' + (STATE_SEVERITY[st.state] || 'danger');
			dom.content(this.stateNode, children);
		}
		show(this.statsNode, st.state != 'logging-off');
		show(this.queriesSection, st.state != 'logging-off');

		const notes = [];
		if (flags.dnsMode)
			notes.push(E('div', { 'class': 'alert-message notice', 'id': 'abfm-dns-mode', 'data-mode': flags.dnsMode },
				T(DNS_MODE_TEXT[flags.dnsMode])));
		if (flags.stalled)
			notes.push(E('div', { 'class': 'alert-message warning', 'id': 'abfm-log-stalled' }, [
				E('p', {}, T(_('The system log was restarted and dnsmasq has logged nothing since, so DNS query logging may have stopped.'))),
				E('p', {}, T(_('If new queries do not appear, restart dnsmasq: System → Startup → dnsmasq → Restart, or run "/etc/init.d/dnsmasq restart".')))
			]));
		if (flags.paused)
			notes.push(E('div', { 'class': 'alert-message notice', 'id': 'abfm-paused' },
				T(_('Updates are paused because this page has not been used for 15 minutes. Move the mouse or press a key to resume.'))));
		if (flags.readError && st.state != 'error')
			notes.push(E('div', { 'class': 'alert-message warning', 'id': 'abfm-read-error' },
				T(_('The system log cannot be read: %s').format(flags.readError))));
		if (flags.backoff)
			notes.push(E('div', { 'class': 'alert-message warning', 'id': 'abfm-retrying' },
				T(_('Retrying less often until the system log can be read again.'))));
		dom.content(this.notesNode, notes);

		/* one line about the switch that makes dnsmasq log every query, and its risks */
		const line = [];
		if (flags.source == 'ours') {
			line.push(E('span', {}, T(_('Query logging is on: dnsmasq writes every DNS query to the system log, also while this page is closed.'))));
			if (this.canWrite)
				line.push(' ', E('button', { 'class': 'cbi-button cbi-button-neutral', 'id': 'abfm-logging-off',
					'click': ui.createHandlerFn(this, 'handleLoggingOff') }, T(_('Turn off query logging'))));
		}
		else if (flags.source == 'elsewhere') {
			line.push(E('span', { 'id': 'abfm-logging-elsewhere' },
				T(_('Query logging is on in dnsmasq\'s own settings (for example turned on by luci-app-adblock-fast).'))));
		}
		if (flags.source == 'ours' || flags.source == 'elsewhere')
			flags.risks.forEach(w => line.push(' ', E('strong', { 'data-warning': w }, T(RISK_TEXT[w]))));
		dom.content(this.loggingNode, line);
	},

	/* §3: query_logging through LuCI's own save and apply; the init script does the rest. */
	setLogging(on) {
		return uci.load('adblock-fast-monitor').then(() => {
			uci.set('adblock-fast-monitor', 'config', 'query_logging', on ? '1' : '0');
			return uci.save();
		}).then(() => ui.changes.apply(true)).catch(e => {
			ui.addNotification(null, E('p', {}, T(_('Query logging could not be changed: %s').format(e.message))), 'danger');
		});
	},

	handleLoggingOff() {
		return this.setLogging(false);
	},

	/* Asks first when the system log leaves RAM (§6.1 logd-to-flash, logd-remote). */
	handleLoggingOn() {
		const risks = model.loggingRisks(this.infoResult);
		if (!risks.length)
			return this.setLogging(true);
		return new Promise(resolve => {
			ui.showModal(_('Turn on DNS query logging?'), [
				E('div', { 'class': 'alert-message warning' }, risks.map(w => E('p', { 'data-risk': w }, T(RISK_TEXT[w])))),
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'cbi-button', 'click': () => { ui.hideModal(); resolve(false); } }, T(_('Cancel'))), ' ',
					E('button', { 'class': 'cbi-button cbi-button-positive', 'id': 'abfm-confirm-logging',
						'click': () => { ui.hideModal(); resolve(true); } }, T(_('Turn on')))
				])
			]);
		}).then(ok => ok ? this.setLogging(true) : null);
	},

	/* ---- statistics ----------------------------------------------------------------- */

	missedText(missed) {
		const info = this.infoData();
		const kib = (info && info.logd && typeof(info.logd.size_kib) == 'number') ? info.logd.size_kib : null;
		return (kib != null
			? _('%d log entries were missed: queries came faster than the system log (%d KiB, shared by every service) keeps them.').format(missed, kib)
			: _('%d log entries were missed: queries came faster than the system log keeps them.').format(missed)) +
			' ' + _('To keep more, raise "System log buffer size" in System → System → Logging.');
	},

	/*
	 * The blocked share as a donut in a LuCI card (.ifacebox, as on Status →
	 * Overview) next to one sentence (model.summary). Built once; a poll
	 * rewrites only the attributes and texts that changed (P4).
	 */
	updateStats() {
		const s = querylog.stats(this.log, { show_router: false });
		this.keptRows = s.kept || 0;
		const sum = model.summary(s, model.dnsModeNote(this.infoResult));
		let v = this.statView;
		if (!v) {
			v = this.statView = { donut: chart.donut(96), text: textNode(), line: undefined };
			v.missed = E('div', { 'class': 'alert-message warning', 'style': 'display:none' }, [ textNode() ]);
			v.paused = E('div', { 'class': 'alert-message notice', 'id': 'abfm-paused-gap', 'style': 'display:none' }, [ textNode() ]);
			this.missedNode = E('div', { 'id': 'abfm-missed', 'data-missed': '0', 'data-paused': '0' }, [ v.missed, v.paused ]);
			dom.content(this.statsNode, [
				E('div', { 'data-stat': 'blocked_pct', 'style': 'display:flex;align-items:center;flex-wrap:wrap;gap:1em' }, [
					E('div', { 'class': 'ifacebox', 'style': 'margin:0' }, [
						E('div', { 'class': 'ifacebox-head' }, T(_('Blocked'))),
						E('div', { 'class': 'ifacebox-body' }, [ v.donut.node ])
					]),
					E('p', { 'data-stat': 'text' }, [ v.text ])
				]),
				this.missedNode
			]);
		}
		v.donut.update(sum.pct, sum.value, sum.label || sum.text);
		if (v.line !== sum.text)
			v.text.data = v.line = sum.text;

		const missed = s.missed_total || 0;
		const paused = s.paused_total || 0;
		const key = missed + ':' + paused;
		if (key == this.missedKey)
			return;
		this.missedKey = key;
		this.missedNode.setAttribute('data-missed', String(missed));
		this.missedNode.setAttribute('data-paused', String(paused));
		this.setNote(v.missed, missed ? this.missedText(missed) : '');
		this.setNote(v.paused, paused ? _('%d log entries were overwritten while updates were paused (page hidden or not in use); they are not shown.').format(paused) : '');
	},

	/* A note is shown while it has text; unchanged text or visibility is not written again. */
	setNote(node, text) {
		if (node.firstChild.data !== text)
			node.firstChild.data = text;
		show(node, !!text);
	},

	/* ---- the last queries ------------------------------------------------------------ */

	renderQueriesSection() {
		this.queriesTable = E('table', { 'class': 'table', 'aria-label': _('Last queries') });
		/* keyboard users scroll it too: focusable, named region (WCAG 2.1.1) */
		this.queriesNode = E('div', { 'id': 'abfm-queries', 'style': LIST_STYLE, 'tabindex': '0',
			'role': 'region', 'aria-label': _('Last queries') }, [ this.queriesTable ]);
		this.queriesSection = E('div', { 'class': 'cbi-section', 'id': 'abfm-queries-section' }, [
			E('h3', {}, T(_('Last queries'))),
			E('div', { 'class': 'cbi-section-descr' }, T(_('Newest first, up to 50. The list updates every 2 seconds while this page is open.'))),
			this.queriesNode
		]);
		return this.queriesSection;
	},

	/* What the action cell of a row shows: '', 'inflight', 'staged:<op>' or 'op:<op>'. */
	actionState(row, slot) {
		if (this.noActions)
			return '';
		const domain = row.domain;
		if (this.pending.inflight && this.pending.inflight.items.some(i => i.domain == domain))
			return 'inflight';
		const staged = model.pendingOp(this.pending, domain);
		if (staged)
			return 'staged:' + staged;
		const op = model.rowOp(row.decision);
		if (!op || !slot.valid || (op == 'block' && model.isProtected(this.protect, slot.valid)))
			return '';
		return 'op:' + op;
	},

	/*
	 * A row slot: one <tr> of the queries table and the text nodes of its
	 * cells, reused for whatever row sits at its place (updateQueries).
	 * Cells are cloned from one template; buttons read the slot's current
	 * domain when clicked.
	 */
	newSlot() {
		if (!this.rowTemplate) {
			const tds = [
				cell(_('Time'), [ E('time') ]),
				cell(_('Domain'), [], 'abfm-domain'),
				cell(_('Client'), [], 'abfm-client'),
				cell(_('Result'), [], 'abfm-result')
			];
			if (this.canWrite)
				tds.push(cell(_('Action'), [], 'cbi-section-actions'));
			this.rowTemplate = E('tr', { 'class': 'tr' }, tds);
			tds[0].firstChild.appendChild(textNode());
			for (let i = 1; i < 4; i++)
				tds[i].appendChild(textNode());
		}
		const tr = this.rowTemplate.cloneNode(true);
		const tds = tr.children;
		return { tr: tr, key: null, domain: null, valid: null, decision: null, vals: [],
			text: [ tds[0].firstChild.firstChild, tds[1].firstChild, tds[2].firstChild, tds[3].firstChild ],
			act: null, aria: null, ariaButton: null, actCell: this.canWrite ? tds[4] : null, buttons: {}, staged: null, inflight: null };
	},

	/* "Decision (source)", formatted once per pair (a few dozen at most). */
	resultLabel(decision, source) {
		const k = decision + '\n' + source;
		let text = this.resultLabels.get(k);
		if (text === undefined) {
			const d = Object.prototype.hasOwnProperty.call(DECISION_LABEL, decision) ? DECISION_LABEL[decision] : decision;
			text = source ? _('%s (%s)').format(d, SOURCE_LABEL[source] || source) : String(d);
			if (this.resultLabels.size < 256)
				this.resultLabels.set(k, text);
		}
		return text;
	},

	/* Writes only what differs from the slot's last values; returns true if anything changed. */
	fillSlot(slot, r) {
		let changed = false;
		if (slot.domain !== r.domain) {
			slot.domain = r.domain;
			slot.valid = model.normalizeDomain(r.domain);
			slot.tr.setAttribute('data-domain', r.domain);
			changed = true;
		}
		if (slot.decision !== r.decision) {
			slot.decision = r.decision;
			slot.tr.setAttribute('data-decision', r.decision);
			changed = true;
		}
		if (r.time !== this.timeKey) {
			this.timeKey = r.time;
			this.timeText = model.formatClock(r.time);
		}
		const vals = [ this.timeText, String(r.domain), (r.client == null) ? '' : String(r.client), this.resultLabel(r.decision, r.source) ];
		for (let i = 0; i < vals.length; i++) {
			if (slot.vals[i] !== vals[i]) {
				slot.vals[i] = vals[i];
				slot.text[i].data = vals[i];
				changed = true;
			}
		}
		if (this.canWrite && this.fillActions(slot, this.actionState(r, slot)))
			changed = true;
		return changed;
	},

	/*
	 * Action cell. Its controls are made once per slot and kept: one button
	 * per operation (so a row never changes a button's class, which would
	 * restyle it and start the theme's border transition), the Undo button
	 * of a staged change, and the "Applying…" note. The cell's children
	 * are swapped only when the state differs; labels follow the slot's
	 * domain. Returns true if anything changed.
	 */
	fillActions(slot, state) {
		const domain = slot.domain;
		let changed = false;
		if (state != slot.act) {
			slot.act = state;
			changed = true;
			let nodes = [];
			if (state == 'inflight') {
				if (!slot.inflight)
					slot.inflight = E('em', {}, T(_('Applying…')));
				nodes = [ slot.inflight ];
			}
			else if (state.indexOf('staged:') == 0) {
				if (!slot.staged)
					slot.staged = {
						button: E('button', { 'class': 'cbi-button cbi-button-neutral', 'data-staged': '',
							'click': () => this.unstageDomain(slot.domain) }, [ textNode() ]),
						op: null
					};
				const staged = state.substring(7);
				if (slot.staged.op !== staged) {
					slot.staged.op = staged;
					slot.staged.button.setAttribute('data-staged', staged);
					slot.staged.button.firstChild.data = UNDO_LABEL[staged] || staged;
				}
				nodes = [ slot.staged.button ];
			}
			else if (state.indexOf('op:') == 0) {
				const op = state.substring(3);
				if (!slot.buttons[op])
					slot.buttons[op] = E('button', { 'class': OP_BUTTON_CLASS[op], 'data-op': op,
						'click': () => this.stageOp(op, slot.domain) }, T(OP_LABEL[op]));
				nodes = [ slot.buttons[op] ];
			}
			slot.actCell.replaceChildren(...nodes);
		}
		/* the shown button's accessible name carries the row's domain */
		let button = null, aria = null;
		if (state.indexOf('op:') == 0) {
			const op = state.substring(3);
			button = slot.buttons[op];
			aria = OP_ARIA.format(OP_LABEL[op], domain);
		}
		else if (state.indexOf('staged:') == 0) {
			const op = state.substring(7);
			button = slot.staged.button;
			aria = UNDO_ARIA.format(OP_LABEL[op] || op, domain);
		}
		if (button && (slot.aria !== aria || slot.ariaButton !== button)) {
			button.setAttribute('aria-label', aria);
			slot.aria = aria;
			slot.ariaButton = button;
			changed = true;
		}
		return changed;
	},

	/*
	 * Update of the list (the newest PAGE_SIZE rows). The table keeps one
	 * slot (a <tr> and the text nodes of its cells) per shown row, by
	 * position: a poll writes each row into the slot at its place, and a
	 * write only touches the text nodes and attributes whose value differs.
	 * A list that shifts therefore costs text writes only: no row is
	 * created, moved or restyled (stripes are fixed per position), and
	 * nothing reads layout, so the browser lays out once (P4). Slots are
	 * created only while the list grows (the first fill is built in one
	 * fragment and inserted once) and kept for reuse while it is short.
	 * Keyboard focus in a row follows that row's key, and leaves the table
	 * when the row leaves the list. Returns the number of rows written or
	 * removed (0 on an idle poll), at most PAGE_SIZE; this.queryCreated
	 * counts the slots created.
	 */
	updateQueries() {
		if (!this.queriesNode)
			return 0;
		const rows = querylog.page(this.log, { show_router: false, limit: PAGE_SIZE }).rows;
		const table = this.queriesTable;
		const map = this.queryRows;
		const slots = this.querySlots;
		let changed = 0;
		this.queryCreated = 0;

		const layout = String(this.canWrite);
		if (layout != this.queryLayout) {
			this.queryLayout = layout;
			const captions = [ _('Time'), _('Domain'), _('Client'), _('Result') ];
			if (this.canWrite)
				captions.push(_('Action'));
			this.queryCols = captions.length;
			changed += slots.length;
			map.clear();
			slots.length = 0;
			this.slotPool = [];
			this.rowTemplate = null;
			this.queryPlaceholder = null;
			dom.content(table, [ E('tr', { 'class': 'tr table-titles' },
				captions.map(c => E('th', { 'class': 'th', 'scope': 'col', 'style': HEAD_STYLE }, T(c)))) ]);
		}

		/* the row that holds keyboard focus, if any (only document state is read here) */
		const active = document.activeElement;
		let focus = null;
		if (active && active !== document.body && slots.length && table.contains(active)) {
			const at = slots.find(s => s.tr.contains(active));
			if (at)
				focus = { slot: at, key: at.key };
		}

		let fresh = null;
		const before = slots.length ? slots[slots.length - 1].tr.nextSibling : table.firstChild.nextSibling;
		while (slots.length < rows.length) {
			let slot = this.slotPool.pop();
			if (!slot) {
				slot = this.newSlot();
				this.queryCreated++;
			}
			slot.tr.className = 'tr cbi-rowstyle-' + ((slots.length % 2) ? 2 : 1);
			slots.push(slot);
			if (!fresh)
				fresh = document.createDocumentFragment();
			fresh.appendChild(slot.tr);
		}
		while (slots.length > rows.length) {
			const slot = slots.pop();
			slot.tr.remove();
			if (this.slotPool.length < PAGE_SIZE)
				this.slotPool.push(slot);
			changed++;
		}

		map.clear();
		for (let i = 0; i < rows.length; i++) {
			const slot = slots[i];
			slot.key = rows[i].key;
			map.set(slot.key, slot);
			if (this.fillSlot(slot, rows[i]))
				changed++;
		}
		if (fresh)
			table.insertBefore(fresh, before);

		if (focus) {
			const to = map.get(focus.key);
			let target = null;
			if (to === focus.slot && focus.slot.tr.contains(active))
				target = active;
			else if (to && to.actCell)
				target = to.actCell.querySelector('button');
			if (target !== active) {
				if (target)
					target.focus({ preventScroll: true });
				else if (active.isConnected && table.contains(active))
					active.blur();
			}
		}

		const text = rows.length ? null : _('No queries seen yet.');
		if (text != (this.queryPlaceholder && this.queryPlaceholder.textContent)) {
			if (this.queryPlaceholder)
				this.queryPlaceholder.remove();
			this.queryPlaceholder = text ? table.appendChild(placeholderRow(this.queryCols, text)) : null;
		}
		return changed;
	},

	/* ---- staged changes (§8.4) ------------------------------------------------------------ */

	savePending() {
		if (!storageSet(model.STORAGE_KEY, model.serializePending(this.pending)))
			ui.addNotification(null, E('p', {}, T(_('Changes could not be kept in this browser; they are lost when the page is closed.'))), 'warning');
	},

	setPending(state) {
		this.pending = state;
		this.savePending();
		this.updatePending();
		this.updateQueries();
	},

	stageOp(op, domain) {
		const r = model.stage(this.pending, op, domain, Math.floor(Date.now() / 1000), this.protect);
		if (r.error) {
			ui.addNotification(null, E('p', {}, T(_('Cannot change "%s": %s').format(String(domain), errorText(r.error)))), 'warning');
			return false;
		}
		this.setPending(r.state);
		return true;
	},

	unstageDomain(domain) {
		this.setPending(model.unstage(this.pending, domain));
	},

	/* The changes bar: shown only while something is staged; the job's progress below it. */
	renderChanges() {
		this.changesTitle = textNode();
		this.pendingNode = E('ul', { 'id': 'abfm-pending', 'aria-label': _('Pending changes') });
		this.applyButton = E('button', { 'class': 'cbi-button cbi-button-apply', 'id': 'abfm-apply',
			'click': ui.createHandlerFn(this, 'handleApply') }, T(_('Apply and save')));
		this.discardButton = E('button', { 'class': 'cbi-button cbi-button-reset', 'id': 'abfm-discard',
			'click': () => this.setPending(model.discard(this.pending)) }, T(_('Discard')));
		this.changesNode = E('div', { 'class': 'alert-message notice', 'id': 'abfm-changes', 'style': 'display:none' }, [
			E('strong', {}, [ this.changesTitle ]),
			this.pendingNode,
			E('div', { 'class': 'right' }, [ this.discardButton, ' ', this.applyButton ])
		]);
		this.jobNode = E('div', { 'id': 'abfm-job', 'role': 'status', 'aria-live': 'polite' });
		return E('div', { 'id': 'abfm-changes-section' }, [ this.changesNode, this.jobNode ]);
	},

	updatePending() {
		if (!this.pendingNode)
			return;
		const items = this.pending.items;
		this.changesTitle.data = _('Changes not applied yet: %d').format(items.length);
		dom.content(this.pendingNode, items.map(i => E('li', { 'data-domain': i.domain, 'data-op': i.op }, [
			E('span', {}, T(_('%s %s').format(OP_LABEL[i.op], i.domain))),
			i.reason ? E('em', {}, T(' ' + _('(last attempt: %s)').format(errorText(i.reason)))) : '',
			' ',
			E('button', { 'class': 'cbi-button cbi-button-remove',
				'aria-label': _('Remove pending change for %s').format(i.domain),
				'click': () => this.unstageDomain(i.domain) }, T(_('Remove')))
		])));
		show(this.changesNode, items.length > 0);
		this.applyButton.disabled = !items.length || !!this.pending.inflight || !!this.applying || !!this.noActions;
		this.discardButton.disabled = !items.length;
		this.updateJob();
	},

	/* ---- Apply and save (§8.4): dry run → confirm → apply → job ---------------------------- */

	applyError(reply) {
		const e = (reply && reply.error) || {};
		if (e.code == 'busy') {
			ui.addNotification(null, E('p', {}, T(errorText('busy'))), 'warning');
			const id = reply.job_id || e.job_id;
			if (id)
				this.watchJob(id);
			return;
		}
		if (e.domain)
			this.setPending(model.markError(this.pending, e));
		ui.addNotification(null, E('p', { 'data-error': e.code || '' }, T(_('Changes were not applied: %s').format(
			errorText(e.code, e.message) + (e.domain ? ' (' + e.domain + ')' : '')))), 'danger');
	},

	confirmModal(plan) {
		const list = (plan.plan || []).filter(p => Array.isArray(p.change) && p.change.length).map(p =>
			E('li', {}, T(_('%s %s').format(OP_LABEL[p.op] || p.op, p.domain))));
		return new Promise(resolve => {
			ui.showModal(_('Apply and save'), [
				E('p', {}, T(_('The domains are saved in adblock-fast\'s Allowed Domains and Blocked Domains lists, the same lists its own settings page shows.'))),
				list.length ? E('ul', {}, list) : '',
				E('div', { 'class': 'alert-message warning' }, [
					E('p', {}, T(_('adblock-fast then rebuilds its block lists: all lists are downloaded again, DNS restarts briefly, and this can take a few minutes.')))
				]),
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'cbi-button', 'click': () => { ui.hideModal(); resolve(false); } }, T(_('Cancel'))), ' ',
					E('button', { 'class': 'cbi-button cbi-button-apply', 'id': 'abfm-confirm-apply',
						'click': () => { ui.hideModal(); resolve(true); } }, T(_('Apply and save')))
				])
			]);
		});
	},

	handleApply() {
		if (this.applying || !this.pending.items.length || this.pending.inflight)
			return Promise.resolve();
		this.applying = true;
		this.updatePending();
		const ops = model.toOps(this.pending);
		return callApply(ops, false, false, true).then(reply => {
			/* a rebuild batch is refused with confirm-required before the dry run */
			const confirmRequired = reply && reply.ok === false && reply.error && reply.error.code == 'confirm-required';
			if ((!reply || reply.ok === false) && !confirmRequired)
				return this.applyError(reply);
			const plan = model.applyPlan(confirmRequired ? Object.assign({}, reply, { mode: reply.mode || 'rebuild' }) : reply);
			if (plan.noop) {
				this.setPending(model.settleNoop(this.pending, ops));
				ui.addNotification(null, E('p', {}, T(_('Nothing to change: adblock-fast already has these rules.'))), 'info');
				return;
			}
			const go = plan.needsConfirm ? this.confirmModal(plan) : Promise.resolve(true);
			return go.then(confirmed => confirmed ? this.submit(ops, plan.needsConfirm) : null);
		}).catch(e => {
			ui.addNotification(null, E('p', {}, T(_('Changes were not applied: %s').format(e.message))), 'danger');
		}).finally(() => {
			this.applying = false;
			this.updatePending();
		});
	},

	submit(ops, confirmRebuild) {
		return callApply(ops, confirmRebuild, false, false).then(reply => {
			if (!reply || reply.ok === false) {
				if (reply && reply.error && reply.error.code == 'confirm-required' && !confirmRebuild)
					return this.confirmModal(model.applyPlan(reply)).then(ok => ok ? this.submit(ops, true) : null);
				return this.applyError(reply);
			}
			if (reply.noop || !reply.job_id) {
				this.setPending(model.settleNoop(this.pending, ops));
				return;
			}
			this.setPending(model.beginInflight(this.pending, reply.job_id, ops));
			this.job = { id: reply.job_id, state: reply.state || 'queued', mode: reply.mode, items: [] };
			this.watchJob(reply.job_id);
		});
	},

	/* ---- job ------------------------------------------------------------------------------ */

	loadLatestJob() {
		if (!this.canWrite)
			return;
		callJob().then(reply => {
			if (reply && reply.ok !== false && reply.job && !model.isTerminal(reply.job))
				this.watchJob(reply.job.id);
		}).catch(() => {});
	},

	watchJob(id) {
		this.watchedJob = id;
		if (!this.job || this.job.id != id)
			this.job = { id: id, state: 'queued', items: [] };
		this.updateJob();
		if (this.polling)
			poll.add(this.ticks.job, JOB_INTERVAL);
		/* a hidden or idle page (e.g. another tab started the job) asks later, from startPolling (P2) */
		if (document.visibilityState != 'visible' || this.idlePaused)
			return Promise.resolve();
		return this.pollJob();
	},

	stopJob() {
		poll.remove(this.ticks.job);
		this.watchedJob = null;
	},

	pollJob() {
		const id = this.watchedJob;
		if (!id || this.jobBusy)
			return Promise.resolve();
		this.jobBusy = true;
		return callJob(id).then(model.settle, model.failure).then(res => {
			this.jobBusy = false;
			if (id != this.watchedJob)
				return;
			if (res.ok && res.data && res.data.ok === false && res.data.error && res.data.error.code == 'not-found') {
				this.stopJob();
				this.job = null;
				if (this.pending.inflight && this.pending.inflight.job_id == id)
					this.setPending(model.returnInflight(this.pending, 'not-found'));
				this.updateJob();
				return;
			}
			if (!res.ok || !res.data || !res.data.job)
				return;
			this.job = res.data.job;
			if (model.isTerminal(this.job)) {
				this.stopJob();
				if (this.pending.inflight && this.pending.inflight.job_id == this.job.id)
					this.setPending(model.settleJob(this.pending, this.job).state);
			}
			this.updateJob();
		});
	},

	/* One line for the running or last job, its per-domain results, and a Dismiss once it ended. */
	updateJob() {
		if (!this.jobNode)
			return;
		const job = this.job;
		if (!job) {
			this.jobKey = null;
			dom.content(this.jobNode, []);
			return;
		}
		const key = JSON.stringify([ job.id, job.state, job.phase, job.error, job.mode,
			(job.items || []).map(i => [ i.result, i.reason ]) ]);
		if (key == this.jobKey)
			return;
		this.jobKey = key;

		const terminal = model.isTerminal(job);
		let text = (job.state == 'applied' && job.mode == 'persist-only') ? SAVED_ONLY_TEXT : (JOB_TEXT[job.state] || job.state);
		if (job.error)
			text += ' ' + errorText(job.error.code, job.error.message);
		const severity = { applied: 'success', partial: 'warning', failed: 'danger' }[job.state] || 'notice';
		const items = Array.isArray(job.items) ? job.items : [];
		const children = [
			E('p', { 'id': 'abfm-job-state', 'data-job': job.id, 'data-state': job.state, 'data-mode': job.mode || '',
				'class': terminal ? '' : 'spinning' }, T(text))
		];
		if (job.error)
			children[0].setAttribute('data-error', job.error.code);
		if (items.length)
			children.push(E('ul', { 'aria-label': _('Apply results') }, items.map(i =>
				E('li', { 'data-domain': i.domain, 'data-result': i.result }, T(_('%s %s: %s').format(
					OP_LABEL[i.op] || i.op, i.domain,
					(RESULT_TEXT[i.result] || i.result || '') + (i.reason ? ' (' + errorText(i.reason) + ')' : '')))))));
		if (terminal)
			children.push(E('div', { 'class': 'right' }, [ E('button', { 'class': 'cbi-button cbi-button-neutral', 'id': 'abfm-job-dismiss',
				'click': () => { this.job = null; this.updateJob(); } }, T(_('Dismiss'))) ]));
		dom.content(this.jobNode, [ E('div', { 'class': 'alert-message ' + severity }, children) ]);
	}
});
