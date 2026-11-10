#!/usr/bin/ucode
// SPDX-License-Identifier: Apache-2.0
// Query-logging drop-ins for dnsmasq (docs/CONTRACT.md §5).
//   logging.uc enable | disable | status
// Never writes /etc/config/dhcp. Restarts dnsmasq once, only when the set of
// drop-in files changed and dnsmasq is running.
'use strict';

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

let res = sys.logging_apply(mode, {
	cursor: uci.cursor(),
	running: () => sys.service_state(conn, 'dnsmasq').running,
	restart: function() {
		system([ 'logger', '-t', 'adblock-fast-monitor', 'query-logging drop-ins changed; restarting dnsmasq' ]);
		system([ '/etc/init.d/dnsmasq', 'restart' ]);
	}
});

for (let e in res.errors)
	warn(`adblock-fast-monitor: ${e.section ?? e.confdir}: ${e.error}\n`);

exit(length(res.errors) ? 1 : 0);
