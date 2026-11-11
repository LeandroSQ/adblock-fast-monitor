'use strict';
'require view';
'require rpc';
'require uci';
'require ui';
'require form';
'require poll';
'require dom';
'require adblock-fast-monitor.model as model';
'require adblock-fast-monitor.querylog as querylog';

/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * Dashboard (docs/CONTRACT.md §8): the last DNS queries, read from the system
 * log in the browser exactly like LuCI's System Log page (`log read`), parsed
 * by querylog.js, with Allow/Block buttons that stage changes in this browser
 * and one explicit Apply (one adblock-fast rebuild).
 * Every dynamic value is inserted as a text node (arrays passed to E()/dom).
 */

const callLogRead = rpc.declare({ object: 'log', method: 'read',
	params: [ 'lines', 'stream', 'oneshot' ], reject: true });
const callInfo = rpc.declare({ object: 'luci.adblock-fast-monitor', method: 'info', reject: true });
const callApply = rpc.declare({ object: 'luci.adblock-fast-monitor', method: 'apply',
	params: [ 'ops', 'confirm_rebuild', 'rebuild', 'dry_run' ], reject: true });
const callJob = rpc.declare({ object: 'luci.adblock-fast-monitor', method: 'job', params: [ 'job_id' ], reject: true });

const INFO_INTERVAL = 30;
/* LuCI's poll runs a function when its tick count is a multiple of the interval: check often, call rarely. */
const INFO_CHECK = 5;
const JOB_INTERVAL = 2;
const MAX_ROWS = 500;
/* about 33 min of 2 s polls; then the old `abfm-poll` measures are dropped */
const MAX_MEASURES = 1000;
/* No keyboard, pointer or touch input for this long pauses polling (P0). */
const IDLE_PAUSE_MS = 15 * 60 * 1000;
const FILTER_DEBOUNCE_MS = 150;
const SETTINGS_PATH = 'admin/services/adblock-fast-monitor/settings';
const INPUT_EVENTS = [ 'pointerdown', 'pointermove', 'keydown', 'wheel', 'touchstart' ];

