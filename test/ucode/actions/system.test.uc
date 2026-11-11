// SPDX-License-Identifier: Apache-2.0
// abfm.system adblock-fast discovery (docs/CONTRACT.md §6.1, §6.5, §10)
// against a temporary UCI directory and real files.
'use strict';

push(REQUIRE_SEARCH_PATH, '/src/root/usr/share/ucode/*.uc');

const fs = require('fs');
const cursor = require('uci').cursor;
const sys = require('abfm.system');
let t = require('testlib');

let base = `/tmp/abfm-af-system-test.${fs.readlink('/proc/self')}`;
fs.mkdir(base);
fs.mkdir(`${base}/config`);
fs.mkdir(`${base}/save`);
function write(name, text) { fs.writefile(`${base}/config/${name}`, text); }
function cur() { return cursor(`${base}/config`, `${base}/save`); }

write('dhcp', `
config dnsmasq
	option domain 'lan'
	option local '/lan/'
	option logfacility '/tmp/dnsmasq.log'

config dnsmasq 'guest'
	option domain 'guest.example'
	option confdir 'relative/dir'

config dnsmasq 'off'
	option disabled '1'
	option domain 'off.example'
`);
write('system', `
config system
	option hostname 'MyRouter'
`);
write('adblock-fast', `
config adblock-fast 'config'
	option enabled '1'
	option dns 'dnsmasq.addnhosts'
	list allowed_domain 'cdn.jsdelivr.net'
	list blocked_domain 'ads.example.com'
	list blocked_domain 'x.example.com'
	option heartbeat_domain '-'

config file_url
	option url 'https://Lists.Example.org/a.txt'
	option enabled '1'

config file_url
	option url 'https://disabled.example.org/b.txt'
	option enabled '0'

config file_url
	option url 'http://10.0.2.2:8080/c.txt'
`);

t.test('adblock_fast_state reads committed UCI with adblock-fast defaults', () => {
	let af = sys.adblock_fast_state(cur(), null);
	t.eq([ af.enabled, af.dns, af.output_file, af.status ],
		[ true, 'dnsmasq.addnhosts', '/var/run/adblock-fast/dnsmasq.addnhosts', null ]);
	t.eq(af.allowed, [ 'cdn.jsdelivr.net' ]);
	t.eq(af.blocked, [ 'ads.example.com', 'x.example.com' ]);
	t.eq(af.heartbeat_domain, 'heartbeat.mossdef.org', "'-' falls back to the default (§10)");
	t.match(af.config_update_url, /^https:\/\/cdn\.jsdelivr\.net\//);
	t.eq(af.external_config, false);
});

t.test('adblock_fast_state: missing config -> dnsmasq.servers, disabled, empty lists', () => {
	let c = cursor(`${base}/none`, `${base}/save`);
	let af = sys.adblock_fast_state(c, null);
	t.eq([ af.enabled, af.dns, af.allowed, af.blocked ], [ false, 'dnsmasq.servers', [], [] ]);
});

t.test('adblock_fast_protected: heartbeat, dhcp domain/local, hostname; enabled list hosts', () => {
	let c = cur();
	let p = sys.adblock_fast_protected(c, sys.adblock_fast_state(c, null));
	for (let n in [ 'heartbeat.mossdef.org', 'lan', 'guest.example', 'off.example', 'MyRouter' ])
		t.ok(index(p.names, n) >= 0, n);
	t.ok(index(p.hosts, 'lists.example.org') >= 0, 'enabled file_url host');
	t.ok(index(p.hosts, '10.0.2.2') >= 0, 'file_url without enabled is enabled');
	t.ok(index(p.hosts, 'disabled.example.org') < 0, 'disabled file_url host');
	t.ok(index(p.hosts, 'cdn.jsdelivr.net') >= 0, 'config_update_url host');
});

t.test('adblock_fast_pending ignores adblock-fast size bookkeeping only', () => {
	let f = `${base}/delta`;
	t.ok(!sys.adblock_fast_pending(`${base}/missing`), 'no delta file');
	fs.writefile(f, '');
	t.ok(!sys.adblock_fast_pending(f), 'empty delta file');
	fs.writefile(f, "adblock-fast.cfg0a1b2c.size='180'\nadblock-fast.fixture.size='3476485'\n");
	t.ok(!sys.adblock_fast_pending(f), 'size deltas only');
	fs.writefile(f, "adblock-fast.fixture.size='180'\nadblock-fast.config.dns='dnsmasq.conf'\n");
	t.ok(sys.adblock_fast_pending(f), 'a user change');
	fs.writefile(f, "+adblock-fast.config.allowed_domain='x.example.com'\n");
	t.ok(sys.adblock_fast_pending(f), 'a list add');
});

t.test('dnsmasq_info: enabled sections with logfacility_file, confdir-invalid', () => {
	let info = sys.dnsmasq_info(cur(), null);
	t.eq(info.running, false);
	t.eq(length(info.instances), 2, 'disabled section left out');
	let main = info.instances[0], guest = info.instances[1];
	t.eq(sort(keys(main)), [ 'confdir', 'dropin', 'logfacility_file', 'running', 'section', 'uci_logqueries' ]);
	t.eq([ main.logfacility_file, main.dropin, main.uci_logqueries ], [ true, false, false ]);
	t.eq([ guest.section, guest.confdir, guest.reason, guest.logfacility_file ],
		[ 'guest', null, 'confdir-invalid', false ]);
});

t.test('logd_size_kib: log_buffer_size, else log_size, else 64 (ubox log.init)', () => {
	t.eq(sys.logd_size_kib(cur()), 64, 'neither set');
	write('system', "config system\n\toption log_size '128'\n");
	t.eq(sys.logd_size_kib(cur()), 128);
	write('system', "config system\n\toption log_size '128'\n\toption log_buffer_size '256'\n");
	t.eq(sys.logd_size_kib(cur()), 256);
	write('system', "config system\n\toption log_size 'big'\n\toption log_buffer_size '0'\n");
	t.eq(sys.logd_size_kib(cur()), 64, 'unparsable and zero are ignored');
	write('system', "config system\n\toption hostname 'MyRouter'\n");
});

system(`rm -rf ${base}`);
t.done();
