'use strict';

/* The DNS hot path is resident memory only. Snapshots are an in-process,
 * atomic coalesced publication at most once per interval, never per event. */
let fs = require('fs');

let state_dir = ARGV[1];
let capacity = +ARGV[2];
let events = [];
let counters = { allowed: 0, blocked: 0, unknown: 0, lost: 0 };
let generation = -1;
let started = time();
let dirty = false;
let last_snapshot = 0;
let snapshot_interval = 5;
let lock_file = fs.open(state_dir + '/monitor.lock', 'r+');

function read_generation() {
	let value = fs.readfile(state_dir + '/generation') || '0';
	value = +trim(value);
	return value >= 0 ? value : 0;
}

function load_snapshot_loss() {
	let status = fs.readfile(state_dir + '/status') || '';
	let match_loss = match(status, /(?:^|\n)lost=([0-9]+)/);
	return match_loss ? +match_loss[1] : 0;
}

function reset_if_purged() {
	let current = read_generation();
	if (current == generation)
		return;
	generation = current;
	events = [];
	counters = { allowed: 0, blocked: 0, unknown: 0, lost: load_snapshot_loss() };
	dirty = true;
}

function atomic_write(path, content) {
	let next = path + '.next';
	let file = fs.open(next, 'w');
	if (!file)
		return false;
	file.write(content);
	file.close();
	fs.chmod(next, 0600);
	return fs.rename(next, path);
}

function snapshot() {
	if (!dirty || time() - last_snapshot < snapshot_interval)
		return;
	if (!lock_file || !fs.flock(lock_file, 'ex'))
		return;

	/* Purge uses this same advisory lock. The generation check and both
	 * renames are one critical section, so an old ring cannot republish. */
	reset_if_purged();
	let status = 'state=running\nstarted=' + started + '\n' +
		'allowed=' + counters.allowed + '\nblocked=' + counters.blocked + '\n' +
		'unknown=' + counters.unknown + '\nlost=' + counters.lost + '\ncapacity=' + capacity +
		'\ngeneration=' + generation + '\n';
	let activity = '';
	for (let event in events)
		activity += event.timestamp + '\t' + event.decision + '\t' + event.domain + '\t' + event.reason + '\tunknown\n';
	if (atomic_write(state_dir + '/activity.tsv', activity) &&
		atomic_write(state_dir + '/status', status)) {
		dirty = false;
		last_snapshot = time();
	}
	fs.flock(lock_file, 'un');
}

function record(decision, domain, reason) {
	if (!match(domain, /^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$/))
		return;
	reset_if_purged();
	decision = decision == 'allowed' || decision == 'blocked' ? decision : 'unknown';
	push(events, { timestamp: time(), decision, domain, reason });
	counters[decision]++;
	if (length(events) > capacity) {
		let dropped = shift(events);
		counters[dropped.decision]--;
		counters.lost++;
	}
	dirty = true;
	snapshot();
}

generation = read_generation();
counters.lost = load_snapshot_loss();
let log = fs.popen('/sbin/logread -f', 'r');
while (true) {
	let line = log.read('line');
	if (line == null)
		break;
	let reply = match(line, /dnsmasq.*: reply ([^ ]+) is /);
	let config = match(line, /dnsmasq.*: config ([^ ]+) is /);
	if (reply)
		record('allowed', reply[1], 'reply');
	else if (config)
		record('unknown', config[1], 'config-response');
}
last_snapshot = 0;
snapshot();
