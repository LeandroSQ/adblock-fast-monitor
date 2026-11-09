'use strict';
'require view';
'require form';

return view.extend({
	render() {
		const map = new form.Map('adblock-fast-monitor', _('Adblock Fast Monitor'));
		const section = map.section(form.NamedSection, 'config', 'monitor', _('Collection settings'));

		section.option(form.Flag, 'enabled', _('Enable monitoring'));

		let option = section.option(form.Value, 'max_events', _('Maximum events'));
		option.datatype = 'uinteger';
		option.default = '256';
		option.description = _('Maximum number of in-memory activity records.');

		option = section.option(form.Value, 'poll_interval', _('Poll interval'));
		option.datatype = 'uinteger';
		option.default = '5';
		option.description = _('Seconds between collector polls.');

		option = section.option(form.Flag, 'own_logqueries', _('Manage dnsmasq log queries'));
		option.description = _('Only enable when this monitor may manage dnsmasq logging. dnsmasq expands the boolean setting to detailed query logging.');

		return map.render();
	}
});
