// SPDX-License-Identifier: Apache-2.0
// §3 option parsing and §5 query-logging drop-ins (abfm.system) against a
// temporary UCI directory and real files. T08's unit half: drop-in set,
// restart-once rule, /etc/config/dhcp never written; T32's stale /dev/log
// detection and its loop guard against a fake /proc.
'use strict';

push(REQUIRE_SEARCH_PATH, sourcepath(0, true) + '/../../../root/usr/share/ucode/*.uc');

const fs = require('fs');
const cursor = require('uci').cursor;
const sys = require('abfm.system');

let t = require('testlib');

let base = `/tmp/abfm-system-test.${fs.readlink("/proc/self")}`;
let confdir_root = `${base}/run`;
fs.mkdir(base);
fs.mkdir(`${base}/config`);
fs.mkdir(`${base}/save`);
fs.mkdir(confdir_root);

function write(name, text) {
	fs.writefile(`${base}/config/${name}`, text);
}

function cur() {
	return cursor(`${base}/config`, `${base}/save`);
}

function dhcp(extra) {
	write('dhcp', `
config dnsmasq
	option domain 'lan'
	option local '/lan/'
	option confdir '${confdir_root}/main.d,*.conf'

config dnsmasq 'guest'
	option domain 'guest.example'
	option local '/guest.example/'

config dnsmasq 'off'
	option disabled '1'
	option confdir '${confdir_root}/off.d'
${extra ?? ''}
config dhcp 'lan'
	option interface 'lan'
`);
}

function monitor(opts) {
	let text = "config monitor 'config'\n";
	for (let k, v in opts ?? {})
		if (type(v) == 'array')
			for (let x in v)
				text += `\tlist ${k} '${x}'\n`;
		else
			text += `\toption ${k} '${v}'\n`;
	write('adblock-fast-monitor', text);
}

function rm_rf(path) {
	let st = fs.lstat(path);
	if (!st)
		return;
	if (st.type == 'directory') {
		for (let e in fs.lsdir(path))
			rm_rf(`${path}/${e}`);
		fs.rmdir(path);
	}
	else {
		fs.unlink(path);
	}
}

function harness(running) {
	let h = { restarts: 0 };
	h.opts = { cursor: cur(), running: () => running, restart: (why) => { h.restarts++; h.why = why; } };
	return h;
}

function apply(mode, running) {
	let h = harness(running ?? true);
	h.res = sys.logging_apply(mode, h.opts);
	return h;
}

function guest_dir() {
	let sections = sys.dnsmasq_sections(cur());
	return sections[1].confdir;
}

t.test('§3: query_logging parses like UCI booleans; other options are ignored', () => {
	monitor({});
	t.eq(sys.monitor_config(cur()), { query_logging: false });
	monitor({ query_logging: 'yes', exclude_router: '0', poll_interval: '9', dnsmasq_instance: [ 'guest' ], enabled: '1' });
	t.eq(sys.monitor_config(cur()), { query_logging: true }, 'unknown options are ignored');
	monitor({ query_logging: 'maybe' });
	t.eq(sys.monitor_config(cur()), { query_logging: false }, 'unparsable -> default');
	monitor({ query_logging: 'off' });
	t.eq(sys.monitor_config(cur()).query_logging, false);
	write('adblock-fast-monitor', '');
	t.eq(sys.monitor_config(cur()).query_logging, false, 'missing section');
});

t.test('§5: confdir defaults, comma suffix, relative paths are invalid', () => {
	t.eq(sys.confdir_of('cfg01411c', null), '/tmp/dnsmasq.cfg01411c.d');
	t.eq(sys.confdir_of('x', '/tmp/x.d,*.conf'), '/tmp/x.d');
	t.eq(sys.confdir_of('x', '/tmp/x.d/'), '/tmp/x.d');
	t.eq(sys.confdir_of('x', 'relative/dir'), null);
	t.eq(sys.confdir_of('x', ''), null);
});

t.test('§5: sections use UCI names; every enabled section is a target', () => {
	dhcp();
	monitor({});
	let s = sys.dnsmasq_sections(cur());
	t.eq(length(s), 3);
	t.match(s[0].section, /^cfg[0-9a-f]{6}$/, 'anonymous section name');
	t.eq([ s[0].confdir, s[1].section, s[1].confdir, s[2].disabled ],
		[ `${confdir_root}/main.d`, 'guest', '/tmp/dnsmasq.guest.d', true ]);
	t.eq(map(sys.logging_targets(cur()), (x) => x.section), [ s[0].section, 'guest' ]);
	t.eq(sys.local_domains(cur()), [ 'lan', 'guest.example' ]);
});

