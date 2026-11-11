// SPDX-License-Identifier: Apache-2.0
// The real rpcd plugin (root/usr/share/rpcd/ucode/luci.adblock-fast-monitor),
// loaded with loadfile() the way rpcd loads it and called method by method in
// the userland container: real uci, real flock, the real job.uc spawned
// through setsid. There is no ubusd, so ubus.connect() returns null (adblock-
// fast status and dnsmasq state read as unknown/stopped). Covers the §6.3
// pipeline order, §7.3 busy/reap rules, reply shapes and file modes (T14,
// T19 host half). The container's / is disposable: this test writes the
// router paths the plugin uses and removes them again.
'use strict';

const fs = require('fs');

let t = require('testlib');

if (getenv('ABFM_SRC') != '/src' || fs.access('/etc/init.d/adblock-fast'))
	die('plugin.test.uc writes router paths; run it only in the userland container (npm run test:ucode)\n');

const SRC = '/src/root';
const RUN = '/var/run/adblock-fast-monitor';
const JOB_FILE = RUN + '/job.json';
const LOCK_FILE = '/var/lock/adblock-fast-monitor.lock';
const JOB_BIN = '/usr/libexec/adblock-fast-monitor/job.uc';
const AF_DELTA = '/tmp/.uci/adblock-fast';

function sh(cmd) {
	return system(cmd);
}

sh(`mkdir -p /etc/config /etc/init.d /var/run /var/lock /tmp/.uci /usr/share/ucode /usr/libexec/adblock-fast-monitor
	ln -sfn ${SRC}/usr/share/ucode/abfm /usr/share/ucode/abfm
	cp ${SRC}/usr/libexec/adblock-fast-monitor/job.uc ${JOB_BIN} && chmod 0755 ${JOB_BIN}
	printf '#!/bin/sh\\nexit 0\\n' >/etc/init.d/adblock-fast && chmod 0755 /etc/init.d/adblock-fast`);

function config(name, text) {
	fs.writefile(`/etc/config/${name}`, text);
}

const AF_CONFIG = `
config adblock-fast 'config'
	option enabled '1'
	option dns 'dnsmasq.servers'
	option heartbeat_domain 'hb.example.net'
	list allowed_domain 'kept.example.com'

config file_url 'fixture'
	option url 'http://lists.example.org/block.txt'
	option enabled '1'
`;
config('adblock-fast', AF_CONFIG);
config('adblock-fast-monitor', "config monitor 'config'\n\toption query_logging '1'\n");
config('dhcp', "config dnsmasq\n\toption domain 'lan'\n\toption local '/lan/'\n\toption confdir '/tmp/abfm-plugin-test.d'\n");
config('system', "config system\n\toption hostname 'TestRouter'\n\toption log_size '128'\n");

let plugin = loadfile(`${SRC}/usr/share/rpcd/ucode/luci.adblock-fast-monitor`)();
let obj = plugin['luci.adblock-fast-monitor'];

function call(method, args) {
	return obj[method].call({ args: args ?? {} });
}
function code(r) {
	return r?.error?.code;
}
function apply(args) {
	return call('apply', args);
}
function read_job() {
	return json(fs.readfile(JOB_FILE) ?? 'null');
}
function write_job(job) {
	fs.writefile(JOB_FILE, sprintf('%J', job));
}
function af_list(opt) {
	let c = require('uci').cursor();
	let v = c.get('adblock-fast', 'config', opt);
	return type(v) == 'array' ? v : (v ? [ v ] : []);
}
function lock_hold() {
	let f = fs.open(LOCK_FILE, 'a', 0o600);
	return f.lock('xn') ? f : null;
}
function wait_terminal(id) {
	for (let i = 0; i < 300; i++) {
		let j = call('job', { job_id: id });
		if (j.job && index([ 'applied', 'partial', 'failed' ], j.job.state) >= 0)
			return j.job;
		sleep(100);
	}
	return call('job', { job_id: id }).job;
}

const BLOCK = { ops: [ { op: 'block', domain: 'ads.example.com' } ], confirm_rebuild: true };

