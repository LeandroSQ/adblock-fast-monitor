'use strict';

'require view';
'require form';
'require poll';
'require dom';
'require rpc';
'require session';
'require adblock-fast-monitor/model as model';

var callStatus = rpc.declare({
	object: 'adblock-fast-monitor',
	method: 'status',
	expect: {}
});

var callActivity = rpc.declare({
	object: 'adblock-fast-monitor',
	method: 'activity',
	params: [ 'cursor', 'limit', 'search', 'filter' ],
	expect: {}
});

var callPurge = rpc.declare({
	object: 'adblock-fast-monitor',
	method: 'purge',
	expect: {}
});

var PAGE_SIZE = 50;
var MAX_CURSOR_HISTORY = 20;

function node(tag, attrs, children) {
	return E(tag, attrs || {}, children || []);
}

function textNode(value) {
	return document.createTextNode(model.text(value, ''));
}

function labelForHealth(status) {
	var labels = {
		disabled: _('Disabled'),
		degraded: _('Degraded'),
		stale: _('Stale'),
		error: _('Error'),
		pending: _('Pending'),
		applying: _('Applying'),
		applied: _('Applied'),
		failed: _('Failed'),
		healthy: _('Healthy'),
		unknown: _('Unknown')
	};

	return labels[status.state] || labels.unknown;
}

