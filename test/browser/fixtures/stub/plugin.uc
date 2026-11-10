// TEST-ONLY stand-in for WU2's rpcd plugin luci.adblock-fast-monitor
// (docs/CONTRACT.md §6–7). Never shipped; installed into the guest by
// test/browser/fixtures/stub/install.sh only with ABFM_UI_STUB=1.
// It follows the published wire shapes; it is not a reference implementation.
'use strict';

import { access, readfile, writefile, rename, stat, open, mkdir, lsdir } from 'fs';
import { cursor } from 'uci';
import { connect } from 'ubus';

const RUN = '/var/run/adblock-fast-monitor';
const JOB = RUN + '/job.json';
const SAVEDIR = RUN + '/uci';
const JOBUC = '/usr/libexec/adblock-fast-monitor/stub-job.uc';
const OUT = {
	'dnsmasq.servers': '/var/run/adblock-fast/dnsmasq.servers',
	'dnsmasq.addnhosts': '/var/run/adblock-fast/dnsmasq.addnhosts',
	'dnsmasq.conf': '/var/run/adblock-fast/adblock-fast.dnsmasq',
	'dnsmasq.ipset': '/var/run/adblock-fast/adblock-fast.dnsmasq',
	'dnsmasq.nftset': '/var/run/adblock-fast/adblock-fast.dnsmasq'
};

function err(code, message, extra) {
	let r = { api: 1, ok: false, error: { code, message: message ?? code } };
	for (let k, v in extra) r[k] = v;
	return r;
}

function svc(name) {
	let u = connect();
	let r = u?.call('service', 'list', { name });
	u?.disconnect();
	let s = r?.[name];
	let running = false, pid = null;
	for (let n, i in s?.instances) if (i.running) { running = true; pid = i.pid; }
	return { running, pid, data: s?.data };
}

function nonempty(path) {
	let s = stat(path);
	if (s?.type == 'directory') return length(lsdir(path) ?? []) > 0;
	return s != null && s.size > 0;
}

function af() {
	let c = cursor();
	c.load('adblock-fast');
	let dns = c.get('adblock-fast', 'config', 'dns') ?? 'dnsmasq.servers';
	return {
		c, dns, out: OUT[dns],
		enabled: c.get('adblock-fast', 'config', 'enabled') == '1',
		A: c.get('adblock-fast', 'config', 'allowed_domain') ?? [],
		B: c.get('adblock-fast', 'config', 'blocked_domain') ?? [],
		external: length(c.get('adblock-fast', 'config', 'dnsmasq_config_file_url') ?? '') > 0
	};
}

function normalize(d) {
	if (type(d) != 'string') return null;
	d = lc(trim(d));
	if (substr(d, -1) == '.') d = substr(d, 0, -1);
	if (length(d) < 1 || length(d) > 253) return null;
	let labels = split(d, '.');
	if (length(labels) < 2) return null;
	for (let l in labels) if (!match(l, /^[a-z0-9_]([a-z0-9_-]{0,61}[a-z0-9_])?$/)) return null;
	if (match(labels[-1], /^[0-9]+$/)) return null;
	return d;
}

function listed(a, d) {
	if (!a.out || !access(a.out)) return null;
	let txt = readfile(a.out) ?? '';
	if (a.dns == 'dnsmasq.addnhosts')
		return index(txt, '127.0.0.1 ' + d + '\n') >= 0 || index(txt, ':: ' + d + '\n') >= 0;
	let labels = split(d, '.');
	for (let i = 0; i < length(labels) - 1; i++) {
		let s = join('.', slice(labels, i));
		if (index(txt, 'server=/' + s + '/#') >= 0) return false;
		if (index(txt, 'server=/' + s + '/\n') >= 0 || index(txt, 'local=/' + s + '/\n') >= 0) return true;
	}
	return false;
}

function rule(a, d) {
	let manual = (d in a.A) ? 'allow' : ((d in a.B) ? 'block' : null);
	let parent = null, labels = split(d, '.');
	for (let i = 1; i < length(labels) - 1 && !parent; i++) {
		let s = join('.', slice(labels, i));
		if (s in a.A) parent = { list: 'allow', domain: s };
		else if (s in a.B) parent = { list: 'block', domain: s };
	}
	let l = listed(a, d);
	let eff = (l === true) ? 'blocked' : ((l === false || manual == 'allow') ? 'allowed' : 'unknown');
	let actions = [];
	if (eff != 'allowed') push(actions, 'allow');
	if (manual == 'block') push(actions, 'unblock');
	if (eff != 'blocked') push(actions, 'block');
	if (manual == 'allow') push(actions, 'unallow');
	return { manual, manual_parent: parent, listed: l, effective: eff, actions };
}

