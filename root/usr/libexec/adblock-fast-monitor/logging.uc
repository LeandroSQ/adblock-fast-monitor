#!/usr/bin/ucode
// SPDX-License-Identifier: Apache-2.0
// Query-logging drop-ins for dnsmasq (docs/CONTRACT.md §5).
//   logging.uc enable | disable | status
// Never writes /etc/config/dhcp. Restarts dnsmasq once, only when it is
// running and the set of drop-in files changed, or (enable with drop-ins in
// place) its jailed /dev/log is stale after a logd restart (§4, §11 P10).
'use strict';

const fs = require('fs');
const uci = require('uci');
const ubus = require('ubus');
const sys = require('abfm.system');

let mode = ARGV[0];
let conn = ubus.connect();

if (mode == 'status') {
	printf('%J\n', sys.logging_status(uci.cursor(), conn));
	exit(0);
}

if (mode != 'enable' && mode != 'disable') {
	warn('usage: logging.uc enable|disable|status\n');
	exit(2);
}

// After a logd restart /dev/log is briefly missing; wait for it (≤ 5 s) so a
// stale jail socket is not missed (logd is up long before START=18 at boot).
let stale_pids = [];
function stale() {
	for (let i = 0; i < 25 && !fs.stat('/dev/log'); i++)
		sleep(200);
	stale_pids = sys.dnsmasq_log_stale();
	return length(stale_pids) > 0;
}

let res = sys.logging_apply(mode, {
	cursor: uci.cursor(),
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
