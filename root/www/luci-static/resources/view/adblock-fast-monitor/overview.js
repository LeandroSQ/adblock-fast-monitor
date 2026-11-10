'use strict';
'require view';
'require rpc';
'require uci';
'require ui';
'require form';
'require poll';
'require dom';
'require adblock-fast-monitor.model as model';

/*
 * Dashboard (docs/CONTRACT.md §8): health banner, cumulative statistics,
 * last/top domains with contextual rule actions, browser-side staging of
 * rule changes and one explicit Apply with job progress.
 * All dynamic text is inserted as text nodes (arrays passed to E()/dom).
 */

const callStatus = rpc.declare({ object: 'adblock-fast-monitor', method: 'status', reject: true });
const callDomains = rpc.declare({ object: 'adblock-fast-monitor', method: 'domains',
	params: [ 'view', 'decision', 'q', 'offset', 'limit' ], reject: true });
const callPurge = rpc.declare({ object: 'adblock-fast-monitor', method: 'purge', reject: true });
const callInfo = rpc.declare({ object: 'luci.adblock-fast-monitor', method: 'info', reject: true });
const callRules = rpc.declare({ object: 'luci.adblock-fast-monitor', method: 'rules', params: [ 'domains' ], reject: true });
const callApply = rpc.declare({ object: 'luci.adblock-fast-monitor', method: 'apply',
	params: [ 'ops', 'confirm_rebuild', 'rebuild', 'dry_run' ], reject: true });
const callJob = rpc.declare({ object: 'luci.adblock-fast-monitor', method: 'job', params: [ 'job_id' ], reject: true });

const PAGE_SIZE = 25;
const TOP_SIZE = 10;
const INFO_INTERVAL = 30;
const JOB_INTERVAL = 2;
const SETTINGS_PATH = 'admin/services/adblock-fast-monitor/settings';

