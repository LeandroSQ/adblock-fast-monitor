// §3 option parsing and §5 query-logging drop-ins (abfm.system) against a
// temporary UCI directory and real files. T08's unit half: drop-in set,
// restart-once rule, /etc/config/dhcp never written.
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
	h.opts = { cursor: cur(), running: () => running, restart: () => h.restarts++ };
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

t.test('§3: booleans, clamped uints, defaults and the instance list', () => {
	monitor({});
	t.eq(sys.monitor_config(cur()), {
		enabled: false, manage_logging: true, record_clients: false, exclude_router: true,
		recent_size: 500, top_size: 256, pending_size: 512, pending_ttl: 10, poll_interval: 5,
		dnsmasq_instance: [ '*' ]
	});
	monitor({ enabled: 'yes', manage_logging: 'off', record_clients: '1', exclude_router: 'maybe',
	          recent_size: '9999', top_size: '1', pending_size: 'abc', pending_ttl: ' 30 ',
	          poll_interval: '-5', dnsmasq_instance: [ 'guest', 'main' ], max_events: '256' });
	t.eq(sys.monitor_config(cur()), {
		enabled: true, manage_logging: false, record_clients: true, exclude_router: true,
		recent_size: 2000, top_size: 32, pending_size: 512, pending_ttl: 30, poll_interval: 5,
		dnsmasq_instance: [ 'guest', 'main' ]
	});
	write('adblock-fast-monitor', '');
	t.eq(sys.monitor_config(cur()).enabled, false, 'missing section');
});

t.test('§5: confdir defaults, comma suffix, relative paths are invalid', () => {
	t.eq(sys.confdir_of('cfg01411c', null), '/tmp/dnsmasq.cfg01411c.d');
	t.eq(sys.confdir_of('x', '/tmp/x.d,*.conf'), '/tmp/x.d');
	t.eq(sys.confdir_of('x', '/tmp/x.d/'), '/tmp/x.d');
	t.eq(sys.confdir_of('x', 'relative/dir'), null);
	t.eq(sys.confdir_of('x', ''), null);
});

t.test('§5: sections use UCI names; targets honour disabled and dnsmasq_instance', () => {
	dhcp();
	monitor({});
	let s = sys.dnsmasq_sections(cur());
	t.eq(length(s), 3);
	t.match(s[0].section, /^cfg[0-9a-f]{6}$/, 'anonymous section name');
	t.eq([ s[0].confdir, s[1].section, s[1].confdir, s[2].disabled ],
		[ `${confdir_root}/main.d`, 'guest', '/tmp/dnsmasq.guest.d', true ]);
	t.eq(map(sys.logging_targets(cur()), (x) => x.section), [ s[0].section, 'guest' ]);
	monitor({ dnsmasq_instance: [ 'guest', 'off', 'nope' ] });
	t.eq(map(sys.logging_targets(cur()), (x) => x.section), [ 'guest' ]);
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
		t.eq(fs.readfile(p), 'log-queries=extra\n');
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
	t.eq([ h.res.changed, h.restarts, fs.readfile(MAIN) ], [ false, 0, 'log-queries=extra\n' ]);
});

t.test('§5 narrowing dnsmasq_instance removes the other drop-in (one restart)', () => {
	monitor({ dnsmasq_instance: 'guest' });
	let h = apply('enable');
	t.eq([ h.res.changed, h.restarts, h.res.dropins ], [ true, 1, [ GUEST ] ]);
	t.ok(!fs.lstat(MAIN));
});

t.test('§5 an instance with logqueries=1 gets no drop-in', () => {
	write('dhcp', replace(DHCP_BYTES, "config dnsmasq 'guest'\n", "config dnsmasq 'guest'\n\toption logqueries '1'\n"));
	let h = apply('enable');
	t.eq([ h.res.changed, h.restarts, h.res.dropins ], [ true, 1, [] ]);
	let st = sys.logging_status(cur(), null);
	t.eq(st.instances[1], { section: 'guest', confdir: `${confdir_root}/guest.d`, dropin: false, uci_logqueries: true, running: false });
	write('dhcp', DHCP_BYTES);
});

t.test('§5 changes while dnsmasq is not running never restart it (boot)', () => {
	monitor({});
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

t.test('service_state reads procd instances through ubus', () => {
	let fake = { call: (o, m, a) => (o == 'service' && m == 'list' && a.name == 'dnsmasq')
		? { dnsmasq: { instances: { cfg01411c: { running: true, pid: 5 }, guest: { running: false } } } } : null };
	t.eq(sys.service_state(fake, 'dnsmasq'), { running: true, instances: { cfg01411c: true, guest: false } });
	t.eq(sys.service_state({ call: () => null }, 'dnsmasq'), { running: false, instances: {} });
	t.eq(sys.service_state(null, 'dnsmasq'), { running: false, instances: {} });
});

rm_rf(base);
t.done();
