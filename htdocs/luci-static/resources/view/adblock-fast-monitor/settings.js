'use strict';
'require view';
'require form';
'require rpc';
'require uci';

/* Settings for /etc/config/adblock-fast-monitor (docs/CONTRACT.md §3). */

const callInfo = rpc.declare({ object: 'luci.adblock-fast-monitor', method: 'info' });

return view.extend({
	load() {
		return Promise.all([
			uci.load('adblock-fast-monitor'),
			L.resolveDefault(callInfo(), null)
		]);
	},

	render([ , info ]) {
		const m = new form.Map('adblock-fast-monitor', _('Adblock Fast Monitor'),
			_('No process of this app runs on the router: the dashboard reads the DNS queries from the system log in your browser, only while it is open.'));

		const s = m.section(form.NamedSection, 'config', 'monitor', _('Query logging'));
		s.anonymous = true;
		s.addremove = false;

		const instances = (info && info.dnsmasq && Array.isArray(info.dnsmasq.instances)) ? info.dnsmasq.instances : [];
		if (instances.some(i => i && i.uci_logqueries === true))
			s.description = _('dnsmasq query logging is already on in the dnsmasq configuration (for example through luci-app-adblock-fast), so the dashboard works even with the option below off.');

		const o = s.option(form.Flag, 'query_logging', _('Log DNS queries'),
			_('Adds a runtime-only dnsmasq option (log-queries=extra); /etc/config/dhcp is not changed, but dnsmasq is restarted when this changes. Every DNS query is then written to the system log buffer, which pushes out other log messages sooner.') + ' ' +
			_('luci-app-adblock-fast has its own query-logging toggle; both may be enabled at the same time.'));
		o.default = '0';
		o.rmempty = false;

		return m.render();
	}
});