const OP_LABEL = {
	allow: _('Allow'), unblock: _('Unblock'), block: _('Block'), unallow: _('Unallow')
};
const OP_BUTTON_CLASS = {
	allow: 'cbi-button cbi-button-positive', unblock: 'cbi-button cbi-button-neutral',
	block: 'cbi-button cbi-button-negative', unallow: 'cbi-button cbi-button-neutral'
};
const DECISION_LABEL = { blocked: _('Blocked'), allowed: _('Allowed'), other: _('Other') };
const SOURCE_LABEL = {
	config: _('dnsmasq rule'), addnhosts: _('adblock-fast hosts'), hosts: _('hosts file'),
	dhcp: _('DHCP lease'), local: _('local name'), error: _('upstream error'),
	upstream: _('upstream'), cache: _('cache'), auth: _('authoritative')
};
const STATE_TEXT = {
	'loading': [ _('Loading…'), null ],
	'access-denied': [ _('Access denied'), _('This account may not read the monitor status.') ],
	'adblock-fast-missing': [ _('adblock-fast is not installed'),
		_('Install the adblock-fast package; this dashboard only monitors and edits its rules.') ],
	'disabled': [ _('Monitoring is off'),
		_('Statistics are not collected and no monitor process runs. Rule changes below still work.') ],
	'starting': [ _('Monitor is starting…'), null ],
	'not-running': [ _('Monitor is not running'),
		_('Monitoring is enabled but the monitor service is not available. Check the system log for details:') ],
	'logging-unavailable': [ _('DNS query logging is unavailable'), null ],
	'degraded': [ _('Monitoring is degraded'), null ],
	'healthy': [ _('Monitoring is active'), null ],
	'error': [ _('Monitor status is unavailable'), null ]
};
const REASON_TEXT = {
	'dnsmasq-not-running': _('dnsmasq is not running.'),
	'dnsmasq-logs-to-file': _('dnsmasq writes its log to a file (log facility), so queries never reach the system log.'),
	'logging-not-active': _('No dnsmasq instance logs queries. Enable "Manage query logging" in Settings.'),
	'confdir-invalid': _('A dnsmasq instance has an invalid configuration directory, so query logging cannot be enabled for it.'),
	'input-overflow': _('The log reader overflowed in the last minute; some queries were not counted.'),
	'pending-overflow': _('Too many queries were waiting for an answer in the last minute; some were dropped.'),
	'dnsmasq-log-overflow': _('dnsmasq reported lost log entries in the last minute.'),
	'dns-mode-unsupported': _('adblock-fast blocks in the firewall in its current DNS mode (ipset/nftset), so blocks are not visible to the monitor.')
};
const WARNING_TEXT = {
	'query-logging-active': _('DNS query logging is active: every query is written to the system log buffer.'),
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
	'pending-uci-changes': _('adblock-fast has unsaved changes in LuCI; save or revert them first'),
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
		return Promise.all([
			L.resolveDefault(uci.load('adblock-fast-monitor'), null),
			callInfo().then(model.settle, model.failure),
			callStatus().then(model.settle, model.failure)
		]);
	},

	render([ , infoResult, statusResult ]) {
		this.canWrite = L.hasViewPermission() === true;
		this.uciEnabled = uci.get('adblock-fast-monitor', 'config', 'enabled') == '1';
		this.interval = model.pollInterval(uci.get('adblock-fast-monitor', 'config', 'poll_interval'));
		this.infoResult = infoResult;
		this.statusResult = null;
		this.lastStatus = null;
		this.lastOkAt = null;
		this.since = null;
		this.filter = { decision: '', q: '', offset: 0 };
		this.recent = null;
		this.tops = { top_blocked: null, top_allowed: null };
		this.topKeys = {};
		this.recentKey = null;
		this.rules = {};
		this.busy = {};
		this.again = {};
		this.stateKey = null;
		this.job = null;
		this.jobKey = null;
		this.dismissed = {};
		this.pending = model.parsePending(storageGet(model.STORAGE_KEY));
		this.polling = false;
		this.ticks = {
			main: L.bind(this.tick, this),
			info: L.bind(this.refreshInfo, this),
			job: L.bind(this.pollJob, this)
		};
		this.applyInfo(infoResult);

		const node = E('div', { 'class': 'cbi-map', 'id': 'abfm-overview' }, [
			E('h2', {}, T(_('Adblock Fast Monitor'))),
			E('div', { 'class': 'cbi-map-descr' }, T(_('DNS statistics and recently seen domains for adblock-fast. Rule changes are collected below and sent to adblock-fast together when you apply them.')))
		]);

		this.bannerNode = E('div', { 'id': 'abfm-health', 'role': 'status', 'aria-live': 'polite' });
		this.warningsNode = E('div', { 'id': 'abfm-warnings' });
		node.appendChild(this.bannerNode);
		node.appendChild(this.warningsNode);

		this.statsNode = E('div', { 'id': 'abfm-stats' });
		this.statsSection = E('div', { 'class': 'cbi-section', 'id': 'abfm-stats-section' }, [
			E('h3', {}, T(_('Statistics'))),
			this.statsNode
		]);
		if (this.canWrite)
			this.statsSection.appendChild(E('div', { 'class': 'right' }, [
				E('button', {
					'class': 'cbi-button cbi-button-reset',
					'click': ui.createHandlerFn(this, 'handlePurge')
				}, T(_('Reset statistics')))
			]));
		node.appendChild(this.statsSection);

		if (this.canWrite)
			node.appendChild(this.renderPendingSection());

		node.appendChild(this.renderRecentSection());

		this.topNodes = {
			top_blocked: E('div', { 'id': 'abfm-top-blocked' }),
			top_allowed: E('div', { 'id': 'abfm-top-allowed' })
		};
		node.appendChild(E('div', { 'class': 'cbi-section', 'id': 'abfm-top-section' }, [
			E('h3', {}, T(_('Top domains'))),
			E('div', { 'class': 'cbi-section-descr' }, T(_('Most frequent domains since the statistics were last reset (approximate counts).'))),
			E('h4', {}, T(_('Top blocked'))), this.topNodes.top_blocked,
			E('h4', {}, T(_('Top allowed'))), this.topNodes.top_allowed
		]));

		this.applyStatus(statusResult);
		this.updateAll();

		document.addEventListener('visibilitychange', L.bind(this.handleVisibility, this));
		window.addEventListener('storage', L.bind(this.handleStorage, this));

		this.startPolling();
		if (this.shouldPollMonitor())
			this.refreshDomains(false);
		if (this.pending.inflight)
			this.watchJob(this.pending.inflight.job_id);
		else
			this.loadLatestJob();

		return node;
	},

	/* ---- polling ---------------------------------------------------------- */

	shouldPollMonitor() {
		const s = this.derived ? this.derived.state : 'loading';
		return s != 'access-denied' && s != 'adblock-fast-missing' && s != 'disabled';
	},

	startPolling() {
		if (this.polling || document.visibilityState == 'hidden')
			return;
		this.polling = true;
		poll.add(this.ticks.main, this.interval);
		poll.add(this.ticks.info, INFO_INTERVAL);
		if (this.job && !model.isTerminal(this.job))
			poll.add(this.ticks.job, JOB_INTERVAL);
	},

	stopPolling() {
		if (!this.polling)
			return;
		this.polling = false;
		poll.remove(this.ticks.main);
		poll.remove(this.ticks.info);
		poll.remove(this.ticks.job);
	},

	handleVisibility() {
		if (document.visibilityState == 'hidden')
			this.stopPolling();
		else
			this.startPolling();
	},

	handleStorage(ev) {
		if (ev.key != model.STORAGE_KEY)
			return;
		this.pending = model.parsePending(ev.newValue);
		this.updatePending();
		this.updateRecent();
		this.updateTops();
	},

	/*
	 * At most one request of each kind in flight. A forced call made while
	 * one is in flight discards that reply and refetches with current inputs.
	 */
	fetchOnce(kind, fn, apply, force) {
		if (this.busy[kind]) {
			if (force)
				this.again[kind] = true;
			return this.busy[kind];
		}
		const run = () => fn().then(model.settle, model.failure).then(res => {
			if (this.again[kind]) {
				this.again[kind] = false;
				return run();
			}
			this.busy[kind] = null;
			return apply(res);
		});
		this.busy[kind] = run();
		return this.busy[kind];
	},

	tick() {
		if (!this.shouldPollMonitor())
			return Promise.resolve();
		return Promise.all([ this.refreshStatus(), this.refreshDomains(false) ]);
	},

	refreshInfo() {
		return this.fetchOnce('info', () => callInfo(), res => {
			const wasPolling = this.shouldPollMonitor();
			this.infoResult = res;
			this.applyInfo(res);
			this.updateBanner();
			this.updateWarnings();
			if (!wasPolling && this.shouldPollMonitor())
				return this.tick();
		});
	},

	applyInfo(res) {
		const data = (res && res.ok) ? res.data : null;
		if (data && data.monitor && typeof(data.monitor.enabled) == 'boolean')
			this.uciEnabled = data.monitor.enabled;
		this.info = data;
		this.derive();
	},

	refreshStatus() {
		return this.fetchOnce('status', () => callStatus(), res => {
			this.applyStatus(res);
			this.updateBanner();
			this.updateStats();
		});
	},

	applyStatus(res) {
		const now = Math.floor(Date.now() / 1000);
		this.statusResult = res;
		this.since = model.missingSince(this.since, res, now);
		if (res && res.ok && res.data && res.data.ok !== false) {
			this.lastStatus = res.data;
			this.lastOkAt = now;
		}
		else if (res && res.ok && res.data && res.data.ok === false) {
			this.statusResult = { ok: false, rpc: null, message: (res.data.error && res.data.error.message) || 'error' };
		}
		this.derive();
	},

	derive() {
		const now = Math.floor(Date.now() / 1000);
		const status = (this.statusResult && !this.statusResult.ok && this.statusResult.rpc !== model.OBJECT_MISSING && this.lastStatus)
			? model.settle(this.lastStatus) : this.statusResult;
		this.derived = model.deriveState(this.uciEnabled, this.infoResult, status, now, this.since);
		this.stale = this.lastStatus != null && this.derived.state != 'disabled' &&
			model.isStale(this.lastOkAt, now, this.interval);
	},

	refreshDomains(force) {
		if (this.statusResult && !this.statusResult.ok && this.statusResult.rpc === model.OBJECT_MISSING && !force)
			return Promise.resolve();
		const recent = this.fetchOnce('recent', () => callDomains('recent',
			this.filter.decision || undefined, this.filter.q || undefined, this.filter.offset, PAGE_SIZE), res => {
			if (res.ok && res.data && res.data.ok !== false)
				this.recent = res.data;
			else if (!res.ok && res.rpc === model.OBJECT_MISSING)
				this.recent = null;
			this.updateRecent();
		}, force);
		const tops = [ 'top_blocked', 'top_allowed' ].map(v => this.fetchOnce(v,
			() => callDomains(v, undefined, undefined, 0, TOP_SIZE), res => {
				if (res.ok && res.data && res.data.ok !== false)
					this.tops[v] = res.data;
				else if (!res.ok && res.rpc === model.OBJECT_MISSING)
					this.tops[v] = null;
				this.updateTops();
			}));
		return Promise.all([ recent ].concat(tops)).then(() => this.refreshRules());
	},

	visibleDomains() {
		const out = [];
		const add = d => { if (typeof(d) == 'string' && out.indexOf(d) < 0) out.push(d); };
		((this.recent && this.recent.items) || []).forEach(i => add(i.domain));
		[ 'top_blocked', 'top_allowed' ].forEach(v => ((this.tops[v] && this.tops[v].items) || []).forEach(i => add(i.domain)));
		return out.slice(0, 50);
	},

	/* Rules for visible rows that have none yet; the cache keeps only visible rows. */
	refreshRules(force) {
		const visible = this.visibleDomains();
		const kept = {};
		visible.forEach(d => { if (this.rules[d] && !force) kept[d] = this.rules[d]; });
		this.rules = kept;
		const missing = visible.filter(d => !this.rules[d]);
		if (!missing.length)
			return Promise.resolve();
		return this.fetchOnce('rules', () => callRules(missing), res => {
			if (res.ok && res.data && res.data.ok !== false && res.data.domains)
				for (const d in res.data.domains)
					this.rules[d] = res.data.domains[d];
			this.updateRecent();
			this.updateTops();
		});
	},

	/* ---- banner, warnings, stats --------------------------------------------- */

	updateAll() {
		this.updateBanner();
		this.updateWarnings();
		this.updateStats();
		this.updatePending();
		this.updateRecent();
		this.updateTops();
	},

	updateBanner() {
		this.derive();
		const d = this.derived;
		const key = [ d.state, d.reasons.join(','), this.stale ? this.lastOkAt : '' ].join('|');
		if (key == this.stateKey)
			return;
		this.stateKey = key;

		const text = STATE_TEXT[d.state] || [ d.state, null ];
		const children = [ E('strong', {}, T(text[0])) ];
		if (d.state == 'starting')
			children[0] = E('strong', { 'class': 'spinning' }, T(text[0]));
		if (text[1])
			children.push(E('p', {}, T(text[1])));
		if (d.state == 'not-running')
			children.push(E('p', {}, [ E('code', {}, T('logread -e adblock-fast-monitor')) ]));
		if (d.state == 'error' && d.message)
			children.push(E('p', {}, T(d.message)));
		if (d.reasons.length)
			children.push(E('ul', {}, d.reasons.map(r => E('li', { 'data-reason': r }, T(REASON_TEXT[r] || r)))));
		if (d.state == 'disabled' || d.state == 'not-running' || (d.state == 'logging-unavailable' && d.reasons[0] == 'logging-not-active'))
			children.push(E('p', {}, [ E('a', { 'href': L.url(SETTINGS_PATH) }, T(_('Open settings'))) ]));
		if (this.stale)
			children.push(E('p', { 'class': 'abfm-stale' },
				T(_('Data is stale since %s; showing the last known values.').format(model.formatTime(this.lastOkAt)))));

		const severity = this.stale && d.state == 'healthy' ? 'warning' : model.stateSeverity(d.state);
		this.bannerNode.className = 'alert-message ' + severity;
		this.bannerNode.setAttribute('data-state', d.state);
		this.bannerNode.setAttribute('data-stale', this.stale ? 'true' : 'false');
		dom.content(this.bannerNode, children);

		const dim = this.stale || d.state == 'logging-unavailable';
		this.statsSection.style.opacity = dim ? '0.6' : '';
		this.statsSection.setAttribute('aria-disabled', dim ? 'true' : 'false');
	},

	updateWarnings() {
		const warnings = (this.info && Array.isArray(this.info.warnings)) ? this.info.warnings : [];
		const shown = warnings.filter(w => !this.dismissed[w]);
		dom.content(this.warningsNode, shown.map(w => E('div', { 'class': 'alert-message notice', 'data-warning': w }, [
			E('span', {}, T(WARNING_TEXT[w] || w)), ' ',
			E('button', {
				'class': 'cbi-button cbi-button-neutral',
				'aria-label': _('Dismiss note'),
				'click': () => { this.dismissed[w] = true; this.updateWarnings(); }
			}, T(_('Dismiss')))
		])));
	},

	updateStats() {
		const s = this.lastStatus;
		if (!s || !s.counters) {
			dom.content(this.statsNode, [ E('p', { 'class': 'cbi-section-descr' },
				T(this.derived.state == 'disabled' ? _('No statistics while monitoring is off.') : _('No statistics available.'))) ]);
			return;
		}
		const c = s.counters, daemon = s.daemon || {};
		const drops = model.sumDrops(c);
		const d = c.dropped || {};
		const age = (daemon.now && daemon.stats_since) ? daemon.now - daemon.stats_since : null;
		const rows = [
			[ _('Queries'), model.formatCount(c.queries), 'queries' ],
			[ _('Blocked'), model.formatCount(c.blocked), 'blocked' ],
			[ _('Block rate'), model.formatPct(s.block_pct), 'block_pct' ],
			[ _('Allowed'), model.formatCount(c.allowed), 'allowed' ],
			[ _('Other answers'), model.formatCount(c.other), 'other' ],
			[ _('Dropped'), model.formatCount(drops) + (drops ? ' ' + _('(log reader %d, waiting queries %d, dnsmasq %d)')
				.format(d.input_overflow || 0, d.pending_evicted || 0, d.dnsmasq_reported || 0) : ''), 'drops' ],
			[ _('Counting since'), model.formatTime(daemon.stats_since) + (age != null ? ' ' + _('(%s)').format(model.formatDuration(age)) : ''), 'since' ],
			[ _('Last query'), s.last_event_at ? _('%s ago').format(model.formatDuration((daemon.now || s.last_event_at) - s.last_event_at)) : '—', 'last_event' ]
		];
		dom.content(this.statsNode, [ E('table', { 'class': 'table', 'aria-label': _('Statistics') },
			rows.map(r => E('tr', { 'class': 'tr', 'data-stat': r[2] }, [
				E('th', { 'class': 'td left', 'scope': 'row', 'width': '33%' }, T(r[0])),
				E('td', { 'class': 'td left' }, T(r[1]))
			]))) ]);
	},

	handlePurge() {
		return new Promise(resolve => {
			ui.showModal(_('Reset statistics'), [
				E('p', {}, T(_('All counters, recent domains and top domains are cleared. DNS and adblock-fast are not affected.'))),
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'cbi-button', 'click': () => { ui.hideModal(); resolve(); } }, T(_('Cancel'))), ' ',
					E('button', { 'class': 'cbi-button cbi-button-negative', 'click': () => {
						ui.hideModal();
						callPurge().then(r => {
							if (r && r.ok === false)
								throw new Error((r.error && r.error.message) || 'purge failed');
							this.recent = null;
							return Promise.all([ this.refreshStatus(), this.refreshDomains(true) ]);
						}).catch(e => ui.addNotification(null, E('p', {}, T(_('Could not reset statistics: %s').format(e.message))), 'danger'))
							.finally(resolve);
					} }, T(_('Reset')))
				])
			]);
		});
	},

	/* ---- domain rows ---------------------------------------------------------- */

	ruleText(rule) {
		if (!rule)
			return '';
		if (rule.manual == 'block')
			return _('Manual block');
		if (rule.manual == 'allow')
			return _('Manual allow');
		if (rule.manual_parent && rule.manual_parent.domain)
			return (rule.manual_parent.list == 'allow' ? _('Allowed via %s') : _('Blocked via %s')).format(rule.manual_parent.domain);
		if (rule.listed === true)
			return _('On a block list');
		return '';
	},

	actionsCell(domain) {
		if (!this.canWrite)
			return null;
		const staged = model.pendingOp(this.pending, domain);
		const inflight = this.pending.inflight && this.pending.inflight.items.some(i => i.domain == domain);
		const out = [];
		if (inflight) {
			out.push(E('em', {}, T(_('Applying…'))));
			return out;
		}
		if (staged) {
			out.push(E('span', { 'class': 'abfm-staged' }, T(_('Pending: %s').format(OP_LABEL[staged])))), out.push(' ');
			out.push(E('button', {
				'class': 'cbi-button cbi-button-neutral',
				'aria-label': _('Cancel pending change for %s').format(domain),
				'click': () => this.unstageDomain(domain)
			}, T(_('Cancel'))));
			return out;
		}
		model.rowActions(this.rules[domain]).forEach(op => {
			out.push(E('button', {
				'class': OP_BUTTON_CLASS[op],
				'data-op': op,
				'aria-label': _('%s %s').format(OP_LABEL[op], domain),
				'click': () => this.stageOp(op, domain)
			}, T(OP_LABEL[op])), ' ');
		});
		return out;
	},

	renderRecentSection() {
		const decision = E('select', { 'id': 'abfm-filter-decision', 'class': 'cbi-input-select',
			'change': ev => this.setFilter({ decision: ev.target.value }) }, [
			E('option', { 'value': '' }, T(_('All'))),
			E('option', { 'value': 'blocked' }, T(_('Blocked'))),
			E('option', { 'value': 'allowed' }, T(_('Allowed'))),
			E('option', { 'value': 'other' }, T(_('Other')))
		]);
		this.searchHint = E('span', { 'id': 'abfm-search-hint', 'class': 'cbi-value-description', 'aria-live': 'polite' });
		let timer = null;
		const search = E('input', { 'id': 'abfm-filter-q', 'class': 'cbi-input-text', 'type': 'search',
			'maxlength': 64, 'placeholder': _('part of a domain'), 'aria-describedby': 'abfm-search-hint',
			'input': ev => {
				window.clearTimeout(timer);
				const value = ev.target.value;
				timer = window.setTimeout(() => {
					const q = model.searchQuery(value);
					if (q == null) {
						dom.content(this.searchHint, T(_('Use letters, digits, ".", "-" or "_" only.')));
						return;
					}
					dom.content(this.searchHint, []);
					if (q != this.filter.q)
						this.setFilter({ q: q });
				}, 300);
			} });
		this.recentNode = E('div', { 'id': 'abfm-recent' });
		this.pagerNode = E('div', { 'id': 'abfm-pager', 'class': 'right' });

		const children = [
			E('h3', {}, T(_('Last domains'))),
			E('div', { 'class': 'cbi-section-descr' }, T(_('Each domain appears once, with its latest answer. A, AAAA and HTTPS lookups are counted together.')))
		];
		const filters = E('div', { 'class': 'cbi-section-node abfm-filters' }, [
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title', 'for': 'abfm-filter-decision' }, T(_('Show'))),
				E('div', { 'class': 'cbi-value-field' }, [ decision ])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title', 'for': 'abfm-filter-q' }, T(_('Search'))),
				E('div', { 'class': 'cbi-value-field' }, [ search, ' ', this.searchHint ])
			])
		]);
		children.push(filters, this.recentNode, this.pagerNode);
		return E('div', { 'class': 'cbi-section', 'id': 'abfm-recent-section' }, children);
	},

	setFilter(change) {
		Object.assign(this.filter, change);
		if (!('offset' in change))
			this.filter.offset = 0;
		this.rules = {};
		return this.refreshDomains(true);
	},

	/* Rows are rebuilt only when what they show changed, so focus survives refreshes. */
	rowsKey(items) {
		return JSON.stringify([ items, items.map(i => [ this.rules[i.domain] || null, model.pendingOp(this.pending, i.domain) ]),
			this.pending.inflight, this.derived.state ]);
	},

	updateRecent() {
		if (!this.recentNode)
			return;
		const r = this.recent;
		const items = (r && Array.isArray(r.items)) ? r.items : [];
		const key = this.rowsKey(items) + JSON.stringify([ r && r.total, this.filter ]);
		if (key == this.recentKey)
			return;
		this.recentKey = key;
		const showClient = items.some(i => i.client);
		const captions = [ _('Domain'), _('Last answer'), _('Source'), _('Queries'), _('Types'), _('Last seen') ];
		if (showClient)
			captions.push(_('Client'));
		captions.push(_('Rule'));
		if (this.canWrite)
			captions.push(_('Actions'));

		const rows = items.map(i => {
			const tds = [
				cell(_('Domain'), T(i.domain), 'abfm-domain'),
				cell(_('Last answer'), T(DECISION_LABEL[i.decision] || i.decision)),
				cell(_('Source'), T(SOURCE_LABEL[i.source] || i.source)),
				cell(_('Queries'), [ E('span', { 'title': _('%d blocked, %d allowed').format(i.blocked || 0, i.allowed || 0) },
					T(model.formatCount(i.count))) ]),
				cell(_('Types'), T((Array.isArray(i.qtypes) ? i.qtypes : []).join(', '))),
				cell(_('Last seen'), [ E('time', { 'title': _('First seen %s').format(model.formatTime(i.first_seen)) },
					T(model.formatTime(i.last_seen))) ])
			];
			if (showClient)
				tds.push(cell(_('Client'), T(i.client || '')));
			tds.push(cell(_('Rule'), T(this.ruleText(this.rules[i.domain]))));
			if (this.canWrite)
				tds.push(cell(_('Actions'), this.actionsCell(i.domain), 'cbi-section-actions'));
			return E('tr', { 'class': 'tr', 'data-domain': i.domain, 'data-decision': i.decision }, tds);
		});

		let placeholder = _('No domains seen yet.');
		if (!r)
			placeholder = this.derived.state == 'disabled' ? _('Monitoring is off.') : _('No data available.');
		else if (this.filter.q || this.filter.decision)
			placeholder = _('No domains match the filter.');
		dom.content(this.recentNode, [ dataTable(_('Last domains'), captions, rows, placeholder) ]);

		const page = model.pageInfo(r ? r.total : 0, this.filter.offset, PAGE_SIZE);
		dom.content(this.pagerNode, [
			E('span', { 'id': 'abfm-page-info' }, T(_('%d–%d of %d').format(page.first, page.last, page.total))), ' ',
			E('button', { 'class': 'cbi-button', 'disabled': page.hasPrev ? null : '',
				'click': () => this.setFilter({ offset: page.prevOffset }) }, T(_('Previous page'))), ' ',
			E('button', { 'class': 'cbi-button', 'disabled': page.hasNext ? null : '',
				'click': () => this.setFilter({ offset: page.nextOffset }) }, T(_('Next page')))
		]);
	},

	updateTops() {
		[ 'top_blocked', 'top_allowed' ].forEach(v => {
			if (!this.topNodes)
				return;
			const t = this.tops[v];
			const items = (t && Array.isArray(t.items)) ? t.items : [];
			const key = this.rowsKey(items);
			if (key == this.topKeys[v])
				return;
			this.topKeys[v] = key;
			const label = (v == 'top_blocked') ? _('Top blocked') : _('Top allowed');
			const captions = [ _('Domain'), _('Queries'), _('Rule') ];
			if (this.canWrite)
				captions.push(_('Actions'));
			const rows = items.map(i => {
				const tds = [
					cell(_('Domain'), T(i.domain), 'abfm-domain'),
					cell(_('Queries'), [ E('span', { 'title': i.error ? _('may be overestimated by up to %d').format(i.error) : null },
						T(model.formatCount(i.count))) ]),
					cell(_('Rule'), T(this.ruleText(this.rules[i.domain])))
				];
				if (this.canWrite)
					tds.push(cell(_('Actions'), this.actionsCell(i.domain), 'cbi-section-actions'));
				return E('tr', { 'class': 'tr', 'data-domain': i.domain }, tds);
			});
			dom.content(this.topNodes[v], [ dataTable(label, captions, rows, _('No domains yet.')) ]);
		});
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
		this.updateRecent();
		this.updateTops();
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
		const op = E('select', { 'id': 'abfm-add-op', 'class': 'cbi-input-select' },
			model.OPS.map(o => E('option', { 'value': o, 'selected': (o == 'block') ? '' : null }, T(OP_LABEL[o]))));
		const add = E('button', { 'class': 'cbi-button cbi-button-add', 'id': 'abfm-add',
			'click': () => { if (this.stageOp(op.value, input.value)) input.value = ''; } }, T(_('Add to pending')));
		input.addEventListener('keydown', ev => { if (ev.key == 'Enter') add.click(); });

		return E('div', { 'class': 'cbi-section', 'id': 'abfm-pending-section' }, [
			E('h3', {}, T(_('Pending changes'))),
			E('div', { 'class': 'cbi-section-descr' }, T(_('Changes are kept in this browser until you apply them. Apply sends all of them at once and rebuilds the adblock-fast block lists one time.'))),
			this.pendingNode,
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title', 'for': 'abfm-add-domain' }, T(_('Domain'))),
				E('div', { 'class': 'cbi-value-field' }, [
					input, ' ',
					E('label', { 'for': 'abfm-add-op', 'class': 'abfm-visually-hidden', 'style': 'position:absolute;left:-10000px' }, T(_('Change'))),
					op, ' ', add
				])
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
		const blocked = !items.length || !!this.pending.inflight || !!this.applying;
		this.applyButton.disabled = blocked;
		this.discardButton.disabled = !items.length;
		this.updateJob();
	},

	/* ---- apply ------------------------------------------------------------------------ */

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
		ui.addNotification(null, E('p', {}, T(_('Changes were not applied: %s').format(
			errorText(e.code, e.message) + (e.domain ? ' (' + e.domain + ')' : '')))), 'danger');
	},

	confirmModal(plan) {
		const lines = [ _('This rebuilds the adblock-fast block lists: all lists are downloaded again over the WAN, DNS is restarted, and it may take minutes.') ];
		const list = (plan.plan || []).filter(p => Array.isArray(p.change) && p.change.length).map(p =>
			E('li', {}, T(p.effective_op && p.effective_op != p.op
				? _('%s %s (applied as %s)').format(OP_LABEL[p.op] || p.op, p.domain, OP_LABEL[p.effective_op] || p.effective_op)
				: _('%s %s').format(OP_LABEL[p.op] || p.op, p.domain))));
		return new Promise(resolve => {
			ui.showModal(_('Apply changes'), [
				E('div', { 'class': 'alert-message warning' }, lines.map(l => E('p', {}, T(l)))),
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
					return this.confirmModal(model.applyPlan(reply))
						.then(ok => ok ? this.submit(ops, true) : null);
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

	pollJob() {
		const id = this.watchedJob;
		if (!id)
			return Promise.resolve();
		return this.fetchOnce('job', () => callJob(id), res => {
			if (res.ok && res.data && res.data.ok === false && res.data.error && res.data.error.code == 'not-found') {
				poll.remove(this.ticks.job);
				this.watchedJob = null;
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
				poll.remove(this.ticks.job);
				this.watchedJob = null;
				this.finishJob(this.job);
			}
			this.updateJob();
		});
	},

	finishJob(job) {
		const inflight = this.pending.inflight;
		if (!inflight || inflight.job_id != job.id)
			return;
		const r = model.settleJob(this.pending, job);
		this.setPending(r.state);
		this.rules = {};
		this.refreshRules();
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
			E('p', { 'id': 'abfm-job-state', 'data-state': job.state, 'class': terminal ? '' : 'spinning' }, T(parts.join(' · ')))
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
					cell(_('Change'), T((OP_LABEL[i.op] || i.op) + (i.effective_op && i.effective_op != i.op ? ' → ' + (OP_LABEL[i.effective_op] || i.effective_op) : ''))),
					cell(_('Expected'), T(i.expect || '')),
					cell(_('Observed'), T(i.observed || '')),
					cell(_('Result'), T(RESULT_TEXT[i.result] || i.result || '')),
					cell(_('Reason'), T(i.reason ? errorText(i.reason) : ''))
				])), ''));
		dom.content(this.jobNode, children);
	}
});