function readjob() {
	let j = null;
	try { j = json(readfile(JOB) ?? 'null'); } catch (e) {}
	return j;
}

function joblock() {
	let f = open('/var/lock/adblock-fast-monitor.lock', 'a');
	return (f && f.lock('xn')) ? f : null;
}

function freshjob() {
	let j = readjob();
	if (!j || j.state in [ 'applied', 'partial', 'failed' ]) return j;
	let f = joblock();
	if (!f) return j;
	f.lock('u'); f.close();
	if (j.state == 'queued' && time() - j.created_at < 30) return j;
	j.state = 'failed'; j.finished_at = time();
	j.error = { code: j.state == 'queued' ? 'start-timeout' : 'interrupted', message: 'job is not running' };
	writefile(JOB + '.tmp', j); rename(JOB + '.tmp', JOB);
	return j;
}

function plan(a, op, d) {
	let ch = [], eff = op, inA = d in a.A, inB = d in a.B;
	if (op == 'unblock' && !inB) eff = 'allow';
	if (eff == 'allow') { if (!inA) push(ch, 'allow:add'); if (inB) push(ch, 'block:remove'); }
	else if (eff == 'unblock') push(ch, 'block:remove');
	else if (eff == 'block') { if (inA) push(ch, 'allow:remove'); if (!inB) push(ch, 'block:add'); }
	else if (eff == 'unallow') { if (inA) push(ch, 'allow:remove'); }
	return { op, domain: d, effective_op: eff, change: ch };
}

const PROTECTED = [ 'localhost', 'arpa', 'local', 'internal', 'home.arpa', 'lan' ];

