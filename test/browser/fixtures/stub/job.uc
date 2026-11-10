#!/usr/bin/ucode
// TEST-ONLY stand-in for WU2's job.uc (docs/CONTRACT.md §7). Never shipped.
// Runs the real adblock-fast runtime step and verifies with BusyBox nslookup.
'use strict';

import { readfile, writefile, rename, open, popen } from 'fs';
import { connect } from 'ubus';

const JOB = '/var/run/adblock-fast-monitor/job.json';
const id = ARGV[0];
let job = json(readfile(JOB) ?? 'null');
if (!job || job.id != id) exit(1);

function save() { writefile(JOB + '.tmp', job); rename(JOB + '.tmp', JOB); }
function status() {
	let u = connect(), r = u?.call('service', 'list', { name: 'adblock-fast' });
	u?.disconnect();
	return r?.['adblock-fast']?.data?.status;
}
function finish(state, error) {
	job.state = state; job.error = error; job.finished_at = time(); job.phase = (state == 'failed') ? job.phase : null;
	job.adblock_fast_status = status();
	save();
	exit(0);
}

let lock = open('/var/lock/adblock-fast-monitor.lock', 'a');
if (!lock || !lock.lock('xn')) finish('failed', { code: 'lock-failed', message: 'lock busy' });

job.state = 'applying'; job.started_at = time(); job.phase = 'uci'; save();
sleep(1000);

function listed(d) {
	let txt = readfile(job.output_file ?? '') ;
	if (txt == null) return null;
	if (index(txt, '127.0.0.1 ' + d + '\n') >= 0 || index(txt, ':: ' + d + '\n') >= 0) return true;
	let labels = split(d, '.');
	for (let k = 0; k < length(labels) - 1; k++) {
		let s = join('.', slice(labels, k));
		if (index(txt, 'server=/' + s + '/#') >= 0) return false;
		if (index(txt, 'server=/' + s + '/\n') >= 0 || index(txt, 'local=/' + s + '/\n') >= 0) return true;
	}
	return false;
}

let doms = map(filter(job.items, (i) => length(i.change)), (i) => i.domain);
if (job.mode == 'fast-allow') {
	job.phase = 'allow'; save();
	system('/etc/init.d/adblock-fast allow ' + join(' ', doms) + ' >/dev/null 2>&1');
	if (status() != 'statusSuccess') finish('failed', { code: 'allow-failed', message: 'adblock-fast allow failed' });
}
else if (job.mode == 'rebuild') {
	job.phase = 'rebuild'; save();
	system('/etc/init.d/adblock-fast dl >/dev/null 2>&1');
	if (status() != 'statusSuccess') finish('failed', { code: 'rebuild-failed', message: 'adblock-fast rebuild failed' });
}
else {
	for (let i in job.items) i.result = 'skipped';
	finish('applied', null);
}

job.state = 'verifying'; job.phase = 'verify'; save();
sleep(500);
let all = true;
for (let i in job.items) {
	if (!length(i.change)) { i.result = 'ok'; continue; }
	let p = popen('nslookup ' + i.domain + ' 127.0.0.1 2>&1');
	let out = p.read('all'); p.close();
	let n = index(out, 'Name:');
	out = (n >= 0) ? substr(out, n) : out;
	let addrs = [];
	for (let m in match(out, /Address: ([0-9a-f:.]+)/g)) push(addrs, m[1]);
	let sink = length(filter(addrs, (a) => a in [ '0.0.0.0', '127.0.0.1', '::' ])) > 0;
	let nx = index(out, 'NXDOMAIN') >= 0;
	i.answer = { rcode: nx ? 'NXDOMAIN' : 'NOERROR', a: addrs, aaaa: [] };
	let l = listed(i.domain);
	i.observed = sink ? 'blocked' : ((nx || !length(addrs)) ? ((l === true) ? 'blocked' : ((l === false) ? 'allowed' : 'unknown')) : 'allowed');
	if (i.expect == 'any') i.result = 'ok';
	else if (i.observed == 'unknown') { i.result = 'unverified'; i.reason = 'dns-error'; }
	else if (i.observed == i.expect) i.result = 'ok';
	else { i.result = 'mismatch'; i.reason = (i.expect == 'blocked') ? 'not-blocked' : 'still-listed'; }
	if (i.result != 'ok') all = false;
	save();
}
finish(all ? 'applied' : 'partial', null);
