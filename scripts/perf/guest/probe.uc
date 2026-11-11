#!/usr/bin/ucode
// Guest-side measurement probe for the P0 performance harness (docs/performance.md).
// Uses only modules present on a stock OpenWrt 25.12.6 image (fs, ubus).
// Every subcommand prints one JSON document on stdout.
//
//   probe.uc snapshot                    every task (userland and kernel threads)
//                                        + meminfo + /proc/stat
//   probe.uc window SECONDS [TAG]        logger marker, snapshot, sleep, snapshot;
//                                        counts syslog lines after the marker
//   probe.uc watch SECONDS [INTERVAL_MS] package processes seen in /proc every
//                                        INTERVAL (250) ms, with per-pid lifetimes
//   probe.uc rpc OBJECT METHOD JSON N    N timed ubus calls (ms)
//   probe.uc rpcprobe SECONDS INTERVAL_MS  repeated `session list` latencies (rpcd)
//   probe.uc logbench CALLS INTERVAL_MS  `log read` latency at the browser's
//                                        adaptive N for the current log rate
//                                        and at N=900 (§11 P3)

import * as fs from 'fs';

const PKG = 'adblock-fast-monitor';

function now_ms() {
	let c = clock(true);
	return c[0] * 1000 + c[1] / 1000000.0;
}

function status_kb(text, key) {
	let m = match(text ?? '', regexp('(^|\n)' + key + ':[ \t]*([0-9]+)'));
	return m ? +m[2] : null;
}