t.test('§5: adblock-fast dns mode', () => {
	write('adblock-fast', '');
	t.eq(sys.adblock_fast_dns(cur()), null, 'no adblock-fast config');
	write('adblock-fast', "config adblock-fast 'config'\n\toption enabled '1'\n");
	t.eq(sys.adblock_fast_dns(cur()), 'dnsmasq.servers', 'adblock-fast default');
	write('adblock-fast', "config adblock-fast 'config'\n\toption dns 'dnsmasq.nftset'\n");
	t.eq(sys.adblock_fast_dns(cur()), 'dnsmasq.nftset');
});

// The guest section's default confdir lives under /tmp; point it into the
// test directory so nothing outside it is touched.
dhcp();
write('dhcp', replace(fs.readfile(`${base}/config/dhcp`), "config dnsmasq 'guest'\n",
	`config dnsmasq 'guest'\n\toption confdir '${confdir_root}/guest.d'\n`));
let DHCP_BYTES = fs.readfile(`${base}/config/dhcp`);
let MAIN = `${confdir_root}/main.d/adblock-fast-monitor.conf`;
let GUEST = `${confdir_root}/guest.d/adblock-fast-monitor.conf`;

t.test('§5 enable: one drop-in per target, 0644, restart exactly once', () => {
	monitor({});
	let h = apply('enable');
	t.eq([ h.res.changed, h.res.restarted, h.restarts, h.res.errors ], [ true, true, 1, [] ]);
	t.eq(sort(h.res.dropins), [ GUEST, MAIN ]);
	for (let p in [ MAIN, GUEST ]) {
		t.eq(fs.readfile(p), 'log-queries=extra\nlog-async=25\n');
		t.eq(fs.lstat(p).mode & 0o777, 0o644);
	}
	t.eq(fs.lstat(`${confdir_root}/main.d`).mode & 0o777, 0o755, 'confdir created 0755');
	t.ok(!fs.lstat(`${confdir_root}/off.d`), 'disabled instance untouched');
	t.eq(fs.lsdir(`${confdir_root}/main.d`), [ 'adblock-fast-monitor.conf' ], 'no temp file left');
});

t.test('§5 enable again: unchanged set, no restart', () => {
	let h = apply('enable');
	t.eq([ h.res.changed, h.restarts ], [ false, 0 ]);
});

t.test('§5 a damaged drop-in is rewritten without a restart', () => {
	fs.writefile(MAIN, 'garbage\n');
	let h = apply('enable');
	t.eq([ h.res.changed, h.restarts, fs.readfile(MAIN) ], [ false, 0, sys.DROPIN_CONTENT ]);
});

t.test('§5 disabling an instance in dhcp removes its drop-in (one restart)', () => {
	write('dhcp', replace(DHCP_BYTES, "config dnsmasq 'guest'\n", "config dnsmasq 'guest'\n\toption disabled '1'\n"));
	let h = apply('enable');
	t.eq([ h.res.changed, h.restarts, h.res.dropins ], [ true, 1, [ MAIN ] ]);
	t.ok(!fs.lstat(GUEST));
	write('dhcp', DHCP_BYTES);
	h = apply('enable');
	t.eq([ h.res.changed, h.restarts, sort(h.res.dropins) ], [ true, 1, [ GUEST, MAIN ] ], 'enabled again: drop-in back');
});

t.test('§5 an instance with logqueries=1 gets no drop-in', () => {
	write('dhcp', replace(DHCP_BYTES, "config dnsmasq 'guest'\n", "config dnsmasq 'guest'\n\toption logqueries '1'\n"));
	let h = apply('enable');
	t.eq([ h.res.changed, h.restarts, h.res.dropins ], [ true, 1, [ MAIN ] ]);
	let st = sys.logging_status(cur(), null);
	t.eq(st.instances[1], { section: 'guest', confdir: `${confdir_root}/guest.d`, dropin: false, uci_logqueries: true, running: false });
	write('dhcp', DHCP_BYTES);
});