t.test('the plugin declares exactly info, apply and job with the §6 signatures', () => {
	t.eq(sort(keys(plugin)), [ 'luci.adblock-fast-monitor' ]);
	t.eq(sort(keys(obj)), [ 'apply', 'info', 'job' ]);
	t.eq([ obj.info.args, obj.apply.args, obj.job.args ],
		[ {}, { ops: [], confirm_rebuild: true, rebuild: true, dry_run: true }, { job_id: '' } ]);
});

t.test('info: api 2 shape, monitor has only query_logging, protected_suffixes', () => {
	let r = call('info');
	t.eq(sort(keys(r)), [ 'adblock_fast', 'api', 'dnsmasq', 'local_domains', 'logd', 'monitor', 'ok', 'protected_suffixes', 'warnings' ]);
	t.eq([ r.api, r.ok, r.monitor, r.local_domains, r.logd ], [ 2, true, { query_logging: true }, [ 'lan' ], { size_kib: 128 } ]);
	t.eq(r.protected_suffixes, [ 'localhost', 'arpa', 'local', 'internal', 'invalid', 'onion', 'bind',
		'hb.example.net', 'lan', 'testrouter' ]);
	t.eq(sort(keys(r.adblock_fast)), [ 'dns', 'enabled', 'external_config', 'installed', 'output_exists',
		'output_file', 'pending_uci_changes', 'status' ]);
	t.eq([ r.adblock_fast.installed, r.adblock_fast.enabled, r.adblock_fast.status, r.adblock_fast.dns ],
		[ true, true, null, 'dnsmasq.servers' ]);
	t.eq(r.dnsmasq.running, false, 'no ubusd: dnsmasq reads as stopped');
	t.eq(r.dnsmasq.instances[0].confdir, '/tmp/abfm-plugin-test.d');
	t.eq(r.warnings, []);
});

t.test('§6.3 rejects at the first failing step: shape, then domains, then preconditions', () => {
	sh('mv /etc/init.d/adblock-fast /etc/init.d/adblock-fast.off');
	let ops65 = [];
	for (let i = 0; i < 65; i++)
		push(ops65, { op: 'allow', domain: `d${i}.example.com` });
	t.eq(code(apply({ ops: ops65 })), 'batch-too-large', 'step 1 before adblock-fast-missing');
	t.eq(code(apply({ ops: [ { op: 'unblock', domain: 'a.example.com' } ] })), 'invalid-request');
	t.eq(code(apply({})), 'batch-empty');
	let r = apply({ ops: [ { op: 'allow', domain: 'ok.example.com' }, { op: 'block', domain: 'bad..example.com' } ] });
	t.eq([ code(r), r.error.index, r.error.domain ], [ 'invalid-domain', 1, 'bad..example.com' ], 'step 2 before step 4');
	t.eq(code(apply({ ops: [ { op: 'block', domain: 'x.lan' } ] })), 'protected-domain');
	t.eq(code(apply({ ops: [ { op: 'allow', domain: 'a.example.com' }, { op: 'block', domain: 'a.example.com' } ] })), 'conflict', 'step 3 before step 4');
	t.eq(code(apply(BLOCK)), 'adblock-fast-missing');
	sh('mv /etc/init.d/adblock-fast.off /etc/init.d/adblock-fast');

	config('adblock-fast', replace(AF_CONFIG, "option dns 'dnsmasq.servers'", "option dns 'unbound.adb_list'\n\toption dnsmasq_config_file_url 'https://lists.example.org/x.conf'"));
	fs.writefile(AF_DELTA, "adblock-fast.config.verbosity='2'\n");
	t.eq(code(apply(BLOCK)), 'external-config', 'external-config is checked first');
	config('adblock-fast', replace(AF_CONFIG, "option dns 'dnsmasq.servers'", "option dns 'unbound.adb_list'"));
	t.eq(code(apply(BLOCK)), 'unsupported-dns-mode', 'then the dns mode');
	config('adblock-fast', AF_CONFIG);
	t.eq(code(apply(BLOCK)), 'pending-uci-changes', 'then uncommitted CLI changes');
	fs.writefile(AF_DELTA, "adblock-fast.fixture.size='180'\n");
	r = apply({ ops: [ { op: 'block', domain: 'x.kept.example.com' } ], confirm_rebuild: true });
	t.eq([ code(r), r.error.domain ], [ 'allow-overrides', 'x.kept.example.com' ], 'size bookkeeping is not pending; step 5');
	r = apply({ ops: [ { op: 'block', domain: 'ads.example.com' } ] });
	t.eq([ code(r), r.mode, r.plan ], [ 'confirm-required', 'rebuild', [ { op: 'block', domain: 'ads.example.com', change: [ 'block:add' ] } ] ]);
	fs.unlink(AF_DELTA);
});

