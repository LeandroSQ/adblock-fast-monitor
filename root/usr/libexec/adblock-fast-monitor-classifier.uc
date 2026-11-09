'use strict';

/* Deliberately separate from the resident reader until its publication
 * protocol is stock-validated. This worker performs bounded, generation-bound
 * scans only; it never changes activity/status snapshots itself. */
let fs = require('fs');

let state_dir = ARGV[0];
let output_file = ARGV[1];
let max_queue = +ARGV[2];
let batch_limit = +ARGV[3];
if (!state_dir || !output_file || max_queue < 1 || batch_limit < 1)
	exit(64);

let activity = state_dir + '/activity.tsv';
let generation_file = state_dir + '/generation';
let response_file = state_dir + '/classifications.tsv';
let lock_path = state_dir + '/monitor.lock';
let cache = {};

function generation() {
	let value = +(trim(fs.readfile(generation_file) || ''));
	return value >= 0 ? value : -1;
}

function output_id() {
	let info = fs.lstat(output_file);
	if (!info || info.type != 'file')
		return null;
	return '' + info.ino + ':' + info.size + ':' + info.mtime;
}

function suffixes(domain) {
	let result = [];
	let value = domain;
	while (value) {
		push(result, value);
		let dot = index(value, '.');
		value = dot < 0 ? '' : substr(value, dot + 1);
	}
	return result;
}

function pending(work_generation, identity) {
	let result = [];
	let lines = split(fs.readfile(activity) || '', '\n');
	for (let line in lines) {
		let fields = split(line, '\t');
		if (length(fields) < 6 || fields[1] != 'unknown' || fields[3] != 'attribution-pending')
			continue;
		if (fields[5] != work_generation || length(result) >= max_queue)
			continue;
		push(result, { sequence: fields[0], domain: fields[2], identity });
	}
	return result;
}

function classify(work, identity) {
	let wanted = {};
	for (let item in work)
		for (let candidate in suffixes(item.domain))
			wanted[candidate] = true;

	let found = {};
	let file = fs.open(output_file, 'r');
	if (!file) return null;
	let remainder = '', chunk;
	while ((chunk = file.read(65536)) && length(chunk)) {
		let lines = split(remainder + chunk, '\n');
		remainder = pop(lines) || '';
		for (let line in lines) {
			let match_domain = match(line, /^server=\/([^/]+)\/$/);
			if (match_domain && wanted[match_domain[1]])
				found[match_domain[1]] = true;
		}
	}
	file.close();
	if (output_id() != identity) return null;
	return found;
}

let work_generation = generation();
let identity = output_id();
if (work_generation < 0 || !identity)
	exit(1);
let work = pending(work_generation, identity);
if (length(work) > batch_limit)
	work = slice(work, 0, batch_limit);
let matches = classify(work, identity);
if (!matches || generation() != work_generation)
	exit(0);

let lock = fs.open(lock_path, 'r+');
if (!lock) {
	let error = fs.error();
	if (error)
		print('classifier lock open failed: ' + error + '\n');
	exit(1);
}
if (!lock.lock('xn')) {
	let error = lock.error() || fs.error();
	if (error)
		print('classifier lock deferred: ' + error + '\n');
	lock.close();
	exit(0);
}
if (generation() == work_generation && output_id() == identity) {
	let output = '';
	for (let item in work) {
		let verdict = false;
		for (let candidate in suffixes(item.domain))
			verdict ||= matches[candidate] == true;
		output += work_generation + '\t' + item.sequence + '\t' + identity + '\t' +
			(verdict ? 'blocked' : 'unknown') + '\n';
	}
	let next = fs.open(response_file + '.next', 'w');
	if (next) {
		next.write(output);
		next.close();
		fs.chmod(response_file + '.next', 0600);
		fs.rename(response_file + '.next', response_file);
	}
}
lock.lock('u');
lock.close();
