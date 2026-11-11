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
const JOB_INTERVAL = 2;
const MAX_ROWS = 500;
/* about 33 min of 2 s polls; then the old `abfm-poll` measures are dropped */
const MAX_MEASURES = 1000;
const SETTINGS_PATH = 'admin/services/adblock-fast-monitor/settings';

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
		this.options = model.viewOptions(infoResult);
		this.log = querylog.create({ max_rows: MAX_ROWS, pending_ttl_s: 10,
			local_domains: model.localDomains(infoResult), hide_router: this.options.hideRouter });
		this.display = { q: '', showRouter: !this.options.hideRouter, showClient: false };
		this.logResult = null;
		this.hasRows = false;
		this.logWatch = null;
		this.measureCount = 0;
		this.keptRows = 0;
		this.dismissed = {};
		this.rowsKey = null;
		this.job = null;
		this.jobKey = null;
		this.pending = model.parsePending(storageGet(model.STORAGE_KEY));
		this.polling = false;
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

		if (this.pending.inflight)
			this.watchJob(this.pending.inflight.job_id);
		else
			this.loadLatestJob();
		this.startPolling();

		return node;
	},

	/* ---- polling: only while the page is visible (P0, CONTRACT §11 P2) ---- */

	startPolling() {
		if (this.polling || document.visibilityState != 'visible')
			return;
		this.polling = true;
		poll.add(this.ticks.log, this.options.interval);
		poll.add(this.ticks.info, INFO_INTERVAL);
		if (this.watchedJob)
			poll.add(this.ticks.job, JOB_INTERVAL);
	},

	stopPolling() {
		if (!this.polling)
			return;
		this.polling = false;
		poll.remove(this.ticks.log);
		poll.remove(this.ticks.info);
		poll.remove(this.ticks.job);
	},

	handleVisibility() {
		if (document.visibilityState == 'visible')
			this.startPolling();
		else
			this.stopPolling();
	},

	handleStorage(ev) {
		if (ev.key != model.STORAGE_KEY)
			return;
		this.pending = model.parsePending(ev.newValue);
		this.updatePending();
		this.updateQueries();
	},

	readLog(lines) {
		return callLogRead(lines, false, true);
	},

	/* One `log read`, plus at most one refetch when querylog sees a gap. */
	/*
	 * One `log read`, plus at most one refetch when querylog sees a gap.
	 * The ingest + render of the reply that is kept is timed as one
	 * `abfm-poll` measure (P4, docs/performance.md), network time excluded.
	 */
	pollLog() {
		const now = () => Math.floor(Date.now() / 1000);
		return this.readLog(querylog.nextRequest(this.log).lines).then(reply => {
			this.markPoll();
			const r = querylog.ingest(this.log, reply) || {};
			if (!r.refetch)
				return { replies: [ reply ], kept: reply, reset: r.reset };
			return this.readLog(r.refetch.lines).then(again => {
				this.markPoll();
				const r2 = querylog.ingest(this.log, again) || {};
				return { replies: [ reply, again ], kept: again, reset: r.reset || r2.reset };
			});
		}).then(res => {
			this.logResult = model.settle(null);
			this.hasRows = true;
			this.logWatch = model.logWatch(this.logWatch, res.replies, res.reset === true, now());
			return res;
		}, err => {
			this.logResult = model.failure(err);
			return null;
		}).then(res => {
			this.updateState();
			this.updateStats();
			this.updateQueries();
			if (res)
				this.measurePoll(res.kept);
		});
	},

	markPoll() {
		try { performance.mark('abfm-poll-start'); } catch (e) {}
	},

	/* One mark/measure pair per poll; marks are cleared at once, measures capped (P0: bounded). */
	measurePoll(reply) {
		try {
			const entries = (reply && Array.isArray(reply.log)) ? reply.log.length : 0;
			if (++this.measureCount > MAX_MEASURES) {
				performance.clearMeasures('abfm-poll');
				this.measureCount = 1;
			}
			performance.measure('abfm-poll', { start: 'abfm-poll-start', detail: { entries: entries, rows: this.keptRows || 0 } });
			performance.clearMarks('abfm-poll-start');
		} catch (e) {}
	},

	/* info at load and every 30 s while visible (§8.5); the first tick is the load itself */
	pollInfo() {
		if (!this.infoSkipped) {
			this.infoSkipped = true;
			return Promise.resolve();
		}
		return callInfo().then(model.settle, model.failure).then(res => {
			this.infoResult = res;
			this.updateState();
			this.updateWarnings();
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
		}
		const children = [ E('strong', {}, T(STATE_TEXT[st.state] || st.state)) ];
		if (st.reason)
			children.push(E('p', { 'data-reason': st.reason }, T(REASON_TEXT[st.reason] || st.reason)));
		if (st.state == 'healthy' && model.loggingElsewhere(this.infoResult))
			children.push(E('p', {}, T(_('dnsmasq\'s own "Log queries" option is on (for example set by luci-app-adblock-fast), so queries are logged whatever this app\'s setting is.'))));
		if (st.state == 'logging-off' || st.state == 'logging-unavailable')
			children.push(E('p', {}, [ E('a', { 'href': L.url(SETTINGS_PATH) }, T(_('Open settings'))) ]));
		if (st.state == 'healthy' && model.logStalled(this.logWatch, Math.floor(Date.now() / 1000)))
			children.push(E('div', { 'class': 'alert-message warning', 'id': 'abfm-log-stalled' }, [
				E('p', {}, T(_('The system log was restarted and dnsmasq has logged nothing since, so DNS query logging may have stopped.'))),
				E('p', {}, T(_('If new queries do not appear, restart dnsmasq: System → Startup → dnsmasq → Restart, or run "/etc/init.d/dnsmasq restart".')))
			]));
		if (this.logResult && !this.logResult.ok)
			children.push(E('p', { 'id': 'abfm-read-error' }, T(_('The system log cannot be read: %s').format(this.logResult.message))));
		this.stateNode.className = 'alert-message ' + (STATE_SEVERITY[st.state] || 'danger');
		this.stateNode.setAttribute('data-state', st.state);
		this.stateNode.setAttribute('data-reason', st.reason || '');
		dom.content(this.stateNode, children);
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
		const rows = [
			[ _('Blocked'), model.formatPct(s.blocked_pct), 'blocked_pct',
				_('%d queries over %s').format(s.kept || 0, model.formatDuration(s.span_s)) ],
			[ _('Shown queries'), _('%s blocked, %s allowed, %s other, %s without answer').format(
				model.formatCount(s.blocked), model.formatCount(s.allowed), model.formatCount(s.other), model.formatCount(s.no_answer)), 'kept' ],
			[ _('Since page opened'), _('%s queries, %s blocked, %s allowed').format(
				model.formatCount(since.queries), model.formatCount(since.blocked), model.formatCount(since.allowed)), 'since_open' ]
		];
		dom.content(this.statsNode, [ E('table', { 'class': 'table', 'aria-label': _('Statistics') },
			rows.map(r => E('tr', { 'class': 'tr', 'data-stat': r[2] }, [
				E('th', { 'class': 'td left', 'scope': 'row', 'width': '33%' }, T(r[0])),
				E('td', { 'class': 'td left' }, [ E('span', { 'class': 'abfm-value' }, T(r[1])) ].concat(
					r[3] ? [ ' ', E('span', { 'class': 'abfm-label' }, T(r[3])) ] : []))
			]))) ]);

		const missed = s.missed_total || 0;
		this.missedNode.setAttribute('data-missed', String(missed));
		dom.content(this.missedNode, missed ? [ E('div', { 'class': 'alert-message warning' },
			T(_('%d log entries missed: the system log buffer was overwritten between refreshes, or dnsmasq reported lost entries.').format(missed))) ] : []);
	},

	/* ---- queries table ---------------------------------------------------------- */

	renderQueriesSection() {
		const filter = E('input', { 'id': 'abfm-filter', 'class': 'cbi-input-text', 'type': 'search',
			'maxlength': 253, 'placeholder': _('part of a domain'), 'autocomplete': 'off', 'spellcheck': 'false',
			'input': ev => { this.display.q = ev.target.value; this.updateQueries(); } });
		this.queriesNode = E('div', { 'id': 'abfm-queries' });
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

	actionsCell(row) {
		const domain = row.domain;
		if (this.noActions)
			return [];
		const inflight = this.pending.inflight && this.pending.inflight.items.some(i => i.domain == domain);
		if (inflight)
			return [ E('em', {}, T(_('Applying…'))) ];
		const staged = model.pendingOp(this.pending, domain);
		if (staged)
			return [
				E('span', { 'class': 'abfm-staged' }, T(_('Pending: %s').format(OP_LABEL[staged] || staged))), ' ',
				E('button', { 'class': 'cbi-button cbi-button-neutral',
					'aria-label': _('Cancel pending change for %s').format(domain),
					'click': () => this.unstageDomain(domain) }, T(_('Cancel')))
			];
		const op = model.rowOp(row.decision);
		if (!op || !model.normalizeDomain(domain))
			return [];
		return [ E('button', { 'class': OP_BUTTON_CLASS[op], 'data-op': op,
			'aria-label': _('%s %s').format(OP_LABEL[op], domain),
			'click': () => this.stageOp(op, domain) }, T(OP_LABEL[op])) ];
	},

	/* Rebuilt only when what it shows changed, so idle polls touch no DOM. */
	updateQueries() {
		if (!this.queriesNode)
			return;
		const all = querylog.rows(this.log, { show_router: this.display.showRouter });
		const rows = model.filterRows(all, this.display.q);
		const key = JSON.stringify([ rows.map(r => [ r.key, r.decision, r.answers ]), this.display,
			this.canWrite ? [ this.pending.items, this.pending.inflight, !!this.noActions ] : null ]);
		if (key == this.rowsKey)
			return;
		this.rowsKey = key;

		const captions = [ _('Time'), _('Domain'), _('Type'), _('Answer'), _('Result') ];
		if (this.display.showClient)
			captions.push(_('Client'));
		if (this.canWrite)
			captions.push(_('Actions'));
		const trs = rows.map(r => {
			const result = ((Object.prototype.hasOwnProperty.call(DECISION_LABEL, r.decision) ? DECISION_LABEL[r.decision] : r.decision)) +
				(r.source ? ' (' + (SOURCE_LABEL[r.source] || r.source) + ')' : '');
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
				tds.push(cell(_('Actions'), this.actionsCell(r), 'cbi-section-actions'));
			return E('tr', { 'class': 'tr', 'data-domain': r.domain, 'data-decision': r.decision,
				'data-router': r.router ? 'true' : 'false' }, tds);
		});
		const placeholder = all.length ? _('No queries match the filter.') : _('No queries seen yet.');
		dom.content(this.queriesNode, [ dataTable(_('Last queries'), captions, trs, placeholder) ]);
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
		const r = model.stage(this.pending, op, domain, Math.floor(Date.now() / 1000));
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
				this.setPending(model.settleNoop(this.pending));
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
				this.setPending(model.settleNoop(this.pending));
				return;
			}
			this.setPending(model.beginInflight(this.pending, reply.job_id));
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