return view.extend({
	load: function() {
		return session.access('ubus', 'adblock-fast-monitor', 'purge');
	},

	_makeFilterForm: function() {
		/*
		 * JSONMap keeps this view within LuCI's form lifecycle without writing
		 * monitor filters to UCI. Its options are rendered as native controls.
		 */
		var map = new form.JSONMap({ monitor: {} }, null, null);
		var section = map.section(form.NamedSection, 'monitor', 'monitor');
		var search = section.option(form.Value, 'search', _('Search activity'));
		var filter = section.option(form.ListValue, 'filter', _('Show'));

		search.placeholder = _('Domain, message, or event');
		search.rmempty = true;
		filter.value('', _('All activity'));
		filter.value('blocked', _('Blocked'));
		filter.value('allowed', _('Allowed domains'));
		filter.value('unknown', _('Unclassified / lost'));

		return map.render().then(L.bind(function(rendered) {
			var input = rendered.querySelector('input');
			var select = rendered.querySelector('select');

			input.value = this.query;
			select.value = this.filter;
			input.addEventListener('input', L.bind(this._queueSearch, this));
			select.addEventListener('change', L.bind(function(ev) {
				this.filter = ev.target.value;
				this._resetPaging();
				this.refresh();
			}, this));

			return rendered;
		}, this));
	},

	_resetPaging: function() {
		this.cursor = null;
		this.cursorHistory = [];
	},

	_queueSearch: function(ev) {
		window.clearTimeout(this.searchTimer);
		this.searchTimer = window.setTimeout(L.bind(function() {
			this.query = ev.target.value;
			this._resetPaging();
			this.refresh();
		}, this), 250);
	},

	_setMessage: function(message, type) {
		dom.content(this.messageNode, message ? [
			node('p', { 'class': 'alert-message ' + (type || '') }, [ textNode(message) ])
		] : []);
	},

	_renderStatus: function(status) {
		var health = labelForHealth(status);
		var stateClass = model.stateClass(status.state);

		dom.content(this.statusNode, [
			node('div', { 'class': 'cbi-section-node' }, [
				node('div', { 'class': 'cbi-value' }, [
					node('label', { 'class': 'cbi-value-title' }, [ textNode(_('Service health')) ]),
					node('div', { 'class': 'cbi-value-field' }, [
						node('span', { 'class': 'label ' + stateClass }, [ textNode(health) ])
					])
				]),
				node('div', { 'class': 'cbi-value' }, [
					node('label', { 'class': 'cbi-value-title' }, [ textNode(_('Coverage')) ]),
					node('div', { 'class': 'cbi-value-field' }, [
						node('div', { 'class': 'progress' }, [
							node('div', {
								'class': 'progress-bar',
								'style': 'width: ' + status.coverage + '%',
								'role': 'progressbar',
								'aria-valuemin': '0',
								'aria-valuemax': '100',
								'aria-valuenow': String(status.coverage),
								'aria-label': _('Coverage')
							})
						]),
						node('span', { 'class': 'cbi-value-description' }, [
							textNode(_('%d%% covered').format(status.coverage))
						])
					])
				]),
				node('div', { 'class': 'cbi-value' }, [
					node('label', { 'class': 'cbi-value-title' }, [ textNode(_('Blocked domains')) ]),
					node('div', { 'class': 'cbi-value-field' }, [ textNode(status.blocked) ])
				]),
				node('div', { 'class': 'cbi-value' }, [
					node('label', { 'class': 'cbi-value-title' }, [ textNode(_('Allowed domains')) ]),
					node('div', { 'class': 'cbi-value-field' }, [ textNode(status.allowed) ])
				]),
				node('div', { 'class': 'cbi-value' }, [
					node('label', { 'class': 'cbi-value-title' }, [ textNode(_('Unclassified / lost')) ]),
					node('div', { 'class': 'cbi-value-field' }, [
						textNode('%d / %d'.format(status.unknown, status.lost))
					])
				]),
				node('div', { 'class': 'cbi-value' }, [
					node('label', { 'class': 'cbi-value-title' }, [ textNode(_('Started')) ]),
					node('div', { 'class': 'cbi-value-field' }, [ textNode(status.started) ])
				])
			])
		]);

	},

	_renderActivity: function(page) {
		var rows = page.events.map(L.bind(function(entry) {
			return node('tr', {}, [
				node('td', { 'data-title': _('Time') }, [ textNode(entry.time) ]),
				node('td', { 'data-title': _('Domain') }, [ textNode(entry.domain) ]),
				node('td', { 'data-title': _('Decision') }, [ textNode(entry.type) ]),
				node('td', { 'data-title': _('State') }, [ textNode(entry.state) ]),
				node('td', { 'data-title': _('Details') }, [ textNode(entry.message) ]),
				node('td', { 'data-title': _('Current rule') }, [ textNode(entry.ruleState || '-') ])
			]);
		}, this));

		if (!rows.length)
			rows.push(node('tr', {}, [
				node('td', { 'colspan': '6', 'class': 'cbi-section-node' }, [
					textNode(_('No activity matches the current filters.'))
				])
			]));

		dom.content(this.activityBody, rows);
		this.previousButton.disabled = this.cursorHistory.length === 0;
		this.nextButton.disabled = !page.nextCursor;
		this.nextCursor = page.nextCursor;
	},

	_previous: function() {
		if (!this.cursorHistory.length)
			return;
		this.cursor = this.cursorHistory.pop();
		return this.refresh();
	},

	_next: function() {
		if (!this.nextCursor)
			return;
		this.cursorHistory.push(this.cursor);
		if (this.cursorHistory.length > MAX_CURSOR_HISTORY)
			this.cursorHistory.shift();
		this.cursor = this.nextCursor;
		return this.refresh();
	},

	_purge: function() {
		if (!this.canPurge)
			return Promise.resolve();

		this.purgeButton.disabled = true;
		this._setMessage(_('Purging monitor data…'));
		return callPurge().then(L.bind(function(reply) {
			this._setMessage(_('Purge %s.').format(model.text(reply && reply.state, 'applied')), 'success');
			this._resetPaging();
			return this.refresh();
		}, this)).catch(L.bind(function(err) {
			this._setMessage(_('Purge failed: %s').format(err.message || err), 'error');
		}, this)).finally(L.bind(function() {
			this.purgeButton.disabled = false;
		}, this));
	},

	refresh: function() {
		if (document.hidden || this.refreshing)
			return Promise.resolve();

		var generation = ++this.generation;
		this.refreshing = true;
		this._setMessage(_('Refreshing monitor data…'));

		return Promise.all([
			callStatus(),
			callActivity(this.cursor, PAGE_SIZE, this.query, this.filter)
		]).then(L.bind(function(replies) {
			if (generation !== this.generation)
				return;

			var status = model.status(replies[0]);
			this._renderStatus(status);
			this._renderActivity(model.activity(replies[1]));
			this._setMessage(status.enabled === false ?
				_('Monitoring is disabled.') :
				(status.job ? _('Current job: %s').format(status.job) : ''));
		}, this)).catch(L.bind(function(err) {
			if (generation === this.generation)
				this._setMessage(_('Unable to load monitor data: %s').format(err.message || err), 'error');
		}, this)).finally(L.bind(function() {
			if (generation === this.generation)
				this.refreshing = false;
		}, this));
	},

	render: function(canPurge) {
		this.cursor = null;
		this.cursorHistory = [];
		this.nextCursor = null;
		this.query = '';
		this.filter = '';
		this.generation = 0;
		this.refreshing = false;

		this.statusNode = node('div', { 'class': 'cbi-section', 'aria-live': 'polite' }, [
			node('p', { 'class': 'spinning' }, [ textNode(_('Loading monitor status…')) ])
		]);
		this.messageNode = node('div', { 'role': 'status', 'aria-live': 'polite' });
		this.activityBody = node('tbody', {}, [
			node('tr', {}, [ node('td', { 'colspan': '6' }, [ textNode(_('Loading activity…')) ]) ])
		]);
		this.previousButton = node('button', { 'class': 'btn cbi-button', 'type': 'button',
			'disabled': 'disabled', 'click': ui.createHandlerFn(this, '_previous') }, [ textNode(_('Previous')) ]);
		this.nextButton = node('button', { 'class': 'btn cbi-button', 'type': 'button',
			'disabled': 'disabled', 'click': ui.createHandlerFn(this, '_next') }, [ textNode(_('Next')) ]);
		this.canPurge = canPurge === true;
		this.purgeButton = this.canPurge ? node('button', {
			'class': 'btn cbi-button cbi-button-negative',
			'type': 'button',
			'click': ui.createHandlerFn(this, '_purge')
		}, [ textNode(_('Purge activity')) ]) : null;
		return this._makeFilterForm().then(L.bind(function(filterForm) {
			var root = node('div', {}, [
				node('h2', {}, [ textNode(_('Adblock Fast Monitor')) ]),
				this.messageNode,
				node('div', { 'class': 'cbi-section' }, [
					node('h3', {}, [ textNode(_('Health and coverage')) ]),
					this.statusNode
				]),
				node('div', { 'class': 'cbi-section' }, [
					node('h3', {}, [ textNode(_('Activity filters')) ]),
					filterForm
				]),
				node('div', { 'class': 'cbi-section' }, [
					node('h3', {}, [ textNode(_('Newest activity')) ]),
					node('div', { 'class': 'cbi-section-node' }, [
						node('table', { 'class': 'table cbi-section-table', 'aria-label': _('Activity timeline') }, [
							node('thead', {}, [ node('tr', {}, [
								node('th', {}, [ textNode(_('Time')) ]),
								node('th', {}, [ textNode(_('Domain')) ]),
								node('th', {}, [ textNode(_('Decision')) ]),
								node('th', {}, [ textNode(_('State')) ]),
								node('th', {}, [ textNode(_('Details')) ]),
								node('th', {}, [ textNode(_('Current rule')) ])
							]) ]),
							this.activityBody
						])
					]),
					node('div', { 'class': 'right' }, this.canPurge ? [
						this.purgeButton, ' ', this.previousButton, ' ', this.nextButton
					] : [ this.previousButton, ' ', this.nextButton ])
				])
			]);

			document.addEventListener('visibilitychange', L.bind(function() {
				if (!document.hidden)
					this.refresh();
			}, this));
			poll.add(L.bind(this.refresh, this), 10);
			this.refresh();
			return root;
		}, this));
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
