#!/usr/bin/ucode
// SPDX-License-Identifier: Apache-2.0
// adblock-fast-monitor resident daemon (docs/CONTRACT.md D1, §4).
// procd execs this file directly. It follows `logread -f` for dnsmasq lines,
// keeps bounded statistics in RAM and publishes the ubus object
// `adblock-fast-monitor`. No files are written. No timer is armed while no
// query is pending.
'use strict';

const uloop = require('uloop');
const io = require('io');
const fs = require('fs');
const ubus = require('ubus');
const uci = require('uci');
const logparse = require('abfm.logparse');
const stats = require('abfm.stats');
const sys = require('abfm.system');

const OBJECT = 'adblock-fast-monitor';
const LOGREAD = '/sbin/logread';
const READ_CHUNK = 4096;
const READS_PER_WAKEUP = 16;
const LOCALS_MAX_AGE = 300;

function log(msg) {
	warn(`${OBJECT}: ${msg}\n`);
}

let cfg = sys.monitor_config(uci.cursor());
let started_at = time();
let st = stats.create(cfg, started_at);
let pid = +(fs.readlink('/proc/self') ?? 0);
let dns_mode = sys.adblock_fast_dns(uci.cursor());
let exit_code = 1;

let locals = null, locals_at = 0;
let ctx = {
	exclude_router: cfg.exclude_router,
	local_domains: function() {
		let now = time();
		if (locals == null || now - locals_at >= LOCALS_MAX_AGE) {
			locals = sys.local_domains(uci.cursor());
			locals_at = now;
		}
		return locals;
	}
};

uloop.init();

let conn = ubus.connect();
if (!conn) {
	log('ubus connect failed');
	exit(1);
}

// --- logread child, stdout redirected into a pipe (§4.1 step 2) ----------

let pipe = io.pipe();
let reader = pipe?.[0], writer = pipe?.[1];
if (!reader) {
	log(`pipe failed: ${io.error()}`);
	exit(1);
}
reader.fcntl(io.F_SETFD, io.FD_CLOEXEC);
writer.fcntl(io.F_SETFD, io.FD_CLOEXEC);

let saved = io.new(1).dup();
saved.fcntl(io.F_SETFD, io.FD_CLOEXEC);
writer.dup2(1);
let child = null;
child = uloop.process(LOGREAD, [ '-f', '-e', '^dnsmasq\\[' ], {}, (code) => {
	log(`logread exited (${code})`);
	child = null;
	uloop.end();
});
saved.dup2(1);
saved.close();
writer.close();

if (!child) {
	log(`cannot start ${LOGREAD}: ${uloop.error()}`);
	exit(1);
}
let child_pid = child.pid();

function kill_child() {
	if (child_pid)
		system([ '/bin/kill', `${child_pid}` ]);
}

// --- pending TTL timer: armed only while entries are pending ---------------

let armed = false;
let sweeper = null;
sweeper = uloop.timer(-1, () => {
	armed = false;
	let next = stats.sweep(st, time());
	if (next != null) {
		sweeper.set(1000 * (next < 1 ? 1 : (next > cfg.pending_ttl ? cfg.pending_ttl : next)));
		armed = true;
	}
});

function rearm() {
	let pending = st.counters.pending;
	if (pending > 0 && !armed) {
		sweeper.set(1000 * st.limits.pending_ttl);
		armed = true;
	}
	else if (pending == 0 && armed) {
		sweeper.cancel();
		armed = false;
	}
}

// --- input -----------------------------------------------------------------

let frame = logparse.framer(() => stats.input_overflow(st, time()));

function on_line(line, now) {
	let c = st.counters;
	let lost = c.dropped.dnsmasq_reported;
	let ev = logparse.parse_line(line, c);
	stats.note_lost(st, lost, now);
	if (ev)
		stats.ingest(st, ev, ctx, now);
}

reader.fcntl(io.F_SETFL, reader.fcntl(io.F_GETFL) | io.O_NONBLOCK);
let reader_handle = uloop.handle(reader, () => {
	for (let i = 0; i < READS_PER_WAKEUP; i++) {
		let data = reader.read(READ_CHUNK);
		if (data == null)
			break;                     // EAGAIN: drained
		if (data === '') {
			log('logread pipe closed');
			uloop.end();
			return;
		}
		let now = time();
		for (let line in frame.feed(data))
			on_line(line, now);
		if (length(data) < READ_CHUNK)
			break;
	}
	rearm();
}, uloop.ULOOP_READ);

// --- ubus object (§4.6) ----------------------------------------------------

function error_reply(code, message) {
	return { api: 1, ok: false, error: { code, message } };
}

function guarded(fn) {
	return function(req) {
		try {
			return fn(req);
		}
		catch (e) {
			log(`handler error: ${e.message ?? e}`);
			return error_reply('internal-error', `${e.message ?? e}`);
		}
	};
}

function status_reply() {
	let now = time();
	stats.sweep(st, now);
	rearm();

	dns_mode = sys.adblock_fast_dns(uci.cursor());
	let reasons = stats.reasons(st, now);
	if (dns_mode != null && index(sys.DNS_MODES_OBSERVABLE, dns_mode) < 0)
		push(reasons, 'dns-mode-unsupported');

	return {
		api: 1, ok: true,
		state: length(reasons) ? 'degraded' : 'running',
		reasons,
		daemon: { pid, started_at, now, stats_since: st.stats_since, purged_at: st.purged_at },
		counters: stats.snapshot_counters(st),
		block_pct: stats.block_pct(st.counters),
		last_event_at: st.last_event_at,
		limits: { ...st.limits },
		adblock_fast: { dns: dns_mode }
	};
}

let obj = conn.publish(OBJECT, {
	status: {
		args: {},
		call: guarded((req) => status_reply())
	},
	domains: {
		args: { view: '', decision: '', q: '', offset: 0, limit: 0 },
		call: guarded((req) => stats.domains(st, req.args, time()))
	},
	purge: {
		args: {},
		call: guarded((req) => {
			let now = time();
			stats.reset(st, now);
			rearm();
			return { api: 1, ok: true, stats_since: now };
		})
	}
});

if (!obj) {
	log(`ubus publish failed: ${conn.error()}`);
	kill_child();
	exit(1);
}

// --- run -------------------------------------------------------------------

let rc = uloop.run();

if (rc > 0) {
	// SIGTERM/SIGINT from procd: clean shutdown.
	exit_code = 0;
}
else if (child) {
	log('ubus connection lost or reader closed');
}

kill_child();
exit(exit_code);