const OP_LABEL = { allow: _('Allow'), block: _('Block'), unblock: _('Unblock'), unallow: _('Unallow') };
const OP_BUTTON_CLASS = { allow: 'cbi-button cbi-button-positive', block: 'cbi-button cbi-button-negative' };
const DECISION_LABEL = {
	blocked: _('Blocked'), allowed: _('Allowed'), other: _('Other'), 'no-answer': _('No answer'),
	pending: _('Waiting for answer')
};
const SOURCE_LABEL = {
	config: _('dnsmasq rule'), addnhosts: _('adblock-fast hosts'), hosts: _('hosts file'),
	dhcp: _('DHCP lease'), local: _('local name'), error: _('upstream error'),
	upstream: _('upstream'), cache: _('cache'), auth: _('authoritative')
};
const STATE_TEXT = {
	'loading': _('Loading…'),
	'healthy': _('DNS query logging is on: dnsmasq writes every query to the system log, and this page reads them from there.'),
	'logging-off': _('DNS query logging is off, so no queries are shown. Turn on "Log DNS queries" in Settings.'),
	'logging-unavailable': _('DNS query logging is not working.'),
	'adblock-fast-missing': _('adblock-fast is not installed. Install the adblock-fast package; this page only shows and edits its rules.'),
	'access-denied': _('This account may not read the monitor status.'),
	'error': _('The system log cannot be read.')
};
const STATE_SEVERITY = {
	'loading': 'notice', 'healthy': 'success', 'logging-off': 'warning', 'logging-unavailable': 'warning'
};
const DNS_MODE_TEXT = {
	'firewall': _('adblock-fast blocks in the firewall in this DNS mode (ipset/nftset): dnsmasq answers every query normally, so the list below shows blocked domains as allowed and no blocked percentage is computed. Allow and Block still change adblock-fast\'s rules.'),
	'unsupported': _('adblock-fast uses a resolver other than dnsmasq in this DNS mode, so its blocking does not show up in the list below, and changes cannot be applied from this page.')
};
const REASON_TEXT = {
	'dnsmasq-not-running': _('dnsmasq is not running.'),
	'logging-not-active': _('No dnsmasq instance logs queries yet. Check "Log DNS queries" in Settings.'),
	'dnsmasq-logs-to-file': _('dnsmasq writes its log to a file (log facility), so queries never reach the system log.'),
	'confdir-invalid': _('A dnsmasq instance has an invalid configuration directory, so query logging cannot be enabled for it.')
};
const WARNING_TEXT = {
	'query-logging-active': _('Every DNS query is written to the system log buffer, which pushes out other log messages sooner.'),
	'logd-to-flash': _('The system log is also written to a file (log_file); query logging increases writes to that storage.'),
	'logd-remote': _('The system log is sent to a remote host (log_ip); every DNS query is forwarded there.')
};
const JOB_STATE_TEXT = {
	queued: _('Queued'), applying: _('Applying'), verifying: _('Verifying DNS answers'),
	applied: _('Applied'), partial: _('Partially applied'), failed: _('Failed')
};
const JOB_MODE_TEXT = {
	'rebuild': _('full rebuild'), 'persist-only': _('saved only (adblock-fast is disabled)')
};
const RESULT_TEXT = {
	pending: _('Pending'), ok: _('OK'), mismatch: _('Mismatch'), unverified: _('Unverified'), skipped: _('Skipped')
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
	'rebuild-failed': _('The block list rebuild failed'),
	'interrupted': _('The job was interrupted'), 'start-timeout': _('The job did not start'),
	'lock-failed': _('The job could not take its lock'), 'not-found': _('The job is no longer known (router restarted?)'),
	'still-listed': _('Still on a downloaded list; use Allow'), 'parent-blocked': _('A parent domain is still blocked'),
	'not-blocked': _('Still resolves'), 'dns-error': _('DNS lookup failed'),
	'dns-mode-unsupported': _('Not verifiable in this DNS mode'), 'mismatch': _('Mismatch'),
	'unverified': _('Unverified'), 'partial': _('Partially applied'), 'failed': _('Failed'),
	'too-many': _('Too many pending changes (maximum 64)'), 'invalid-op': _('Invalid change')
};

function T(value) {
	return [ (value == null) ? '' : String(value) ];
}

function errorText(code, fallback) {
	return ERROR_TEXT[code] || fallback || code;
}

function cell(title, content, extraClass) {
	return E('td', { 'class': 'td' + (extraClass ? ' ' + extraClass : ''), 'data-title': title }, content);
}

function headerRow(captions) {
	return E('tr', { 'class': 'tr table-titles' },
		captions.map(c => E('th', { 'class': 'th', 'scope': 'col' }, T(c))));
}

function placeholderRow(colspan, text) {
	return E('tr', { 'class': 'tr placeholder' }, [ E('td', { 'class': 'td', 'colspan': colspan }, T(text)) ]);
}

function dataTable(label, captions, rows, placeholder) {
	const head = E('tr', { 'class': 'tr table-titles' },
		captions.map(c => E('th', { 'class': 'th', 'scope': 'col' }, T(c))));
	const body = rows.length ? rows.map((r, i) => {
		r.classList.add('cbi-rowstyle-' + ((i % 2) ? 2 : 1));
		return r;
	}) : [ E('tr', { 'class': 'tr placeholder' }, [ E('td', { 'class': 'td', 'colspan': captions.length }, T(placeholder)) ]) ];
	return E('table', { 'class': 'table', 'aria-label': label }, [ head ].concat(body));
}

function checkbox(id, label, checked, onchange) {
	return E('label', { 'for': id }, [
		E('input', { 'type': 'checkbox', 'id': id, 'checked': checked ? '' : null,
			'change': ev => onchange(ev.target.checked) }), ' ', T(label)
	]);
}

function storageGet(key) {
	try { return window.localStorage.getItem(key); } catch (e) { return null; }
}