t.test('dry_run and noop write nothing and start no job', () => {
	let before = fs.readfile('/etc/config/adblock-fast');
	let r = apply({ ...BLOCK, dry_run: true });
	t.eq(r, { api: 2, ok: true, dry_run: true, noop: false, mode: 'rebuild',
		plan: [ { op: 'block', domain: 'ads.example.com', change: [ 'block:add' ] } ] });
	r = apply({ ops: [ { op: 'allow', domain: 'kept.example.com' } ] });
	t.eq(r, { api: 2, ok: true, noop: true, job_id: null, mode: 'rebuild',
		plan: [ { op: 'allow', domain: 'kept.example.com', change: [] } ] });
	t.eq(fs.readfile('/etc/config/adblock-fast'), before);
	t.ok(!fs.access(JOB_FILE), 'no job.json');
	t.eq(call('job'), { api: 2, ok: true, job: null });
	t.eq(code(call('job', { job_id: 'j0000000000-0000' })), 'not-found');
	t.eq(code(call('job', { job_id: '../../etc/passwd' })), 'not-found');
});

t.test('§7.3 busy: lock held, then a fresh queued job.json (the spawn hand-off window)', () => {
	let held = lock_hold();
	t.ok(held, 'the test holds the job lock');
	let r = apply(BLOCK);
	t.eq([ code(r), r.job_id ], [ 'busy', null ]);
	held.lock('u');
	held.close();
	t.eq(af_list('blocked_domain'), [], 'busy wrote nothing');

	let now = time();
	write_job({ id: sprintf('j%010d-beef', now), state: 'queued', mode: 'rebuild', phase: null, created_at: now,
		started_at: null, finished_at: null, persisted: true, adblock_fast_status: null, error: null, items: [] });
	r = apply(BLOCK);
	t.eq([ code(r), r.job_id ], [ 'busy', sprintf('j%010d-beef', now) ], 'queued < 30 s: busy with its id, deterministically');
	t.eq(af_list('blocked_domain'), [], 'still nothing written');
});

t.test('§7.3 reap: queued >= 30 s -> start-timeout, applying with a free lock -> interrupted (persisted)', () => {
	let old = time() - 60;
	let id = sprintf('j%010d-0001', old);
	write_job({ id, state: 'queued', mode: 'rebuild', phase: null, created_at: old, started_at: null, finished_at: null,
		persisted: true, adblock_fast_status: null, error: null,
		items: [ { op: 'block', domain: 'q.example.com', change: [ 'block:add' ], expect: 'blocked', result: 'pending',
			observed: null, answer: null, reason: null } ] });
	let j = call('job').job;
	t.eq([ j.id, j.state, j.error.code, j.items[0].result ], [ id, 'failed', 'start-timeout', 'unverified' ]);
	t.eq(read_job().state, 'failed', 'persisted');

	id = sprintf('j%010d-0002', old);
	write_job({ id, state: 'applying', mode: 'rebuild', phase: 'rebuild', created_at: old, started_at: old, finished_at: null,
		persisted: true, adblock_fast_status: null, error: null, items: [] });
	let held = lock_hold();
	t.eq(call('job', { job_id: id }).job.state, 'applying', 'lock held: the job is alive');
	held.lock('u');
	held.close();
	j = call('job', { job_id: id }).job;
	t.eq([ j.state, j.error.code, type(j.finished_at) ], [ 'failed', 'interrupted', 'int' ]);
	t.eq(read_job().error.code, 'interrupted', 'persisted');
	fs.unlink(JOB_FILE);
});

