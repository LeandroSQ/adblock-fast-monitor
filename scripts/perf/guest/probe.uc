#!/usr/bin/ucode
// Guest-side measurement probe for the P0 performance harness (docs/performance.md).
// Uses only modules present on a stock OpenWrt 25.12.6 image (fs, ubus, uloop).
// Every subcommand prints one JSON document on stdout.
//
//   probe.uc snapshot                    all userland processes + meminfo + /proc/stat
//   probe.uc window SECONDS [TAG]        logger marker, snapshot, sleep, snapshot;
//                                        samples the package processes'
//                                        /proc/<pid>/syscall once a second and
//                                        counts syslog lines after the marker
//   probe.uc rpc OBJECT METHOD JSON N    N timed ubus calls (ms)
//   probe.uc rpcprobe SECONDS INTERVAL_MS  repeated `session list` latencies (rpcd)
//   probe.uc parsebench N                cost of the contract §4.3 regexes per line
//   probe.uc memref RECENT TOP PENDING   RssAnon growth of a ucode process with
//                                        ubus+uloop and tables of the given sizes

import * as fs from 'fs';

const PKG = 'adblock-fast-monitor';

function now_ms() {
	let c = clock(true);
	return c[0] * 1000 + c[1] / 1000000;
}

function status_kb(text, key) {
	let m = match(text ?? '', regexp('(^|\n)' + key + ':[ \t]*([0-9]+)'));
	return m ? +m[2] : null;
}

function read_proc(pid) {
	let stat = fs.readfile(`/proc/${pid}/stat`);
	let status = fs.readfile(`/proc/${pid}/status`);
	let cmdline = fs.readfile(`/proc/${pid}/cmdline`);
	if (stat == null || status == null || cmdline == null || length(cmdline) == 0)
		return null; // gone, or a kernel thread
	// comm may contain spaces and parentheses: split after the last ')'
	let lp = index(stat, '('), rp = rindex(stat, ')');
	let f = split(trim(substr(stat, rp + 2)), ' ');
	// f[0]=state f[1]=ppid f[11]=utime f[12]=stime f[19]=starttime (clock ticks)
	return {
		pid: +pid,
		ppid: +f[1],
		comm: substr(stat, lp + 1, rp - lp - 1),
		cmdline: rtrim(replace(cmdline, /\x00/g, ' ')),
		state: f[0],
		utime: +f[11],
		stime: +f[12],
		starttime: +f[19],
		vm_rss_kb: status_kb(status, 'VmRSS'),
		rss_anon_kb: status_kb(status, 'RssAnon'),
		rss_file_kb: status_kb(status, 'RssFile'),
		rss_shmem_kb: status_kb(status, 'RssShmem'),
		vm_hwm_kb: status_kb(status, 'VmHWM'),
		vctx: status_kb(status, 'voluntary_ctxt_switches'),
		nvctx: status_kb(status, 'nonvoluntary_ctxt_switches'),
	};
}

function meminfo() {
	let out = {};
	for (let line in split(fs.readfile('/proc/meminfo') ?? '', '\n')) {
		let m = match(line, /^([A-Za-z_()0-9]+):[ \t]*([0-9]+)/);
		if (m) out[m[1]] = +m[2];
	}
	return out;
}

function cpu_totals() {
	let f = split(trim(split(fs.readfile('/proc/stat') ?? '', '\n')[0]), /[ \t]+/);
	return { user: +f[1], nice: +f[2], system: +f[3], idle: +f[4], iowait: +f[5], irq: +f[6], softirq: +f[7] };
}

function snapshot() {
	let procs = [];
	let self = +fs.readlink('/proc/self');
	for (let pid in fs.lsdir('/proc') ?? []) {
		if (!match(pid, /^[0-9]+$/) || +pid == self)
			continue;
		let p = read_proc(pid);
		if (p) push(procs, p);
	}
	let up = split(trim(fs.readfile('/proc/uptime') ?? '0 0'), ' ');
	return { uptime_s: +up[0], wall_ms: now_ms(), meminfo: meminfo(), cpu: cpu_totals(), procs: procs };
}