t.test('§5 changes while dnsmasq is not running never restart it (boot)', () => {
	apply('disable');
	let h = apply('enable', false);
	t.eq([ h.res.changed, h.res.restarted, h.restarts ], [ true, false, 0 ]);
	t.ok(fs.lstat(MAIN) && fs.lstat(GUEST));
});

t.test('§5 status reports every section', () => {
	let st = sys.logging_status(cur(), null);
	t.eq(length(st.instances), 3);
	t.eq(st.instances[0].dropin, true);
	t.eq(st.instances[1], { section: 'guest', confdir: `${confdir_root}/guest.d`, dropin: true, uci_logqueries: false, running: false });
	t.eq(st.instances[2].dropin, false);
});

t.test('§5 disable removes drop-ins under every section, including disabled ones', () => {
	fs.mkdir(`${confdir_root}/off.d`);
	fs.writefile(`${confdir_root}/off.d/adblock-fast-monitor.conf`, 'log-queries=extra\n');
	fs.writefile(`${confdir_root}/off.d/other.conf`, 'keep\n');
	let h = apply('disable');
	t.eq([ h.res.changed, h.restarts, h.res.dropins ], [ true, 1, [] ]);
	t.ok(!fs.lstat(MAIN) && !fs.lstat(GUEST) && !fs.lstat(`${confdir_root}/off.d/adblock-fast-monitor.conf`));
	t.eq(fs.readfile(`${confdir_root}/off.d/other.conf`), 'keep\n', 'foreign files untouched');
	h = apply('disable');
	t.eq([ h.res.changed, h.restarts ], [ false, 0 ], 'second disable is a no-op');
});

t.test('§5 an invalid confdir is reported and skipped', () => {
	write('dhcp', DHCP_BYTES + "\nconfig dnsmasq 'bad'\n\toption confdir 'relative.d'\n");
	let h = apply('enable');
	t.eq(h.res.errors, [ { section: 'bad', error: 'confdir-invalid' } ]);
	t.eq(length(h.res.dropins), 2);
	let st = sys.logging_status(cur(), null);
	t.eq(st.instances[3], { section: 'bad', confdir: null, dropin: false, uci_logqueries: false, running: false, reason: 'confdir-invalid' });
	apply('disable');
	write('dhcp', DHCP_BYTES);
});

t.test('§5 /etc/config/dhcp is never written', () => {
	t.eq(fs.readfile(`${base}/config/dhcp`), DHCP_BYTES);
	t.eq(fs.lsdir(`${base}/save`), [], 'no UCI delta saved');
});

t.test('service_state reads procd instances and their pids through ubus', () => {
	let fake = { call: (o, m, a) => (o == 'service' && m == 'list' && a.name == 'dnsmasq')
		? { dnsmasq: { instances: { cfg01411c: { running: true, pid: 5 }, guest: { running: false, pid: 9 } } } } : null };
	t.eq(sys.service_state(fake, 'dnsmasq'), { running: true, instances: { cfg01411c: true, guest: false }, pids: [ 5 ] });
	t.eq(sys.service_state({ call: () => null }, 'dnsmasq'), { running: false, instances: {}, pids: [] });
	t.eq(sys.service_state(null, 'dnsmasq'), { running: false, instances: {}, pids: [] });
});

function stale_apply(mode, stale, running) {
	let h = harness(running ?? true);
	h.opts.stale = () => { h.asked = true; return stale; };
	h.res = sys.logging_apply(mode, h.opts);
	return h;
}

t.test('§4 stale /dev/log: enable with drop-ins in place restarts dnsmasq once', () => {
	dhcp();
	monitor({});
	apply('enable');
	let h = stale_apply('enable', true);
	t.eq([ h.res.changed, h.res.stale, h.restarts, h.why ], [ false, true, 1, 'stale' ]);
	h = stale_apply('enable', false);
	t.eq([ h.res.changed, h.res.stale, h.restarts ], [ false, false, 0 ], 'fresh socket: no restart');
	h = stale_apply('enable', true, false);
	t.eq(h.restarts, 0, 'dnsmasq not running: nothing to restart');
});