t.test('spawn-failed after a committed change keeps persisted:true', () => {
	sh(`chmod 0644 ${JOB_BIN}`);
	let r = apply({ ops: [ { op: 'allow', domain: 'spawn.example.com' } ], confirm_rebuild: true });
	sh(`chmod 0755 ${JOB_BIN}`);
	t.eq([ code(r), r.persisted, type(r.job_id) ], [ 'spawn-failed', true, 'string' ]);
	t.ok(index(af_list('allowed_domain'), 'spawn.example.com') >= 0, 'the UCI change was committed');
	config('adblock-fast', AF_CONFIG);
	fs.unlink(JOB_FILE);
});

t.test('uci-error when the adblock-fast config section is missing', () => {
	config('adblock-fast', replace(AF_CONFIG, "config adblock-fast 'config'", "config adblock-fast 'renamed'"));
	let r = apply(BLOCK);
	t.eq(code(r), 'uci-error');
	config('adblock-fast', AF_CONFIG);
});

t.test('a real job (persist-only) through setsid: queued reply, job reaches applied, no ctx, file modes', () => {
	config('adblock-fast', replace(AF_CONFIG, "option enabled '1'", "option enabled '0'"));
	// a LuCI session's staged change lives in its own savedir; apply must not
	// commit it (§6.3 step 9, §14.9)
	sh("mkdir -p /var/run/rpcd/uci-abfmtest && printf \"adblock-fast.config.verbosity='2'\\n\" >/var/run/rpcd/uci-abfmtest/adblock-fast");
	let r = apply({ ops: [ { op: 'block', domain: 'ads.example.com' }, { op: 'allow', domain: 'free.example.com' } ] });
	t.eq(sort(keys(r)), [ 'api', 'job_id', 'mode', 'ok', 'plan', 'state' ]);
	t.eq([ r.ok, r.state, r.mode ], [ true, 'queued', 'persist-only' ]);
	t.match(r.job_id, /^j[0-9]{10}-[0-9a-f]{4}$/);
	let j = wait_terminal(r.job_id);
	t.eq(sort(keys(j)), [ 'adblock_fast_status', 'created_at', 'error', 'finished_at', 'id', 'items', 'mode',
		'persisted', 'phase', 'started_at', 'state' ], 'no ctx and no reserved fields');
	t.eq([ j.state, j.mode, j.persisted, j.error ], [ 'applied', 'persist-only', true, null ]);
	t.eq(map(j.items, (i) => [ i.op, i.domain, i.change, i.expect, i.result ]), [
		[ 'block', 'ads.example.com', [ 'block:add' ], 'blocked', 'skipped' ],
		[ 'allow', 'free.example.com', [ 'allow:add' ], 'allowed', 'skipped' ] ]);
	t.eq(sort(keys(j.items[0])), [ 'answer', 'change', 'domain', 'expect', 'observed', 'op', 'reason', 'result' ]);
	t.eq(af_list('blocked_domain'), [ 'ads.example.com' ]);
	t.eq(af_list('allowed_domain'), [ 'kept.example.com', 'free.example.com' ]);
	let c = require('uci').cursor();
	t.eq([ c.get('adblock-fast', 'config', 'verbosity'), c.get('adblock-fast', 'config', 'enabled') ], [ null, '0' ],
		'the session-staged change was not committed');
	t.ok(fs.access('/var/run/rpcd/uci-abfmtest/adblock-fast'), 'and is still staged');
	t.ok(!fs.access(AF_DELTA), 'nothing written to /tmp/.uci');
	t.eq(fs.stat(RUN).mode & 0o777, 0o700, 'runtime dir 0700');
	t.eq(fs.stat(RUN + '/uci').mode & 0o777, 0o700, 'private savedir 0700');
	t.eq(fs.readfile(RUN + '/uci/adblock-fast') ?? '', '', 'the private savedir holds no delta after the commit');
	t.eq(fs.stat(JOB_FILE).mode & 0o777, 0o600, 'job.json 0600');
	t.ok(lock_hold() != null, 'the job released the lock');
	t.eq(call('job').job.id, r.job_id, 'job without an id is the latest');
});

sh(`rm -rf ${RUN} /var/run/rpcd/uci-abfmtest ${LOCK_FILE} ${AF_DELTA} /etc/init.d/adblock-fast /usr/libexec/adblock-fast-monitor`);
sh('rm -rf /usr/share/ucode/abfm /etc/config/adblock-fast /etc/config/adblock-fast-monitor /etc/config/dhcp /etc/config/system');
t.done();