// Package processes: the cmdline names the package, plus their descendants.
function package_pids(procs) {
	let set = {};
	for (let p in procs)
		if (index(p.cmdline, PKG) >= 0 && index(p.cmdline, 'probe.uc') < 0)
			set[p.pid] = true;
	let grew = true;
	while (grew) {
		grew = false;
		for (let p in procs)
			if (!set[p.pid] && set[p.ppid]) { set[p.pid] = true; grew = true; }
	}
	return map(keys(set), (k) => +k);
}

function log_lines_after(marker) {
	let fh = fs.popen('logread', 'r');
	let text = fh ? fh.read('all') : '';
	if (fh) fh.close();
	let lines = split(text ?? '', '\n');
	let at = -1;
	for (let i = 0; i < length(lines); i++)
		if (index(lines[i], marker) >= 0) at = i;
	if (at < 0)
		return { marker_found: false, total: null, dnsmasq: null, lines: [] };
	let after = [];
	for (let i = at + 1; i < length(lines); i++)
		if (length(lines[i])) push(after, lines[i]);
	let dns = 0;
	for (let l in after)
		if (match(l, /dnsmasq\[[0-9]+\]: /)) dns++;
	return { marker_found: true, total: length(after), dnsmasq: dns, lines: slice(after, 0, 50) };
}

function window(seconds, tag) {
	let marker = sprintf('abfm-perf-window-%s-%d', tag ?? 'w', time());
	system(['logger', '-t', 'abfm-perf', marker]);
	sleep(200);
	let t0 = snapshot();
	let pids = package_pids(t0.procs);
	let samples = [];
	let end = t0.wall_ms + seconds * 1000;
	while (now_ms() < end - 5) {
		let wait = min(1000, end - now_ms());
		if (wait > 0) sleep(int(wait));
		let s = { t_ms: int(now_ms() - t0.wall_ms), pids: {} };
		for (let pid in pids)
			s.pids[pid] = trim(fs.readfile(`/proc/${pid}/syscall`) ?? 'gone');
		push(samples, s);
	}
	let t1 = snapshot();
	return { tag: tag, seconds: seconds, marker: marker, package_pids: pids,
		t0: t0, t1: t1, syscall_samples: samples, log: log_lines_after(marker) };
}

function percentile(sorted, q) {
	let n = length(sorted);
	if (!n) return null;
	let x = q * n, c = int(x);
	if (c < x) c++;
	return sorted[max(0, min(n - 1, c - 1))];
}

function stats(ms) {
	let s = sort([...ms], (a, b) => a - b);
	let sum = 0;
	for (let v in s) sum += v;
	return { n: length(s), min: s[0], p50: percentile(s, 0.5), p95: percentile(s, 0.95),
		max: s[length(s) - 1], mean: length(s) ? sum / length(s) : null };
}

function rpc(object, method, args_json, n) {
	let ubus = require('ubus');
	let conn = ubus.connect(null, 60);
	if (!conn)
		return { object: object, method: method, error: 'ubus-connect-failed' };
	let args = json(args_json ?? '{}');
	let times = [], last = null, err = null;
	for (let i = 0; i < n; i++) {
		let t = now_ms();
		last = conn.call(object, method, args);
		push(times, now_ms() - t);
		if (last == null) { err = ubus.error(); break; }
	}
	let text = last != null ? sprintf('%J', last) : null;
	return { object: object, method: method, args: args, n: n, error: err, times_ms: times,
		stats: stats(times), reply_bytes: text ? length(text) : 0,
		reply: text == null ? null : (length(text) <= 4096 ? last : substr(text, 0, 4096)) };
}

function rpcprobe(seconds, interval) {
	let ubus = require('ubus');
	let conn = ubus.connect(null, 30);
	let times = [], errors = 0, worst = -1, t_start = now_ms();
	while (now_ms() - t_start < seconds * 1000) {
		let t = now_ms();
		let r = conn.call('session', 'list', {});
		let dt = now_ms() - t;
		if (r == null) errors++;
		if (worst < 0 || dt > times[worst]) worst = length(times);
		push(times, dt);
		sleep(interval);
	}
	return { probe: 'session list', interval_ms: interval, errors: errors, stats: stats(times) };
}