function storageSet(key, value) {
	try { window.localStorage.setItem(key, value); return true; } catch (e) { return false; }
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
		this.log = querylog.create({ max_rows: MAX_ROWS, pending_ttl_s: 10,
			local_domains: model.localDomains(infoResult), hide_router: true });
		this.display = { q: '', showRouter: false, showClient: false };
		this.logResult = null;
		this.hasRows = false;
		this.logWatch = null;
		this.measureCount = 0;
		this.keptRows = 0;
		this.dismissed = {};
		this.job = null;
		this.jobKey = null;
		this.stateKey = null;
		this.statsKey = null;
		this.queryRows = new Map();
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
			E('div', { 'class': 'cbi-map-descr' }, T(_('The last DNS queries answered by dnsmasq, and whether adblock-fast blocked them. Allow or block a domain, then apply all changes at once.')))
		]);

		node.appendChild(E('div', { 'class': 'alert-message notice', 'id': 'abfm-disclaimer' }, [
			E('strong', {}, T(_('For administrators only.'))), ' ',
			E('span', {}, T(_('Everyone who can open this page can read the whole system log through LuCI\'s standard log access, the same access that luci-app-adblock-fast and Status → System Log use. Grant this app only to administrators.')))
		]));

		this.stateNode = E('div', { 'id': 'abfm-state', 'role': 'status', 'aria-live': 'polite' });
		this.warningsNode = E('div', { 'id': 'abfm-warnings' });
		node.appendChild(this.stateNode);
		node.appendChild(this.warningsNode);

		this.statsNode = E('div', { 'id': 'abfm-stats' });
		this.missedNode = E('div', { 'id': 'abfm-missed' });
		node.appendChild(E('div', { 'class': 'cbi-section', 'id': 'abfm-stats-section' }, [
			E('h3', {}, T(_('Statistics'))),
			this.statsNode,
			this.missedNode,
			E('div', { 'class': 'cbi-section-descr', 'id': 'abfm-buffer-hint' }, T(this.bufferHint()))
		]));

		if (this.canWrite)
			node.appendChild(this.renderPendingSection());
		node.appendChild(this.renderQueriesSection());

		this.updateState();
		this.updateWarnings();
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
			changed: changed || 0
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
			} catch (e) {}
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
			this.updateWarnings();
			this.updateStats();
		});
	},

	/* ---- header ------------------------------------------------------------- */

	bufferHint() {
		const info = (this.infoResult && this.infoResult.ok) ? this.infoResult.data : null;
		const kib = (info && info.logd && typeof(info.logd.size_kib) == 'number') ? info.logd.size_kib : null;
		const where = _('To keep more, raise "System log buffer size" in System → System → Logging.');
		return (kib != null
			? _('Only queries still in the system log buffer (%d KiB, shared by every service) are shown.').format(kib)
			: _('Only queries still in the system log buffer (shared by every service) are shown.')) + ' ' + where;
	},

	updateState() {
		const st = model.pageState(this.infoResult, this.logResult, this.hasRows);
		/* §8.5: no actions without adblock-fast */
		const noActions = (st.state == 'adblock-fast-missing' || st.state == 'access-denied');
		if (noActions != !!this.noActions) {
			this.noActions = noActions;
			this.updatePending();
			this.updateQueries();
		}
		const info = (this.infoResult && this.infoResult.ok) ? this.infoResult.data : null;
		const flags = {
			elsewhere: st.state == 'healthy' && model.loggingElsewhere(this.infoResult),
			ours: st.state == 'healthy' && this.canWrite && !!(info && info.monitor && info.monitor.query_logging === true),
			settings: st.state == 'logging-off' || st.state == 'logging-unavailable',
			stalled: st.state == 'healthy' && model.logStalled(this.logWatch, Math.floor(Date.now() / 1000)),
			readError: (this.logResult && !this.logResult.ok) ? this.logResult.message : null,
			dnsMode: model.dnsModeNote(this.infoResult),
			paused: this.idlePaused,
			backoff: this.failures > 0 && this.hasRows
		};
		/* re-rendered only on change, so the live region is not re-announced every poll */
		const key = JSON.stringify([ st, flags ]);
		if (key == this.stateKey)
			return;
		this.stateKey = key;

		const children = [ E('strong', {}, T(STATE_TEXT[st.state] || st.state)) ];
		if (st.reason)
			children.push(E('p', { 'data-reason': st.reason }, T(REASON_TEXT[st.reason] || st.reason)));
		if (flags.elsewhere)
			children.push(E('p', {}, T(_('dnsmasq\'s own "Log queries" option is on (for example set by luci-app-adblock-fast), so queries are logged whatever this app\'s setting is.'))));
		if (flags.ours)
			children.push(E('p', {}, [
				E('span', {}, T(_('dnsmasq writes one line per DNS query to the system log while this is on, also when this page is closed.'))), ' ',
				E('button', { 'class': 'cbi-button cbi-button-neutral', 'id': 'abfm-logging-off',
					'click': ui.createHandlerFn(this, 'handleLoggingOff') }, T(_('Turn off query logging')))
			]));
		if (flags.settings)
			children.push(E('p', {}, [ E('a', { 'href': L.url(SETTINGS_PATH) }, T(_('Open settings'))) ]));
		if (flags.dnsMode)
			children.push(E('p', { 'id': 'abfm-dns-mode', 'data-mode': flags.dnsMode }, T(DNS_MODE_TEXT[flags.dnsMode])));
		if (flags.stalled)
			children.push(E('div', { 'class': 'alert-message warning', 'id': 'abfm-log-stalled' }, [
				E('p', {}, T(_('The system log was restarted and dnsmasq has logged nothing since, so DNS query logging may have stopped.'))),
				E('p', {}, T(_('If new queries do not appear, restart dnsmasq: System → Startup → dnsmasq → Restart, or run "/etc/init.d/dnsmasq restart".')))
			]));
		if (flags.paused)
			children.push(E('p', { 'id': 'abfm-paused' }, T(_('Updates are paused because this page has not been used for 15 minutes. Move the mouse or press a key to resume.'))));
		if (flags.readError)
			children.push(E('p', { 'id': 'abfm-read-error' }, T(_('The system log cannot be read: %s').format(flags.readError))));
		if (flags.backoff)
			children.push(E('p', { 'id': 'abfm-retrying' }, T(_('Retrying less often until the system log can be read again.'))));
		this.stateNode.className = 'alert-message ' + (STATE_SEVERITY[st.state] || 'danger');
		this.stateNode.setAttribute('data-state', st.state);
		this.stateNode.setAttribute('data-reason', st.reason || '');
		dom.content(this.stateNode, children);
	},

	/* §3: the same change as unticking "Log DNS queries" in Settings, through LuCI's apply. */
	handleLoggingOff() {
		return uci.load('adblock-fast-monitor').then(() => {
			uci.set('adblock-fast-monitor', 'config', 'query_logging', '0');
			return uci.save();
		}).then(() => ui.changes.apply(true)).catch(e => {
			ui.addNotification(null, E('p', {}, T(_('Query logging could not be turned off: %s').format(e.message))), 'danger');
		});
	},

	updateWarnings() {
		const info = (this.infoResult && this.infoResult.ok) ? this.infoResult.data : null;
		const warnings = (info && Array.isArray(info.warnings) ? info.warnings : [])
			.filter(w => typeof(w) == 'string' && WARNING_TEXT[w] && !this.dismissed[w]);
		dom.content(this.warningsNode, warnings.map(w => E('div', { 'class': 'alert-message notice', 'data-warning': w }, [
			E('span', {}, T(WARNING_TEXT[w])), ' ',
			E('button', { 'class': 'cbi-button cbi-button-neutral', 'aria-label': _('Dismiss note'),
				'click': () => { this.dismissed[w] = true; this.updateWarnings(); } }, T(_('Dismiss')))
		])));
	},

	updateStats() {
		const s = querylog.stats(this.log, { show_router: this.display.showRouter });
		this.keptRows = s.kept || 0;
		const since = s.since_open || {};
		const dnsMode = model.dnsModeNote(this.infoResult);
		const rows = [
			[ _('Blocked'), dnsMode ? _('not shown in this DNS mode') : model.formatPct(s.blocked_pct), 'blocked_pct',
				_('%d queries over %s').format(s.kept || 0, model.formatDuration(s.span_s)) ],
			[ _('Shown queries'), _('%s blocked, %s allowed, %s other, %s without answer').format(
				model.formatCount(s.blocked), model.formatCount(s.allowed), model.formatCount(s.other), model.formatCount(s.no_answer)), 'kept' ],
			[ _('Since page opened'), _('%s queries, %s blocked, %s allowed').format(
				model.formatCount(since.queries), model.formatCount(since.blocked), model.formatCount(since.allowed)), 'since_open' ]
		];
		const missed = s.missed_total || 0;
		const paused = s.paused_total || 0;
		const key = JSON.stringify([ rows, missed, paused ]);
		if (key == this.statsKey)
			return;
		this.statsKey = key;

		dom.content(this.statsNode, [ E('table', { 'class': 'table', 'aria-label': _('Statistics') },
			rows.map(r => E('tr', { 'class': 'tr', 'data-stat': r[2] }, [
				E('th', { 'class': 'td left', 'scope': 'row', 'width': '33%' }, T(r[0])),
				E('td', { 'class': 'td left' }, [ E('span', { 'class': 'abfm-value' }, T(r[1])) ].concat(
					r[3] ? [ ' ', E('span', { 'class': 'abfm-label' }, T(r[3])) ] : []))
			]))) ]);

		this.missedNode.setAttribute('data-missed', String(missed));
		this.missedNode.setAttribute('data-paused', String(paused));
		const notes = [];
		if (missed)
			notes.push(E('div', { 'class': 'alert-message warning' },
				T(_('%d log entries missed: the system log buffer was overwritten between refreshes, or dnsmasq reported lost entries.').format(missed))));
		if (paused)
			notes.push(E('div', { 'class': 'alert-message notice', 'id': 'abfm-paused-gap' },
				T(_('%d log entries were overwritten while updates were paused (page hidden or not in use); they are not shown.').format(paused))));
		dom.content(this.missedNode, notes);
	},

	/* ---- queries table ---------------------------------------------------------- */

	renderQueriesSection() {
		const filter = E('input', { 'id': 'abfm-filter', 'class': 'cbi-input-text', 'type': 'search',
			'maxlength': 253, 'placeholder': _('part of a domain'), 'autocomplete': 'off', 'spellcheck': 'false',
			'input': ev => {
				const q = ev.target.value;
				clearTimeout(this.filterTimer);
				this.filterTimer = setTimeout(() => { this.display.q = q; this.updateQueries(); }, FILTER_DEBOUNCE_MS);
			} });
		this.queriesNode = E('div', { 'id': 'abfm-queries' });
		this.queriesTable = E('table', { 'class': 'table', 'aria-label': _('Last queries') });
		this.queriesNode.appendChild(this.queriesTable);
		return E('div', { 'class': 'cbi-section', 'id': 'abfm-queries-section' }, [
			E('h3', {}, T(_('Last queries'))),
			E('div', { 'class': 'cbi-section-descr' }, T(_('Newest first, up to %d queries. Queries made by the router itself (127.0.0.1, ::1) can be shown or hidden.').format(MAX_ROWS))),
			E('div', { 'class': 'cbi-section-node' }, [
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title', 'for': 'abfm-filter' }, T(_('Filter domains'))),
					E('div', { 'class': 'cbi-value-field' }, [ filter ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('div', { 'class': 'cbi-value-title' }, T(_('Display'))),
					E('div', { 'class': 'cbi-value-field' }, [
						checkbox('abfm-show-router', _('Show router queries'), this.display.showRouter, v => { this.display.showRouter = v; this.updateStats(); this.updateQueries(); }), ' ',
						checkbox('abfm-show-client', _('Show client column'), false, v => { this.display.showClient = v; this.updateQueries(); })
					])
				])
			]),
			this.queriesNode
		]);
	},

	/* What the Actions cell of a row shows: '', 'inflight', 'staged:<op>' or 'op:<op>'. */
	actionState(row, ent) {
		if (this.noActions)
			return '';
		const domain = row.domain;
		if (this.pending.inflight && this.pending.inflight.items.some(i => i.domain == domain))
			return 'inflight';
		const staged = model.pendingOp(this.pending, domain);
		if (staged)
			return 'staged:' + staged;
		const op = model.rowOp(row.decision);
		if (!op || !ent.valid || (op == 'block' && model.isProtected(this.protect, ent.valid)))
			return '';
		return 'op:' + op;
	},

	actionsCell(row, state) {
		const domain = row.domain;
		if (state == 'inflight')
			return [ E('em', {}, T(_('Applying…'))) ];
		if (state.indexOf('staged:') == 0) {
			const staged = state.substring(7);
			return [
				E('span', { 'class': 'abfm-staged' }, T(_('Pending: %s').format(OP_LABEL[staged] || staged))), ' ',
				E('button', { 'class': 'cbi-button cbi-button-neutral',
					'aria-label': _('Cancel pending change for %s').format(domain),
					'click': () => this.unstageDomain(domain) }, T(_('Cancel')))
			];
		}
		if (state.indexOf('op:') == 0) {
			const op = state.substring(3);
			return [ E('button', { 'class': OP_BUTTON_CLASS[op], 'data-op': op,
				'aria-label': _('%s %s').format(OP_LABEL[op], domain),
				'click': () => this.stageOp(op, domain) }, T(OP_LABEL[op])) ];
		}
		return [];
	},

	queryRow(r, actions) {
		const decision = Object.prototype.hasOwnProperty.call(DECISION_LABEL, r.decision) ? DECISION_LABEL[r.decision] : r.decision;
		const result = r.source ? _('%s (%s)').format(decision, SOURCE_LABEL[r.source] || r.source) : decision;
		const tds = [
			cell(_('Time'), [ E('time', {}, T(model.formatTime(r.time))) ]),
			cell(_('Domain'), T(r.domain), 'abfm-domain'),
			cell(_('Type'), T(r.qtype)),
			cell(_('Answer'), T((Array.isArray(r.answers) ? r.answers : []).join(', ')), 'abfm-answer'),
			cell(_('Result'), T(result))
		];
		if (this.display.showClient)
			tds.push(cell(_('Client'), T(r.client)));
		if (this.canWrite)
			tds.push(cell(_('Actions'), this.actionsCell(r, actions), 'cbi-section-actions'));
		return E('tr', { 'class': 'tr', 'data-domain': r.domain, 'data-decision': r.decision,
			'data-router': r.router ? 'true' : 'false' }, tds);
	},

	/*
	 * Incremental update keyed by row key: rows whose content is unchanged
	 * keep their DOM node (focus, selection), changed rows are replaced in
	 * place, new rows are inserted and dropped rows removed. Row stripes are
	 * fixed when a row is created, so prepending rows touches no other row.
	 * A different filter, column set or router toggle rebuilds the table.
	 * Returns the number of rows created or removed (0 on an idle poll).
	 */
	updateQueries() {
		if (!this.queriesNode)
			return 0;
		const all = querylog.rows(this.log, { show_router: this.display.showRouter });
		const rows = model.filterRows(all, this.display.q);
		const table = this.queriesTable;
		const map = this.queryRows;
		let changed = 0;

		const layout = JSON.stringify([ this.display, this.canWrite ]);
		if (layout != this.queryLayout) {
			this.queryLayout = layout;
			const captions = [ _('Time'), _('Domain'), _('Type'), _('Answer'), _('Result') ];
			if (this.display.showClient)
				captions.push(_('Client'));
			if (this.canWrite)
				captions.push(_('Actions'));
			this.queryCols = captions.length;
			changed += map.size;
			map.clear();
			this.queryPlaceholder = null;
			dom.content(table, [ headerRow(captions) ]);
		}

		const keys = new Set();
		rows.forEach(r => keys.add(r.key));
		map.forEach((ent, k) => {
			if (!keys.has(k)) {
				ent.tr.remove();
				map.delete(k);
				changed++;
			}
		});

		const fresh = [];
		let prev = table.firstChild;
		rows.forEach(r => {
			let ent = map.get(r.key);
			if (!ent) {
				ent = { tr: null, sig: null, parity: 0, valid: model.normalizeDomain(r.domain) };
				map.set(r.key, ent);
				fresh.push(ent);
			}
			const actions = this.canWrite ? this.actionState(r, ent) : '';
			const sig = r.decision + '\n' + r.source + '\n' + r.answers.join('\n') + '\n' + actions;
			if (sig !== ent.sig) {
				const tr = this.queryRow(r, actions);
				if (ent.parity)
					tr.classList.add('cbi-rowstyle-' + ent.parity);
				if (ent.tr)
					ent.tr.replaceWith(tr);
				else
					changed++;
				ent.tr = tr;
				ent.sig = sig;
			}
			if (prev.nextSibling !== ent.tr)
				table.insertBefore(ent.tr, prev.nextSibling);
			prev = ent.tr;
		});

		/* stripes for new rows continue from the older row below them */
		for (let i = rows.length - 1; i >= 0; i--) {
			const ent = map.get(rows[i].key);
			if (ent.parity)
				continue;
			const below = (i + 1 < rows.length) ? map.get(rows[i + 1].key).parity : 2;
			ent.parity = (below == 1) ? 2 : 1;
			ent.tr.classList.add('cbi-rowstyle-' + ent.parity);
		}

		const text = rows.length ? null : (all.length ? _('No queries match the filter.') : _('No queries seen yet.'));
		if (text != (this.queryPlaceholder && this.queryPlaceholder.textContent)) {
			if (this.queryPlaceholder)
				this.queryPlaceholder.remove();
			this.queryPlaceholder = text ? table.appendChild(placeholderRow(this.queryCols, text)) : null;
		}
		return changed;
	},

	/* ---- staging ------------------------------------------------------------------ */

	savePending() {
		if (!storageSet(model.STORAGE_KEY, model.serializePending(this.pending)))
			ui.addNotification(null, E('p', {}, T(_('Pending changes could not be saved in this browser; they are lost when the page is closed.'))), 'warning');
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
			ui.addNotification(null, E('p', {}, T(_('Cannot stage "%s": %s').format(String(domain), errorText(r.error)))), 'warning');
			return false;
		}
		this.setPending(r.state);
		return true;
	},

	unstageDomain(domain) {
		this.setPending(model.unstage(this.pending, domain));
	},

	renderPendingSection() {
		this.pendingNode = E('div', { 'id': 'abfm-pending' });
		this.jobNode = E('div', { 'id': 'abfm-job', 'role': 'status', 'aria-live': 'polite' });
		this.applyButton = E('button', { 'class': 'cbi-button cbi-button-apply', 'id': 'abfm-apply',
			'click': ui.createHandlerFn(this, 'handleApply') }, T(_('Apply changes')));
		this.discardButton = E('button', { 'class': 'cbi-button cbi-button-reset', 'id': 'abfm-discard',
			'click': () => this.setPending(model.discard(this.pending)) }, T(_('Discard all')));

		const input = E('input', { 'id': 'abfm-add-domain', 'class': 'cbi-input-text', 'type': 'text',
			'maxlength': 253, 'placeholder': 'ads.example.com', 'autocomplete': 'off', 'spellcheck': 'false' });
		const op = E('select', { 'id': 'abfm-add-op', 'class': 'cbi-input-select', 'aria-label': _('Change') },
			model.OPS.map(o => E('option', { 'value': o, 'selected': (o == 'block') ? '' : null }, T(OP_LABEL[o]))));
		const add = this.addButton = E('button', { 'class': 'cbi-button cbi-button-add', 'id': 'abfm-add',
			'click': () => { if (this.stageOp(op.value, input.value)) input.value = ''; } }, T(_('Add to pending')));
		input.addEventListener('keydown', ev => { if (ev.key == 'Enter') add.click(); });

		return E('div', { 'class': 'cbi-section', 'id': 'abfm-pending-section' }, [
			E('h3', {}, T(_('Pending changes'))),
			E('div', { 'class': 'cbi-section-descr' }, T(_('Changes are kept in this browser until you apply them. Apply sends all of them at once and rebuilds the adblock-fast block lists one time.'))),
			this.pendingNode,
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title', 'for': 'abfm-add-domain' }, T(_('Domain'))),
				E('div', { 'class': 'cbi-value-field' }, [ input, ' ', op, ' ', add ])
			]),
			E('div', { 'class': 'right' }, [ this.discardButton, ' ', this.applyButton ]),
			this.jobNode
		]);
	},

	updatePending() {
		if (!this.pendingNode)
			return;
		const items = this.pending.items;
		const rows = items.map(i => E('tr', { 'class': 'tr', 'data-domain': i.domain, 'data-op': i.op }, [
			cell(_('Domain'), T(i.domain), 'abfm-domain'),
			cell(_('Change'), T(OP_LABEL[i.op])),
			cell(_('Note'), T(i.reason ? _('Last attempt: %s').format(errorText(i.reason)) : '')),
			cell(_('Actions'), [ E('button', { 'class': 'cbi-button cbi-button-remove',
				'aria-label': _('Remove pending change for %s').format(i.domain),
				'click': () => this.unstageDomain(i.domain) }, T(_('Remove'))) ], 'cbi-section-actions')
		]));
		dom.content(this.pendingNode, [ dataTable(_('Pending changes'), [ _('Domain'), _('Change'), _('Note'), _('Actions') ],
			rows, _('No pending changes.')) ]);
		this.applyButton.disabled = !items.length || !!this.pending.inflight || !!this.applying || !!this.noActions;
		this.addButton.disabled = !!this.noActions;
		this.discardButton.disabled = !items.length;
		this.updateJob();
	},

	/* ---- apply (§8.2): dry run → confirm → apply → job ------------------------------- */

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
			ui.showModal(_('Apply changes'), [
				E('div', { 'class': 'alert-message warning' }, [
					E('p', {}, T(_('This rebuilds the adblock-fast block lists: all lists are downloaded again over the WAN, DNS is restarted, and it may take minutes.')))
				]),
				list.length ? E('ul', {}, list) : '',
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'cbi-button', 'click': () => { ui.hideModal(); resolve(false); } }, T(_('Cancel'))), ' ',
					E('button', { 'class': 'cbi-button cbi-button-apply', 'id': 'abfm-confirm-apply',
						'click': () => { ui.hideModal(); resolve(true); } }, T(_('Apply')))
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
				ui.addNotification(null, E('p', {}, T(_('Nothing to change: the rules are already in place.'))), 'info');
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

	updateJob() {
		if (!this.jobNode)
			return;
		const job = this.job;
		if (!job) {
			this.jobKey = null;
			dom.content(this.jobNode, []);
			return;
		}
		const key = JSON.stringify([ job.id, job.state, job.phase, job.error,
			(job.items || []).map(i => [ i.result, i.observed ]), !!this.pending.inflight ]);
		if (key == this.jobKey)
			return;
		this.jobKey = key;

		const terminal = model.isTerminal(job);
		const parts = [ JOB_STATE_TEXT[job.state] || job.state ];
		if (job.mode)
			parts.push(JOB_MODE_TEXT[job.mode] || job.mode);
		const children = [
			E('h4', {}, T(_('Last apply'))),
			E('p', { 'id': 'abfm-job-state', 'data-job': job.id, 'data-state': job.state, 'class': terminal ? '' : 'spinning' }, T(parts.join(' · ')))
		];
		if (job.finished_at)
			children.push(E('p', {}, T(_('Finished %s').format(model.formatTime(job.finished_at)))));
		if (job.error)
			children.push(E('div', { 'class': 'alert-message danger', 'data-error': job.error.code },
				T(errorText(job.error.code, job.error.message))));
		const items = Array.isArray(job.items) ? job.items : [];
		if (items.length)
			children.push(dataTable(_('Apply results'), [ _('Domain'), _('Change'), _('Expected'), _('Observed'), _('Result'), _('Reason') ],
				items.map(i => E('tr', { 'class': 'tr', 'data-domain': i.domain, 'data-result': i.result }, [
					cell(_('Domain'), T(i.domain), 'abfm-domain'),
					cell(_('Change'), T(OP_LABEL[i.op] || i.op)),
					cell(_('Expected'), T(i.expect || '')),
					cell(_('Observed'), T(i.observed || '')),
					cell(_('Result'), T(RESULT_TEXT[i.result] || i.result || '')),
					cell(_('Reason'), T(i.reason ? errorText(i.reason) : ''))
				])), ''));
		dom.content(this.jobNode, children);
	}
});
