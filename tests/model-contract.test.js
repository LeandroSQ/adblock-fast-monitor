'use strict';

const assert = require('assert');
const fs = require('fs');
const vm = require('vm');

const source = fs.readFileSync(
	'root/www/luci-static/resources/adblock-fast-monitor/model.js', 'utf8'
).replace(/^return \{/m, 'module.exports = {');

const sandbox = { module: { exports: {} }, isFinite: Number.isFinite, Number, String, Array };
vm.runInNewContext(source, sandbox, { filename: 'model.js' });
const model = sandbox.module.exports;

assert.deepStrictEqual(
	JSON.parse(JSON.stringify(model.status({ state: 'disabled', counters: { blocked: '4' } }))),
	{
		state: 'disabled', enabled: false, health: 'disabled', coverage: 100,
		allowed: 0, blocked: 4, unknown: 0, lost: 0, capacity: 0,
		started: '-', job: null,
		raw: { state: 'disabled', counters: { blocked: '4' } }
	}
);

const page = model.activity({
	activity: [{
		timestamp: '2026-11-05T12:00:00Z', domain: '<img src=x>', decision: 'blocked',
		current_rule: 'blocked'
	}],
	next_cursor: 'next'
});
assert.strictEqual(page.events[0].domain, '<img src=x>');
assert.strictEqual(page.nextCursor, 'next');
assert.strictEqual(page.events[0].ruleState, 'blocked');

const view = fs.readFileSync(
	'root/www/luci-static/resources/view/adblock-fast-monitor/overview.js', 'utf8'
);
assert.match(view, /document\.createTextNode/);
assert.doesNotMatch(view, /\.innerHTML\s*=/);
assert.match(view, /document\.hidden/);
assert.match(view, /MAX_CURSOR_HISTORY/);
assert.doesNotMatch(view, /method:\s*'action'/);
assert.match(view, /session\.access\('ubus', 'adblock-fast-monitor', 'purge'\)/);
assert.match(view, /this\.canPurge = canPurge === true/);
assert.match(view, /this\.canPurge \? \[/);

console.log('model and view contracts passed');
