'use strict';
'require view';
'require form';
'require rpc';
'require uci';
'require ui';

/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * Settings for /etc/config/adblock-fast-monitor (docs/CONTRACT.md §3).
 * Turning query logging on asks for confirmation when `info` reports that
 * the system log leaves RAM (logd-to-flash, logd-remote, §6.1).
 */

const callInfo = rpc.declare({ object: 'luci.adblock-fast-monitor', method: 'info' });

const RISK_TEXT = {
	'logd-to-flash': _('The system log is also written to a file on persistent storage (System → System → Logging → "Write system log to file"): every DNS query adds a write to that storage, which wears flash memory.'),
	'logd-remote': _('The system log is sent to a remote log server (System → System → Logging → "External system log server"): every DNS query, with the client address, is forwarded there.')
};

return view.extend({
	load() {
		return Promise.all([
			uci.load('adblock-fast-monitor'),
			L.resolveDefault(callInfo(), null)
		]);
	},

	render([ , info ]) {
		const m = new form.Map('adblock-fast-monitor', _('Adblock Fast Monitor'),
			_('This app runs no process on the router. While query logging is on, dnsmasq writes one line per DNS query to the system log; the dashboard reads those lines in your browser, only while it is open.'));

		const s = m.section(form.NamedSection, 'config', 'monitor', _('Query logging'));
		s.anonymous = true;
		s.addremove = false;

		const instances = (info && info.dnsmasq && Array.isArray(info.dnsmasq.instances)) ? info.dnsmasq.instances : [];
		if (instances.some(i => i && i.uci_logqueries === true))
			s.description = _('dnsmasq query logging is already on in the dnsmasq configuration (for example through luci-app-adblock-fast), so the dashboard works even with the option below off.');

		this.risks = ((info && Array.isArray(info.warnings)) ? info.warnings : []).filter(w => RISK_TEXT[w]);

		const o = s.option(form.Flag, 'query_logging', _('Log DNS queries'),
			_('Adds a runtime-only dnsmasq option (log-queries=extra); /etc/config/dhcp is not changed, but dnsmasq is restarted when this changes. Every DNS query is then written to the system log buffer, which pushes out other log messages sooner.') + ' ' +
			_('luci-app-adblock-fast has its own query-logging toggle; both may be enabled at the same time.'));
		o.default = '0';
		o.rmempty = false;
		this.flag = o;
		this.formMap = m;

		return m.render().then(node => {
			if (this.risks.length)
				node.insertBefore(E('div', { 'class': 'alert-message warning', 'id': 'abfm-logging-risks' },
					this.risks.map(w => E('p', { 'data-risk': w }, [ RISK_TEXT[w] ]))), node.firstChild);
			return node;
		});
	},

	/* true when this save turns query logging on while the log leaves RAM */
	needsConfirm() {
		if (!this.risks.length || !this.flag)
			return false;
		const now = this.flag.formvalue('config');
		return now == '1' && uci.get('adblock-fast-monitor', 'config', 'query_logging') != '1';
	},

	confirmed() {
		if (!this.needsConfirm())
			return Promise.resolve(true);
		return new Promise(resolve => {
			ui.showModal(_('Turn on DNS query logging?'), [
				E('div', { 'class': 'alert-message warning' }, this.risks.map(w => E('p', {}, [ RISK_TEXT[w] ]))),
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'cbi-button', 'click': () => { ui.hideModal(); resolve(false); } }, [ _('Cancel') ]), ' ',
					E('button', { 'class': 'cbi-button cbi-button-positive', 'id': 'abfm-confirm-logging',
						'click': () => { ui.hideModal(); resolve(true); } }, [ _('Turn on') ])
				])
			]);
		});
	},

	handleSave(ev) {
		return this.confirmed().then(ok => ok ? this.formMap.save() : null);
	},

	handleSaveApply(ev, mode) {
		return this.confirmed().then(ok => ok ? this.formMap.save().then(() => ui.changes.apply(mode == '0')) : null);
	}
});
