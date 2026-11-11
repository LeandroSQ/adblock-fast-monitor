#!/usr/bin/ucode
// SPDX-License-Identifier: Apache-2.0
// Query-logging drop-ins for dnsmasq (docs/CONTRACT.md §4, §5).
//   logging.uc reconcile | disable | status
// `reconcile` reads query_logging itself and writes or removes the drop-ins;
// the init script runs it on start/reload, and procd runs it directly from
// the instance.update trigger, so a trigger costs one process. Never writes
// /etc/config/dhcp. Restarts dnsmasq once, only when it is running and the
// set of drop-in files changed, or (drop-ins in place) the service's jailed
// /dev/log is stale after a logd restart (§4, §11 P10).
'use strict';

const fs = require('fs');
const uci = require('uci');
const ubus = require('ubus');
const sys = require('abfm.system');

const RUN_DIR = '/var/run/adblock-fast-monitor';
const STALE_STAMP = RUN_DIR + '/stale-restart';
const LOCK_DIR = '/var/lock';
const LOCK_FILE = LOCK_DIR + '/adblock-fast-monitor.logging.lock';

let mode = ARGV[0];
let conn = ubus.connect();
let cursor = uci.cursor();

if (mode == 'status') {
	printf('%J\n', sys.logging_status(cursor, conn));
	exit(0);
}

if (mode == 'reconcile')
	mode = sys.monitor_config(cursor).query_logging ? 'enable' : 'disable';
else if (mode != 'disable') {
	warn('usage: logging.uc reconcile|disable|status\n');
	exit(2);
}

// Serializes reconciles (init script, triggers, a manual run) so two of them
// never both see a changed set and restart dnsmasq twice. O_CLOEXEC: the
// dnsmasq restart below must not inherit it.
if (!fs.stat(LOCK_DIR))
	fs.mkdir(LOCK_DIR, 0o755);
let lock = fs.open(LOCK_FILE, 'ae', 0o600);
lock?.lock('x');

// After a logd restart /dev/log is briefly missing; wait for it (≤ 5 s) so a
// stale jail socket is not missed (logd is up long before START=18 at boot).
let stale_pids = [];
function stale() {
	for (let i = 0; i < 25 && !fs.stat('/dev/log'); i++)
		sleep(200);
	if (!fs.stat(RUN_DIR))
		fs.mkdir(RUN_DIR, 0o700);
	stale_pids = sys.dnsmasq_stale_restart('', sys.service_state(conn, 'dnsmasq').pids, STALE_STAMP);
	return length(stale_pids) > 0;
}

let res = sys.logging_apply(mode, {
	cursor,
	running: () => sys.service_state(conn, 'dnsmasq').running,
	stale,
	restart: function(reason) {
		system([ 'logger', '-t', 'adblock-fast-monitor', (reason == 'stale')
			? `dnsmasq ${join(',', stale_pids)} lost /dev/log (logd restarted); restarting dnsmasq`
			: 'query-logging drop-ins changed; restarting dnsmasq' ]);
		system([ '/etc/init.d/dnsmasq', 'restart' ]);
	}
});

for (let e in res.errors)
	warn(`adblock-fast-monitor: ${e.section ?? e.confdir}: ${e.error}\n`);

exit(length(res.errors) ? 1 : 0);