// Contract §4.3 regexes, applied as the daemon must (PREFIX, then BODY).
function parsebench(n) {
	let PREFIX = /^[A-Z][a-z]{2} [A-Z][a-z]{2} [ 0-9][0-9] [0-9]{2}:[0-9]{2}:[0-9]{2} [0-9]{4} [a-z0-9]+\.[a-z]+ dnsmasq\[([0-9]+)\]: (.*)$/;
	let BODY = /^(TCP |UDP )?([0-9]+) ([^ \/]+)\/([0-9]+) ([^ ]+) ([a-z0-9_.-]+) (from|is|to) ([^ ]+)( \([^()]*\))?$/;
	let hdr = 'Tue Nov 10 01:09:19 2026 daemon.info dnsmasq[1234]: ';
	let lines = map([
		'41 192.168.1.10/53211 query[A] u-17-000123.perf.test from 192.168.1.10',
		'41 192.168.1.10/53211 forwarded u-17-000123.perf.test to 127.0.0.1',
		'41 192.168.1.10/53211 reply u-17-000123.perf.test is 192.0.2.1',
		'42 192.168.1.10/53212 config b-17-000124.perf-block.test is NXDOMAIN',
	], (b) => hdr + b);
	let ok = 0, t = now_ms();
	for (let i = 0; i < n; i++) {
		let m = match(lines[i % 4], PREFIX);
		if (m && match(m[2], BODY)) ok++;
	}
	let dt = now_ms() - t;
	return { lines: n, matched: ok, total_ms: dt, us_per_line: dt * 1000 / n };
}

function self_kb(key) {
	return status_kb(fs.readfile('/proc/self/status'), key);
}

function memref(recent, top, pending) {
	let uloop = require('uloop');
	let ubus = require('ubus');
	uloop.init();
	let conn = ubus.connect();
	let obj = conn ? conn.publish('abfm-perf-ref', { status: { args: {}, call: function(req) { return {}; } } }) : null;
	let before = { rss_anon_kb: self_kb('RssAnon'), vm_rss_kb: self_kb('VmRSS') };
	let rows = {}, order = [], tb = {}, ta = {}, pend = {};
	for (let i = 0; i < recent; i++) {
		let d = sprintf('host-%06d.some-tracker-domain.example.com', i);
		rows[d] = { domain: d, decision: 'blocked', source: 'config', count: i, blocked: i, allowed: 0,
			first_seen: 1762747000 + i, last_seen: 1762747000 + i, qtypes: ['A', 'AAAA', 'HTTPS'],
			client: '192.168.1.10' };
		push(order, d);
	}
	for (let i = 0; i < top; i++) {
		tb[sprintf('blocked-%06d.example.com', i)] = { count: i, error: 0 };
		ta[sprintf('allowed-%06d.example.com', i)] = { count: i, error: 0 };
	}
	for (let i = 0; i < pending; i++)
		pend[sprintf('%d:%d', 1234, i)] = { name: sprintf('pending-%06d.example.com', i), qtype: 'A', client: '192.168.1.10', t: 1762747000 };
	gc('collect');
	let after = { rss_anon_kb: self_kb('RssAnon'), vm_rss_kb: self_kb('VmRSS') };
	if (obj) obj.remove();
	return { recent: recent, top: top, pending: pending, published: !!obj, before: before, after: after,
		delta_anon_kb: after.rss_anon_kb - before.rss_anon_kb,
		kept: length(order) + length(tb) + length(ta) + length(pend) + length(rows) };
}

let cmd = ARGV[0];
let out;
if (cmd == 'snapshot') out = snapshot();
else if (cmd == 'window') out = window(+ARGV[1], ARGV[2]);
else if (cmd == 'rpc') out = rpc(ARGV[1], ARGV[2], ARGV[3], +(ARGV[4] ?? 1));
else if (cmd == 'rpcprobe') out = rpcprobe(+ARGV[1], +(ARGV[2] ?? 20));
else if (cmd == 'parsebench') out = parsebench(+(ARGV[1] ?? 2000));
else if (cmd == 'memref') out = memref(+ARGV[1], +ARGV[2], +ARGV[3]);
else { warn('usage: probe.uc snapshot|window|rpc|rpcprobe|parsebench|memref ...\n'); exit(2); }
printf('%J\n', out);
