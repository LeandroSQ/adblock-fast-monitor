#!/usr/bin/ucode
// SPDX-License-Identifier: Apache-2.0
// Detached apply job (docs/CONTRACT.md §7). Started by the rpcd plugin as
// `job.uc <job_id>`; runs the adblock-fast runtime step for the queued job,
// then verifies every domain against real DNS answers from 127.0.0.1.
'use strict';

const fs = require('fs');
const io = require('io');
const uci = require('uci');
const ubus = require('ubus');
const resolv = require('resolv');
const dom = require('abfm.domain');

const RUN_DIR = '/var/run/adblock-fast-monitor';
const JOB_FILE = RUN_DIR + '/job.json';
const UCI_SAVEDIR = RUN_DIR + '/uci';
const LOCK_DIR = '/var/lock';
const LOCK_FILE = LOCK_DIR + '/adblock-fast-monitor.lock';
const AF_INIT = '/etc/init.d/adblock-fast';
const LOCK_WAIT_MS = 10000;
const AF_IDLE_WAIT_S = 900;
const VERIFY_LINE_CAP = 10000;

// system() from rpcd leaves rpcd's sockets, pipes and epoll fd open in this
// process; drop them so the job never holds or uses rpcd resources.
function close_inherited_fds() {
	for (let name in fs.lsdir('/proc/self/fd') ?? []) {
		let fd = +name;
		if (fd <= 2)
			continue;
		let target = fs.readlink('/proc/self/fd/' + name) ?? '';
		if (match(target, /^(socket|pipe|anon_inode):/)) {
			try {
				io.new(fd)?.close();
			}
			catch (e) {}
		}
	}
}

function read_job() {
	try {
		let j = json(fs.readfile(JOB_FILE) ?? 'null');
		return (type(j) == 'object') ? j : null;
	}
	catch (e) {
		return null;
	}
}

function write_job(job) {
	let tmp = JOB_FILE + '.tmp';
	fs.unlink(tmp);
	let f = fs.open(tmp, 'wx', 0600);
	if (!f)
		return false;
	let ok = f.write(sprintf('%J', job)) != null;
	f.close();
	return ok && fs.rename(tmp, JOB_FILE);
}

function acquire_lock() {
	if (!fs.stat(LOCK_DIR))
		fs.mkdir(LOCK_DIR, 0755);
	// O_CLOEXEC: adblock-fast's children must never inherit (and keep) the lock.
	let f = fs.open(LOCK_FILE, 'ae', 0600);
	if (!f)
		return null;
	for (let waited = 0; waited <= LOCK_WAIT_MS; waited += 100) {
		if (f.lock('xn'))
			return f;
		sleep(100);
	}
	f.close();
	return null;
}

function af_service() {
	let conn = ubus.connect();
	let data = conn?.call('service', 'list', { name: 'adblock-fast' })?.['adblock-fast']?.data;
	conn?.disconnect();
	return { status: data?.status || null, errors: data?.errors ?? [] };
}

// Waits while another adblock-fast CLI run (e.g. one orphaned by a killed
// job, or a LuCI-triggered reload) is still working.
function wait_adblock_fast_idle() {
	let self = fs.readlink('/proc/self') ?? '';
	for (let i = 0; i < AF_IDLE_WAIT_S; i++) {
		let busy = false;
		for (let pid in fs.lsdir('/proc') ?? []) {
			if (!match(pid, /^[0-9]+$/) || pid == self)
				continue;
			if (index(fs.readfile(`/proc/${pid}/cmdline`) ?? '', '/lib/adblock-fast/cli.uc') >= 0) {
				busy = true;
				break;
			}
		}
		if (!busy)
			return;
		sleep(1000);
	}
}

function current_dns() {
	let c = uci.cursor(null, UCI_SAVEDIR);
	return c.get('adblock-fast', 'config', 'dns') || 'dnsmasq.servers';
}

function output_lines(file, domains, dns) {
	if (!file || !fs.access(file))
		return [];
	let p = fs.popen(dom.grep_command(file, domains, dns), 'r');
	let lines = [], line;
	while (p && length(lines) < VERIFY_LINE_CAP && (line = p.read('line')) != null && line != '')
		push(lines, rtrim(line, '\n'));
	p?.close();
	return lines;
}

function finish(job, state, error) {
	job.state = state;
	job.error = error;
	job.finished_at = time();
	for (let it in job.items)
		if (it.result == 'pending')
			it.result = 'unverified';
	write_job(job);
}

function verify(job) {
	job.state = 'verifying';
	job.phase = 'verify';
	write_job(job);

	let dns = current_dns();
	let file = dom.DNSMASQ_MODES[dns];
	let domains = uniq(map(job.items, (it) => it.domain));
	let res = length(domains)
		? resolv.query(domains, { type: [ 'A', 'AAAA' ], nameserver: [ '127.0.0.1' ], timeout: 3000, retries: 1 }) ?? {}
		: {};
	let lst = dom.listed(domains, output_lines(file, domains, dns), dns);

	let all_ok = true;
	for (let it in job.items) {
		let ans = dom.answer_of(res, it.domain);
		let observed = dom.observe(ans, lst[it.domain]?.listed);
		let v = dom.verdict(it, observed, ans, lst[it.domain], dns);
		it.observed = observed;
		it.answer = { rcode: ans.rcode, a: ans.a, aaaa: ans.aaaa };
		it.result = v.result;
		it.reason = v.reason;
		if (v.result != 'ok')
			all_ok = false;
	}
	finish(job, all_ok ? 'applied' : 'partial', null);
}

function rebuild(job) {
	job.phase = 'rebuild';
	write_job(job);
	wait_adblock_fast_idle();
	// No timeout: a half-built block-list is worse than a slow one (§7.2).
	system(`${AF_INIT} dl </dev/null >/dev/null 2>&1`);
	let svc = af_service();
	job.adblock_fast_status = svc.status;
	let file = dom.DNSMASQ_MODES[current_dns()];
	let codes = map(svc.errors, (e) => e?.code ?? '' + e);
	if (svc.status != 'statusSuccess' || !file || !fs.access(file) || length(codes)) {
		finish(job, 'failed', {
			code: 'rebuild-failed',
			message: sprintf('adblock-fast status %s%s%s', svc.status ?? 'unknown',
				length(codes) ? ', errors: ' + join(' ', codes) : '',
				(file && fs.access(file)) ? '' : ', no output file'),
		});
		return false;
	}
	return true;
}

function main(id) {
	if (!dom.valid_job_id(id))
		return 2;
	close_inherited_fds();

	let lock = acquire_lock();
	let job = read_job();
	if (!job || job.id != id || job.state != 'queued') {
		// Superseded, reaped (start-timeout) or already run: nothing to do.
		lock?.close();
		return 0;
	}
	if (!lock) {
		finish(job, 'failed', { code: 'lock-failed', message: 'cannot acquire the job lock' });
		return 1;
	}

	job.state = 'applying';
	job.started_at = time();
	write_job(job);

	switch (job.mode) {
	case 'persist-only':
		for (let it in job.items)
			it.result = 'skipped';
		finish(job, 'applied', null);
		break;

	case 'rebuild':
		if (rebuild(job))
			verify(job);
		break;

	default:
		finish(job, 'failed', { code: 'rebuild-failed', message: `unknown mode ${job.mode}` });
	}

	lock.lock('u');
	lock.close();
	return 0;
}

exit(main(ARGV[0]));
