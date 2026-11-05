'use strict';

/*
 * Pure response normalization shared by the monitor view and its contract
 * tests. Values returned by rpcd are treated as untrusted display data.
 */

function text(value, fallback) {
	if (value === null || value === undefined || value === '')
		return fallback || '-';

	return String(value);
}

function number(value, fallback) {
	value = Number(value);
	return isFinite(value) ? value : (fallback || 0);
}

function status(value) {
	value = value || {};
	var counters = value.counters || {};
	var allowed = number(counters.allowed, 0);
	var blocked = number(counters.blocked, 0);
	var unknown = number(counters.unknown, 0);
	var classified = allowed + blocked;
	var observed = classified + unknown;
	var state = text(value.state, 'unknown');

	return {
		state: state,
		enabled: state !== 'disabled',
		health: state,
		coverage: observed ? Math.round((classified * 100) / observed) : 0,
		allowed: allowed,
		blocked: blocked,
		unknown: unknown,
		lost: number(counters.lost, 0),
		capacity: number(value.capacity, 0),
		started: text(value.started, '-'),
		job: value.job || null,
		raw: value
	};
}

function event(value) {
	value = value || {};

	return {
		id: text(value.timestamp, ''),
		time: text(value.timestamp, '-'),
		domain: text(value.domain, '-'),
		type: text(value.decision, 'unknown'),
		state: text(value.decision, 'unknown'),
		message: text(value.reason, ''),
		current: value.current_rule === true,
		ruleState: text(value.current_rule, ''),
		raw: value
	};
}

function activity(value) {
	value = value || {};
	var entries = Array.isArray(value.events) ? value.events :
		(Array.isArray(value.activity) ? value.activity : []);

	return {
		events: entries.map(event),
		nextCursor: value.next_cursor || null,
		retained: number(value.retained, entries.length),
		lost: number(value.lost, 0)
	};
}

return {
	text: text,
	number: number,
	status: status,
	event: event,
	activity: activity
};
