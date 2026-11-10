'use strict';
'require view';
'require form';
'require uci';

/* Settings for /etc/config/adblock-fast-monitor (docs/CONTRACT.md §3). */

/* Unsigned option with the §3 default (shown as placeholder) and range. */
function bounded(section, tab, name, title, def, min, max, description) {
	const o = section.taboption(tab, form.Value, name, title, description);
	o.datatype = 'range(%d,%d)'.format(min, max);
	o.placeholder = String(def);
	o.rmempty = true;
	return o;
}

return view.extend({
	load() {
		return Promise.all([
			uci.load('adblock-fast-monitor'),
			L.resolveDefault(uci.load('dhcp'), null)
		]);
	},

	render([ , dhcp ]) {
		const m = new form.Map('adblock-fast-monitor', _('Adblock Fast Monitor'),
			_('Saving restarts the monitor, which resets its statistics. dnsmasq is restarted only when the set of instances with monitor-managed query logging changes.'));

		const s = m.section(form.NamedSection, 'config', 'monitor', _('Monitoring'));
		s.anonymous = true;
		s.addremove = false;

		s.tab('general', _('General'));
		s.tab('advanced', _('Advanced'));

		let o = s.taboption('general', form.Flag, 'enabled', _('Enable monitoring'),
			_('Runs one small resident monitor process. When off, nothing runs and no query logging is added.'));
		o.default = '0';
		o.rmempty = false;

		o = s.taboption('general', form.Flag, 'manage_logging', _('Manage query logging'),
			_('Adds a runtime-only dnsmasq option (log-queries=extra) for the selected instances; /etc/config/dhcp is not changed. Every DNS query is then written to the system log buffer, which pushes out other log messages faster. Turn this off only if you enable dnsmasq query logging yourself.'));
		o.default = '1';
		o.rmempty = false;

		o = s.taboption('general', form.DynamicList, 'dnsmasq_instance', _('dnsmasq instances'),
			_('Instances that get query logging. "*" means every enabled instance.'));
		o.default = '*';
		o.value('*', _('All enabled instances (*)'));
		if (dhcp)
			uci.sections('dhcp', 'dnsmasq').forEach(sec => {
				o.value(sec['.name']);
			});
		o.depends('manage_logging', '1');

		bounded(s, 'general', 'poll_interval', _('Refresh interval'), 5, 2, 60,
			_('Seconds between dashboard refreshes while the page is visible (2–60).'));

		o = s.taboption('advanced', form.Flag, 'record_clients', _('Record clients'),
			_('Keep the address of the last client that queried each recent domain (in memory only).'));
		o.default = '0';
		o.rmempty = false;

		o = s.taboption('advanced', form.Flag, 'exclude_router', _('Ignore router queries'),
			_('Do not count queries from the router itself (127.0.0.1, ::1), such as adblock-fast checks and rule verification.'));
		o.default = '1';
		o.rmempty = false;

		[ [ 'recent_size', _('Recent domains kept'), 500, 50, 2000, _('Number of distinct domains in the "Last domains" list (50–2000).') ],
		  [ 'top_size', _('Top domains tracked'), 256, 32, 1024, _('Domains tracked for each top list (32–1024).') ],
		  [ 'pending_size', _('Unanswered queries kept'), 512, 64, 4096, _('Queries waiting for an answer (64–4096); more are counted as dropped.') ],
		  [ 'pending_ttl', _('Answer timeout'), 10, 2, 60, _('Seconds to wait for an answer before a query expires (2–60).') ]
		].forEach(([ name, title, def, min, max, descr ]) => bounded(s, 'advanced', name, title, def, min, max, descr));

		return m.render();
	}
});
