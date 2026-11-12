'use strict';
'require baseclass';
'require rpc';
'require adblock-fast-monitor.model as model';
'require adblock-fast-monitor.querylog as querylog';
'require adblock-fast-monitor.chart as chart';

/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * Status → Overview section (docs/CONTRACT.md §8.6): a card (LuCI's
 * .ifacebox, as the Port status and Network sections use) with the share of
 * recent DNS queries adblock-fast blocked, read from the system log in the
 * browser like the app's page. LuCI's status page calls load() for every section on each
 * of its polls (every 5 s), also in a hidden tab, so load() makes no request
 * while the tab is hidden or after 15 minutes without input (P0, P2), and
 * none for an account without this app's grant (it renders nothing then).
 */

const callLogRead = rpc.declare({ object: 'log', method: 'read', params: [ 'lines', 'stream', 'oneshot' ], reject: true });
const callInfo = rpc.declare({ object: 'luci.adblock-fast-monitor', method: 'info', reject: true });

const INFO_INTERVAL_MS = 30000;
const IDLE_PAUSE_MS = 15 * 60 * 1000;
const INPUT_EVENTS = [ 'pointerdown', 'pointermove', 'keydown', 'wheel', 'touchstart' ];
const PAGE = 'admin/services/adblock-fast-monitor';

function T(value) {
	return [ (value == null) ? '' : String(value) ];
}

return baseclass.extend({
	title: _('Adblock Fast Monitor'),

	__init__() {
		this.log = null;
		this.infoResult = null;
		this.infoAt = 0;
		this.denied = false;
		this.result = null;
		this.stoppedAt = null;
		this.lastInput = Date.now();
		const onInput = () => { this.lastInput = Date.now(); };
		INPUT_EVENTS.forEach(t => window.addEventListener(t, onInput, { passive: true, capture: true }));
	},

	/* Hidden or idle: the last result again, no request; the next visible poll asks for the gap once (§8.1 Resume). */
	load() {
		if (this.denied)
			return Promise.resolve(null);
		const now = Date.now();
		if (document.visibilityState != 'visible' || now - this.lastInput >= IDLE_PAUSE_MS) {
			if (this.stoppedAt == null)
				this.stoppedAt = now;
			return Promise.resolve(this.result ? Object.assign({}, this.result, { paused: now - this.lastInput >= IDLE_PAUSE_MS }) : null);
		}
		if (this.stoppedAt != null && this.log) {
			const interval = (+L.env.pollinterval || 5) * 1000;
			querylog.resume(this.log, Math.ceil((now - this.stoppedAt) / interval));
		}
		this.stoppedAt = null;

		const fresh = (!this.infoResult || now - this.infoAt >= INFO_INTERVAL_MS)
			? callInfo().then(model.settle, model.failure).then(r => { this.infoResult = r; this.infoAt = now; return r; })
			: Promise.resolve(this.infoResult);
		return fresh.then(info => {
			const st = model.pageState(info, { ok: true }, true).state;
			if (st == 'access-denied') {
				this.denied = true;
				return null;
			}
			if (st == 'adblock-fast-missing' || st == 'logging-off' || st == 'logging-unavailable' || !info.ok)
				return (this.result = { state: info.ok ? st : 'error' });
			if (!this.log)
				this.log = querylog.create({ max_rows: 500, pending_ttl_s: 10,
					local_domains: model.localDomains(info), hide_router: true });
			return callLogRead(querylog.nextRequest(this.log).lines, false, true).then(reply => {
				const r = querylog.ingest(this.log, reply) || {};
				return r.refetch ? callLogRead(r.refetch.lines, false, true).then(again => querylog.ingest(this.log, again)) : null;
			}).then(() => (this.result = { state: 'healthy',
				summary: model.summary(querylog.stats(this.log, { show_router: false }), model.dnsModeNote(info)) }),
			() => (this.result = { state: 'error' }));
		});
	},

	render(res) {
		if (!res)
			return null;
		const link = E('a', { 'href': L.url(PAGE) }, T(_('Open Adblock Fast Monitor')));
		const node = E('div', { 'id': 'abfm-status', 'data-state': res.state });
		if (res.state != 'healthy') {
			const text = {
				'logging-off': _('DNS query logging is off.'),
				'logging-unavailable': _('DNS query logging is not working.'),
				'adblock-fast-missing': _('adblock-fast is not installed.'),
				'error': _('The system log cannot be read.')
			}[res.state] || res.state;
			node.appendChild(E('p', {}, [ E('span', {}, T(text)), ' ', link ]));
			return node;
		}
		const s = res.summary;
		const donut = chart.donut(96);
		donut.update(s.pct, s.value, s.label || s.text);
		node.appendChild(E('div', { 'class': 'ifacebox', 'data-stat': 'blocked_pct',
			'style': 'margin:.25em 0;width:12em;white-space:normal' }, [
			E('div', { 'class': 'ifacebox-head' }, T(_('Blocked queries'))),
			E('div', { 'class': 'ifacebox-body' }, [
				donut.node,
				E('p', { 'data-stat': 'text' }, T(s.text)),
				res.paused ? E('p', { 'id': 'abfm-status-paused' }, T(_('Paused: this page has not been used for 15 minutes.'))) : '',
				E('p', {}, [ link ])
			])
		]));
		return node;
	}
});
