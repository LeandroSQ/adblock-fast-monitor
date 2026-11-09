'use strict';

/* The DNS hot path is resident memory only. Snapshots are an in-process,
 * atomic coalesced publication at most once per interval, never per event. */
let fs = require('fs');
let io = require('io');
let uloop = require('uloop');

/* Stock ucode direct-script invocations expose user arguments at ARGV[0]. */
let state_dir = ARGV[0];
let capacity = +ARGV[1];
if (!state_dir || capacity < 1)
	exit(64);
let events = [];
let counters = { allowed: 0, blocked: 0, unknown: 0, lost: 0 };
let generation = -1;
let started = time();
let dirty = false;
let last_snapshot = 0;
let snapshot_interval = 5;
let snapshot_timer = null;
let lock_file = fs.open(state_dir + '/monitor.lock', 'r+');
let pending_queries = [];
let known_blocked = [];
let input_buffer = '';
let max_input_buffer = 65536;
let drain_budget = 16;

function read_generation() {
	let value = fs.readfile(state_dir + '/generation') || '0';
	value = +trim(value);
	return value >= 0 ? value : 0;
}

function load_snapshot_loss() {
	let status = fs.readfile(state_dir + '/status') || '';
	let match_loss = match(status, /(^|\n)lost=([0-9]+)/);
	return match_loss ? +match_loss[2] : 0;
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

function schedule_snapshot(retry_delay) {
	if (!snapshot_timer || !dirty)
		return;

	let delay = retry_delay || (last_snapshot + snapshot_interval - time()) * 1000;
	snapshot_timer.set(delay > 0 ? delay : 1);
}

function snapshot() {
	if (!dirty)
		return true;
	if (time() - last_snapshot < snapshot_interval)
		return false;
	if (!lock_file || !lock_file.lock('xn'))
		return false;

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
	lock_file.lock('u');
	return !dirty;
}

function record(decision, domain, reason) {
	let valid_domain = match(domain, /^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$/);
	if (!valid_domain)
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
	if (!snapshot())
		schedule_snapshot();
}

function remember_query(domain) {
	if (!match(domain, /^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$/))
		return;

	/* Keep correlation bounded too. A consumed entry is blanked rather than
	 * retaining a response that could authorize a later unrelated config line. */
	for (let entry in pending_queries) {
		if (!entry.domain) {
			entry.domain = domain;
			return;
		}
	}

	push(pending_queries, { domain });
	if (length(pending_queries) > capacity)
		shift(pending_queries);
}

function consume_query(domain) {
	for (let entry in pending_queries) {
		if (entry.domain == domain) {
			entry.domain = '';
			return true;
		}
	}
	return false;
}

function load_known_blocks() {
	let contents = fs.readfile(state_dir + '/known-blocked.tsv') || '';
	for (let domain in split(contents, '\n')) {
		if (match(domain, /^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$/))
			push(known_blocked, domain);
	}
}

function is_known_blocked(domain) {
	for (let known in known_blocked)
		if (known == domain)
			return true;
	return false;
}

function record_response(source, domain, answer) {
	if (!consume_query(domain)) {
		return;
	}
	if (match(answer, /^CNAME/)) {
		record('unknown', domain, 'cname-ambiguous');
		return;
	}
	if (source == 'config') {
		if (is_known_blocked(domain))
			record('blocked', domain, 'adblock-fast-config');
		else
			record('unknown', domain, 'local-config');
		return;
	}
	if (answer == 'NXDOMAIN')
		record('allowed', domain, source == 'cache' ? 'cached-nxdomain' : 'upstream-nxdomain');
	else
		record('allowed', domain, source == 'cache' ? 'cached-response' : 'upstream-reply');
}

generation = read_generation();
counters.lost = load_snapshot_loss();
load_known_blocks();
let log_pipe = io.pipe();
let log = log_pipe ? log_pipe[0] : null;
let log_writer = log_pipe ? log_pipe[1] : null;
let log_flags = log ? log.fcntl(io.F_GETFL) : null;
if (!log || log_flags == null ||
	!log.fcntl(io.F_SETFL, log_flags | io.O_NONBLOCK) ||
	!(log.fcntl(io.F_GETFL) & io.O_NONBLOCK) || !uloop.init()) {
	let error = io.error() || fs.error() || uloop.error();
	if (error)
		print('adblock-fast-monitor ring initialization failed: ' + error + '\n');
	exit(1);
}

function process_line(line) {
	/* Stock fs.popen() line reads can retain the record terminator. Normalize
	 * before applying end-anchored dnsmasq response patterns. */
	line = trim(line);
	/* Extra dnsmasq logging prefixes payloads with its query serial and client.
	 * Retain raw payload support for logread variants which omit that envelope. */
	let query = match(line, /(^|dnsmasq.*: )([0-9]+ [^ ]+ )?query\[([A-Z]+)\] ([^ ]+) from /);
	let config = match(line, /(^|dnsmasq.*: )([0-9]+ [^ ]+ )?config ([^ ]+) is (.+)$/);
	let reply = match(line, /(^|dnsmasq.*: )([0-9]+ [^ ]+ )?reply ([^ ]+) is (.+)$/);
	let cache = match(line, /(^|dnsmasq.*: )([0-9]+ [^ ]+ )?cached ([^ ]+) is (.+)$/);
	if (query) {
		remember_query(query[4]);
	}
	else if (config) {
		record_response('config', config[3], config[4]);
	}
	else if (reply) {
		record_response('reply', reply[3], reply[4]);
	}
	else if (cache) {
		record_response('cache', cache[3], cache[4]);
	}
}

function note_dropped_input() {
	counters.lost++;
	dirty = true;
	if (!snapshot())
		schedule_snapshot();
}

function drain_log() {
	for (let remaining = drain_budget; remaining > 0; remaining--) {
		let chunk = log.read(4096);
		if (chunk == null || chunk == '')
			return;

		input_buffer += chunk;
		if (length(input_buffer) > max_input_buffer) {
			let fragments = split(input_buffer, '\n');
			input_buffer = fragments[length(fragments) - 1];
			if (length(input_buffer) > max_input_buffer)
				input_buffer = '';
			note_dropped_input();
			continue;
		}

		let lines = split(input_buffer, '\n');
		input_buffer = lines[length(lines) - 1];
		for (let index = 0; index < length(lines) - 1; index++)
			process_line(lines[index]);
	}
}

let reader = uloop.handle(log, function(events) {
	drain_log();
}, uloop.ULOOP_READ);
let log_process = uloop.process(function(args, env) {
	log.close();
	log_writer.dup2(1);
	return [ '/sbin/logread', '-f' ];
}, [], null, function(code) {
	note_dropped_input();
});
if (log_writer)
	log_writer.close();
snapshot_timer = uloop.timer(-1, function() {
	if (!snapshot())
		schedule_snapshot(250);
});
if (!reader || !log_process || !snapshot_timer) {
	let error = uloop.error();
	if (error)
		print('adblock-fast-monitor ring event loop setup failed: ' + error + '\n');
	exit(1);
}
uloop.run();