t.test('§4 stale /dev/log is ignored without drop-ins (query_logging=0 or disable)', () => {
	let h = stale_apply('disable', true);
	t.eq([ h.res.stale, h.asked ?? false, h.restarts, h.why ], [ false, false, 1, 'changed' ], 'only the set change restarts');
	h = stale_apply('disable', true);
	t.eq([ h.res.changed, h.res.stale, h.restarts ], [ false, false, 0 ]);
	write('dhcp', replace(DHCP_BYTES, /config dnsmasq( '[a-z]+')?\n/g, (m) => m + "\toption disabled '1'\n"));
	h = stale_apply('enable', true);
	t.eq([ h.res.dropins, h.res.stale, h.restarts ], [ [], false, 0 ], 'no enabled instance: no drop-in, no restart');
	write('dhcp', DHCP_BYTES);
});

// Fake /proc: procd's dnsmasq instance is a ujail (pid 3360, comm dnsmasq,
// host root) whose child 3361 is the jailed dnsmasq; 3400 is a dnsmasq with
// the current socket; 4000 is a foreign dnsmasq in its own root (a chroot or
// container) whose /dev/log is some other file forever; 12 is logd.
let R = `${base}/root`;
function fake_proc(pid, ppid, comm, log) {
	for (let d in [ `${R}/proc/${pid}`, `${R}/proc/${pid}/root`, `${R}/proc/${pid}/root/dev` ])
		fs.mkdir(d);
	fs.writefile(`${R}/proc/${pid}/comm`, comm + '\n');
	fs.writefile(`${R}/proc/${pid}/stat`, `${pid} (${comm}) S ${ppid} ${pid} ${pid} 0 -1\n`);
	if (log == 'same')
		fs.symlink(`${R}/dev/log`, `${R}/proc/${pid}/root/dev/log`);
	else if (log)
		fs.writefile(`${R}/proc/${pid}/root/dev/log`, log);
}

t.test('§4 dnsmasq_log_stale: only procd instance pids and their children count', () => {
	for (let d in [ R, `${R}/dev`, `${R}/proc` ])
		fs.mkdir(d);
	t.eq(sys.dnsmasq_log_stale(R, [ 3360 ]), [], 'no /dev/log: nothing is stale');
	fs.writefile(`${R}/dev/log`, 'current');
	fake_proc(1, 0, 'procd', 'same');
	fake_proc(3360, 1, 'dnsmasq', 'same');
	fake_proc(3361, 3360, 'dnsmasq', 'old');
	fake_proc(3400, 1, 'dnsmasq', 'same');
	fake_proc(4000, 1, 'dnsmasq', 'foreign');
	fake_proc(4001, 4000, 'dnsmasq', 'foreign');
	fake_proc(12, 1, 'logd', 'old');
	fs.mkdir(`${R}/proc/self`);
	t.eq(sys.dnsmasq_log_stale(R, [ 3360 ]), [ 3361 ], 'the jailed child of the instance');
	t.eq(sys.dnsmasq_log_stale(R, [ 3400 ]), [], 'an instance with the current socket');
	t.eq(sys.dnsmasq_log_stale(R, []), [], 'no instance running: nothing to restart');
	t.eq(sys.dnsmasq_log_stale(R, [ 3360, 3400 ]), [ 3361 ], 'the foreign dnsmasq is never a candidate');
	t.eq(sys.dnsmasq_log_stale(`${base}/missing`, [ 3360 ]), []);
});

t.test('§4 loop guard: one stale restart per logd socket', () => {
	let stamp = `${base}/stale-restart`;
	t.eq(sys.dnsmasq_stale_restart(R, [ 3360 ], stamp), [ 3361 ], 'first time: restart');
	t.eq(trim(fs.readfile(stamp)), sys.log_socket_id(R), 'the socket is recorded');
	t.eq(sys.dnsmasq_stale_restart(R, [ 3360 ], stamp), [], 'still stale against the same socket: no second restart');
	fs.unlink(`${R}/dev/log`);
	fs.writefile(`${R}/dev/log`, 'new socket');
	t.ok(sys.log_socket_id(R) != trim(fs.readfile(stamp)), 'logd restarted again (new inode)');
	t.eq(sys.dnsmasq_stale_restart(R, [ 3360 ], stamp), [ 3361 ], 'a new logd socket allows a new restart');
	fs.unlink(`${R}/proc/3361/root/dev/log`);
	fs.symlink(`${R}/dev/log`, `${R}/proc/3361/root/dev/log`);
	t.eq(sys.dnsmasq_stale_restart(R, [ 3360 ], stamp), [], 'fresh: nothing to do');
});

rm_rf(base);
t.done();