const methods = {
	info: { call: function() {
		let c = cursor();
		let a = af(), s = svc('adblock-fast'), m = svc('adblock-fast-monitor'), d = svc('dnsmasq');
		let u = connect(), objs = u?.list() ?? []; u?.disconnect();
		let instances = [], warn = [];
		c.foreach('dhcp', 'dnsmasq', (sec) => {
			if (sec.disabled == '1') return;
			let cd = sec.confdir ? split(sec.confdir, ',')[0] : '/tmp/dnsmasq.' + sec['.name'] + '.d';
			push(instances, { section: sec['.name'], confdir: substr(cd, 0, 1) == '/' ? cd : null,
				dropin: access(cd + '/adblock-fast-monitor.conf') == true, uci_logqueries: sec.logqueries == '1',
				logfacility_file: index(sec.logfacility ?? '', '/') >= 0 });
		});
		for (let i in instances) if (i.dropin || i.uci_logqueries) { push(warn, 'query-logging-active'); break; }
		let sys = c.get_first('system', 'system');
		if (c.get('system', sys, 'log_file')) push(warn, 'logd-to-flash');
		if (c.get('system', sys, 'log_ip')) push(warn, 'logd-remote');
		return { api: 1, ok: true,
			monitor: { enabled: c.get('adblock-fast-monitor', 'config', 'enabled') == '1',
				manage_logging: c.get('adblock-fast-monitor', 'config', 'manage_logging') != '0',
				poll_interval: +(c.get('adblock-fast-monitor', 'config', 'poll_interval') ?? 5),
				service: { running: m.running, pid: m.pid }, object: 'adblock-fast-monitor' in objs },
			adblock_fast: { installed: access('/etc/init.d/adblock-fast') == true && access('/etc/config/adblock-fast') == true,
				enabled: a.enabled, status: s.data?.status ?? null, dns: a.dns, output_file: a.out,
				output_exists: a.out ? access(a.out) == true : false, external_config: a.external,
				pending_uci_changes: nonempty('/tmp/.uci/adblock-fast') },
			dnsmasq: { running: d.running, instances }, warnings: warn };
	} },

	rules: { args: { domains: [] }, call: function(req) {
		let a = af(), out = {};
		let list = req.args?.domains ?? [];
		if (type(list) != 'array' || length(list) > 50) return err('invalid-argument', 'domains');
		for (let d in list) { let n = normalize(d); if (n) out[n] = rule(a, n); }
		return { api: 1, ok: true, allowed_domain: a.A, blocked_domain: a.B, truncated: false, domains: out };
	} },

	job: { args: { job_id: '' }, call: function(req) {
		let j = freshjob(), id = req.args?.job_id;
		if (id && (!j || j.id != id)) return err('not-found', 'no such job');
		return { api: 1, ok: true, job: j };
	} },

	apply: { args: { ops: [], confirm_rebuild: false, rebuild: false, dry_run: false }, call: function(req) {
		let r = req.args ?? {}, ops = r.ops ?? [];
		if (type(ops) != 'array') return err('invalid-request', 'ops');
		if (length(ops) > 64) return err('batch-too-large', 'too many ops');
		if (!length(ops) && !r.rebuild) return err('batch-empty', 'no ops');
		let seen = {}, norm = [];
		for (let i, o in ops) {
			let d = normalize(o?.domain);
			if (!(o?.op in [ 'allow', 'unblock', 'block', 'unallow' ]) || !d)
				return err('invalid-domain', 'invalid domain', { index: i, domain: o?.domain });
			for (let p in PROTECTED)
				if ((o.op in [ 'block', 'unallow' ]) && (d == p || substr(d, -length(p) - 1) == '.' + p))
					return err('protected-domain', 'protected', { index: i, domain: d });
			if (seen[d] && seen[d] != o.op) return err('conflict', 'conflict', { index: i, domain: d });
			if (!seen[d]) push(norm, { op: o.op, domain: d });
			seen[d] = o.op;
		}
		if (!access('/etc/init.d/adblock-fast')) return err('adblock-fast-missing');
		let a = af();
		if (a.external) return err('external-config');
		if (nonempty('/tmp/.uci/adblock-fast')) return err('pending-uci-changes', 'adblock-fast has unsaved LuCI changes');
		let p = map(norm, (o) => plan(a, o.op, o.domain));
		let s = svc('adblock-fast');
		let mode = 'rebuild', fast = true, any = false;
		for (let x in p) if (length(x.change)) {
			any = true;
			if (x.effective_op != 'allow') fast = false;
		}
		if (!a.enabled) mode = 'persist-only';
		else if (fast && any && a.out && access(a.out) && s.data?.status == 'statusSuccess') mode = 'fast-allow';
		if (!any && !r.rebuild) return { api: 1, ok: true, noop: true, job_id: null, plan: p };
		if (mode == 'rebuild' && !r.confirm_rebuild) return err('confirm-required', 'rebuild needs confirmation', { mode, plan: p });
		let resp = { api: 1, ok: true, mode, may_escalate: mode == 'fast-allow', plan: p };
		if (r.dry_run) return resp;
		mkdir(RUN, 0700); mkdir(SAVEDIR, 0700);
		let f = joblock();
		let cur = readjob();
		if (!f)
			return err('busy', 'a job is running', { job_id: cur?.id });
		if (cur?.state == 'queued' && time() - cur.created_at < 30) {
			f.lock('u'); f.close();
			return err('busy', 'a job is starting', { job_id: cur.id });
		}
		let c = cursor(null, SAVEDIR);
		for (let x in p) for (let ch in x.change) {
			let parts = split(ch, ':'), lst = parts[0], act = parts[1];
			let opt = lst == 'allow' ? 'allowed_domain' : 'blocked_domain';
			let vals = c.get('adblock-fast', 'config', opt) ?? [];
			vals = (act == 'add') ? [ ...vals, x.domain ] : filter(vals, (v) => v != x.domain);
			if (length(vals)) c.set('adblock-fast', 'config', opt, vals); else c.delete('adblock-fast', 'config', opt);
		}
		c.commit('adblock-fast');
		let id = sprintf('j%d-%04x', time(), math_rand());
		let items = map(p, (x) => ({ ...x, expect: x.op in [ 'allow', 'unblock' ] ? 'allowed' : (x.op == 'block' ? 'blocked' : 'any'),
			result: 'pending', observed: null, answer: null, reason: null }));
		let job = { id, state: 'queued', mode, phase: null, created_at: time(), started_at: null, finished_at: null,
			persisted: true, escalated: false, output_file: a.out, adblock_fast_status: s.data?.status ?? null, error: null, items,
			confirm_rebuild: !!r.confirm_rebuild, rebuild: !!r.rebuild };
		writefile(JOB + '.tmp', job); rename(JOB + '.tmp', JOB);
		f.lock('u'); f.close();
		if (system('/usr/bin/ucode ' + JOBUC + ' ' + id + ' </dev/null >/dev/null 2>&1 &') != 0)
			return err('spawn-failed', 'spawn failed', { persisted: true });
		resp.job_id = id; resp.state = 'queued';
		return resp;
	} }
};

function math_rand() {
	let s = readfile('/dev/urandom', 2);
	return ord(s, 0) * 256 + ord(s, 1);
}

return { 'luci.adblock-fast-monitor': methods };
