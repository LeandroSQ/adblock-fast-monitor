// SPDX-License-Identifier: Apache-2.0
// The real logging.uc script (docs/CONTRACT.md §5) run as a process in the
// userland container: `reconcile` reads query_logging itself, `disable`,
// `status`, a usage error, and `write-failed` with exit status 1 when a
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

system('mkdir -p /etc/config /var/lock /usr/share/ucode && ln -sfn /src/root/usr/share/ucode/abfm /usr/share/ucode/abfm');

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
		t.match(r.out, /usage: logging\.uc reconcile\|disable\|status/);
	}
	t.ok(!fs.access(DROPIN));
});

system(`rm -rf ${DIR} ${LOCK} /usr/share/ucode/abfm /etc/config/adblock-fast-monitor /etc/config/dhcp`);
t.done();
