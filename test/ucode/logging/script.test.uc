// SPDX-License-Identifier: Apache-2.0
// The real logging.uc script (docs/CONTRACT.md §5) run as a process in the
// userland container: `reconcile` reads query_logging itself (under the
// lock) and does nothing after `stop` until `start`, `disable`, `status`, a
// usage error, and `write-failed` with exit status 1 when a
// confdir can't be created. No ubusd runs here, so dnsmasq reads as stopped
// and nothing is restarted (the restart rule is unit-tested in
// system.test.uc and run for real on the guest).
'use strict';

const fs = require('fs');

let t = require('testlib');

if (getenv('ABFM_SRC') != '/src' || fs.access('/etc/init.d/dnsmasq'))
	die('script.test.uc writes router paths; run it only in the userland container (npm run test:ucode)\n');

const SCRIPT = '/src/root/usr/libexec/adblock-fast-monitor/logging.uc';
const DIR = '/tmp/abfm-script.d';
const DROPIN = DIR + '/adblock-fast-monitor.conf';
const LOCK = '/var/lock/adblock-fast-monitor.logging.lock';
const STOPPED = '/var/run/adblock-fast-monitor/stopped';

system('mkdir -p /etc/config /var/lock /var/run /usr/share/ucode && ln -sfn /src/root/usr/share/ucode/abfm /usr/share/ucode/abfm');

function run(mode) {
	let p = fs.popen(`ucode ${SCRIPT} ${mode} 2>&1; echo "rc=$?"`, 'r');
	let out = p.read('all');
	p.close();
	let m = match(out, /rc=([0-9]+)\n$/);
	return { rc: m ? +m[1] : -1, out: replace(out, /rc=[0-9]+\n$/, '') };
}
function config(ql, confdir) {
	fs.writefile('/etc/config/adblock-fast-monitor', `config monitor 'config'\n\toption query_logging '${ql}'\n`);
	fs.writefile('/etc/config/dhcp', `config dnsmasq 'main'\n\toption confdir '${confdir}'\n`);
}

t.test('reconcile with query_logging=1 writes the drop-in; exit 0', () => {
	config('1', DIR);
	let r = run('reconcile');
	t.eq([ r.rc, r.out ], [ 0, '' ]);
	t.eq(fs.readfile(DROPIN), 'log-queries=extra\nlog-async=25\n');
	t.eq(fs.stat(LOCK)?.mode & 0o777, 0o600, 'the logging lock file exists, 0600');
});

t.test('status prints the §5 JSON', () => {
	let r = run('status');
	t.eq(r.rc, 0);
	t.eq(json(r.out), { instances: [ { section: 'main', confdir: DIR, dropin: true, uci_logqueries: false, running: false } ] });
});

t.test('reconcile with query_logging=0 removes it; disable too', () => {
	config('0', DIR);
	t.eq(run('reconcile').rc, 0);
	t.ok(!fs.access(DROPIN));
	config('1', DIR);
	run('reconcile');
	t.ok(fs.access(DROPIN));
	t.eq(run('disable').rc, 0, 'disable ignores query_logging');
	t.ok(!fs.access(DROPIN));
});

t.test('stop removes the drop-in and marks the service stopped; a later reconcile (a queued trigger) does nothing', () => {
	config('1', DIR);
	run('reconcile');
	t.ok(fs.access(DROPIN));
	t.eq(run('stop').rc, 0);
	t.ok(!fs.access(DROPIN), 'stop removed the drop-in');
	t.ok(fs.access(STOPPED), 'stop left the stopped mark');
	t.eq(run('reconcile').rc, 0);
	t.ok(!fs.access(DROPIN), 'reconcile after stop did not bring the drop-in back');
});

t.test('start clears the stopped mark and reconciles from the config', () => {
	config('1', DIR);
	t.eq(run('start').rc, 0);
	t.ok(!fs.access(STOPPED));
	t.ok(fs.access(DROPIN));
	config('0', DIR);
	t.eq(run('start').rc, 0, 'start with query_logging=0');
	t.ok(!fs.access(DROPIN));
});

// A reconcile that waits for the lock must act on the config as it is when it
// gets the lock, not as it was when it was started (a trigger queued while
// query_logging was 1 must not bring the drop-in back after it was set to 0).
t.test('reconcile reads query_logging after it holds the lock', () => {
	config('1', DIR);
	run('start');
	t.ok(fs.access(DROPIN));
	let held = fs.open(LOCK, 'a');
	held.lock('x');
	system(`(ucode ${SCRIPT} reconcile >/tmp/abfm-bg.out 2>&1; echo "rc=$?" >>/tmp/abfm-bg.out; touch /tmp/abfm-bg.done) &`);
	let ino = fs.stat(LOCK).inode;
	let waiting = false;
	for (let i = 0; i < 100 && !waiting; i++) {
		waiting = match(fs.readfile('/proc/locks') ?? '', regexp(`->.*:${ino} `)) != null;
		if (!waiting)
			sleep(50);
	}
	t.ok(waiting, 'the background reconcile is blocked on the lock');
	config('0', DIR);
	held.lock('u');
	held.close();
	for (let i = 0; i < 100 && !fs.access('/tmp/abfm-bg.done'); i++)
		sleep(50);
	t.match(fs.readfile('/tmp/abfm-bg.out') ?? '', /rc=0\n$/);
	t.ok(!fs.access(DROPIN), 'the waiting reconcile saw query_logging=0');
	system('rm -f /tmp/abfm-bg.out /tmp/abfm-bg.done');
});

t.test('a confdir that cannot be created: write-failed on stderr, exit 1', () => {
	config('1', '/proc/abfm-readonly.d');
	let r = run('reconcile');
	t.eq(r.rc, 1);
	t.match(r.out, /adblock-fast-monitor: \/proc\/abfm-readonly\.d: write-failed/);
});

t.test('a relative confdir: confdir-invalid on stderr, exit 1', () => {
	config('1', 'relative.d');
	let r = run('reconcile');
	t.eq(r.rc, 1);
	t.match(r.out, /adblock-fast-monitor: main: confdir-invalid/);
});

t.test('any other mode is a usage error (exit 2), and changes nothing', () => {
	config('1', DIR);
	for (let m in [ 'enable', '', 'restart' ]) {
		let r = run(m);
		t.eq(r.rc, 2, `mode '${m}'`);
		t.match(r.out, /usage: logging\.uc start\|stop\|reconcile\|disable\|status/);
	}
	t.ok(!fs.access(DROPIN));
});

system(`rm -rf ${DIR} ${LOCK} /var/run/adblock-fast-monitor /usr/share/ucode/abfm /etc/config/adblock-fast-monitor /etc/config/dhcp`);
t.done();