// One task. Kernel threads (empty cmdline) are included and flagged: the
// window's system total is the sum over every task (§11, docs/performance.md
// "CPU %"), so a kernel thread's work (softirq, virtio) is not lost.
function read_proc(pid) {
	let stat = fs.readfile(`/proc/${pid}/stat`);
	let status = fs.readfile(`/proc/${pid}/status`);
	let cmdline = fs.readfile(`/proc/${pid}/cmdline`);
	if (stat == null || status == null || cmdline == null)
		return null; // gone
	// comm may contain spaces and parentheses: split after the last ')'
	let lp = index(stat, '('), rp = rindex(stat, ')');
	let f = split(trim(substr(stat, rp + 2)), ' ');
	// f[0]=state f[1]=ppid f[11]=utime f[12]=stime f[13]=cutime f[14]=cstime
	// f[19]=starttime (clock ticks)
	let sched = fs.readfile(`/proc/${pid}/schedstat`);
	return {
		pid: +pid,
		ppid: +f[1],
		comm: substr(stat, lp + 1, rp - lp - 1),
		cmdline: rtrim(join(' ', split(cmdline, chr(0)))),
		kthread: length(cmdline) == 0,
		state: f[0],
		utime: +f[11],
		stime: +f[12],
		cutime: +f[13],
		cstime: +f[14],
		starttime: +f[19],
		run_ns: sched ? +split(sched, ' ')[0] : null,
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

// /proc/stat: tick-sampled totals (informational; the gate's system total is
// task-based) and the number of CPUs.
function cpu_totals() {
	let lines = split(fs.readfile('/proc/stat') ?? '', '\n');
	let f = split(trim(lines[0]), /[ \t]+/);
	let ncpu = 0;
	for (let l in lines)
		if (match(l, /^cpu[0-9]+ /)) ncpu++;
	return { user: +f[1], nice: +f[2], system: +f[3], idle: +f[4], iowait: +f[5], irq: +f[6], softirq: +f[7],
		steal: +(f[8] ?? 0), ncpu: ncpu };
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
		if (!p.kthread && index(p.cmdline, PKG) >= 0 && index(p.cmdline, 'probe.uc') < 0)
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
	let end = t0.wall_ms + seconds * 1000;
	while (now_ms() < end - 5)
		sleep(int(min(1000, end - now_ms())));
	let t1 = snapshot();
	return { tag: tag, seconds: seconds, marker: marker, package_pids: package_pids(t1.procs),
		t0: t0, t1: t1, log: log_lines_after(marker) };
}

// Every process whose cmdline names the package, scanned every INTERVAL ms:
// per cmdline (`seen`) and per pid (`procs`: ppid, first/last sighting in ms
// since the watch started), so transient init invocations can be told from
// resident processes (§11 P1).
function watch(seconds, interval) {
	interval ??= 250;
	let seen = {}, procs = {}, scans = 0, t0 = now_ms(), end = t0 + seconds * 1000;
	let up = +split(fs.readfile('/proc/uptime') ?? '0', ' ')[0];
	let self = +fs.readlink('/proc/self');
	while (now_ms() < end) {
		let t = int(now_ms() - t0);
		for (let pid in fs.lsdir('/proc') ?? []) {
			if (!match(pid, /^[0-9]+$/) || +pid == self)
				continue;
			let c = fs.readfile(`/proc/${pid}/cmdline`);
			if (c == null || index(c, PKG) < 0)
				continue;
			c = rtrim(join(' ', split(c, chr(0))));
			if (index(c, 'probe.uc') >= 0)
				continue;
			seen[c] ??= { samples: 0, pids: [] };
			seen[c].samples++;
			if (index(seen[c].pids, +pid) < 0) push(seen[c].pids, +pid);
			let st = fs.readfile(`/proc/${pid}/stat`);
			let key = `${pid}:${st ? split(trim(substr(st, rindex(st, ')') + 2)), ' ')[19] : 0}`;
			if (!procs[key]) {
				let pp = st ? +split(trim(substr(st, rindex(st, ')') + 2)), ' ')[1] : null;
				procs[key] = { pid: +pid, ppid: pp, cmdline: c, first_ms: t, last_ms: t, samples: 0 };
			}
			procs[key].last_ms = t;
			procs[key].samples++;
		}
		scans++;
		sleep(interval);
	}
	return { seconds: seconds, interval_ms: interval, uptime_at_start_s: up, scans: scans,
		duration_ms: int(now_ms() - t0), seen: seen, procs: values(procs) };
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
		stats: stats(times), reply_bytes: text ? length(text) : 0, reply_ok: last?.ok === true,
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

// `log read` exactly as the page calls it ({lines, stream:false,
// oneshot:true}). The adaptive N is derived like the page does it: the ids
// logged in 2 s (one poll interval) give the batch, N = clamp(1.5*batch+16,
// 16, 900). Calls alternate between that N and the first-load N=900.
function log_read(conn, n) {
	let t = now_ms();
	let r = conn.call('log', 'read', { lines: n, stream: false, oneshot: true });
	return { ms: now_ms() - t, reply: r };
}

function last_id(r) {
	let l = r?.log;
	return (type(l) == 'array' && length(l)) ? l[length(l) - 1].id : null;
}

function logbench(calls, interval) {
	let ubus = require('ubus');
	let conn = ubus.connect(null, 30);
	if (!conn)
		return { error: 'ubus-connect-failed' };
	let a = log_read(conn, 1).reply;
	sleep(2000);
	let b = log_read(conn, 1).reply;
	let batch = (last_id(a) != null && last_id(b) != null) ? last_id(b) - last_id(a) : null;
	let n_incr = batch == null ? 16 : max(16, min(900, int(1.5 * batch) + 16));
	let t_incr = [], t_full = [], e_incr = [], e_full = [], errors = 0, sample = null;
	for (let i = 0; i < calls; i++) {
		let x = log_read(conn, n_incr);
		if (x.reply == null) errors++;
		push(t_incr, x.ms); push(e_incr, length(x.reply?.log ?? []));
		sleep(interval);
		let y = log_read(conn, 900);
		if (y.reply == null) errors++;
		push(t_full, y.ms); push(e_full, length(y.reply?.log ?? []));
		if (i == 0 && y.reply?.log) {
			let l = y.reply.log;
			sample = { keys: sort(keys(l[0] ?? {})), first_id: l[0]?.id, last_id: last_id(y.reply),
				bytes: length(sprintf('%J', y.reply)) };
		}
		sleep(interval);
	}
	return { lines_per_2s: batch, n_incremental: n_incr, calls: calls, interval_ms: interval, errors: errors,
		error: errors ? ubus.error() : null, incremental: { times_ms: t_incr, entries: e_incr, stats: stats(t_incr) },
		full: { lines: 900, times_ms: t_full, entries: e_full, stats: stats(t_full) }, sample: sample };
}

let cmd = ARGV[0];
let out;
if (cmd == 'snapshot') out = snapshot();
else if (cmd == 'window') out = window(+ARGV[1], ARGV[2]);
else if (cmd == 'watch') out = watch(+ARGV[1], ARGV[2] ? +ARGV[2] : null);
else if (cmd == 'rpc') out = rpc(ARGV[1], ARGV[2], ARGV[3], +(ARGV[4] ?? 1));
else if (cmd == 'rpcprobe') out = rpcprobe(+ARGV[1], +(ARGV[2] ?? 20));
else if (cmd == 'logbench') out = logbench(+(ARGV[1] ?? 20), +(ARGV[2] ?? 250));
else { warn('usage: probe.uc snapshot|window|watch|rpc|rpcprobe|logbench ...\n'); exit(2); }
printf('%J\n', out);
