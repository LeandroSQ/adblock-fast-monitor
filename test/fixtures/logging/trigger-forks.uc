// SPDX-License-Identifier: Apache-2.0
// Guest test helper (docs/CONTRACT.md §4, T06): how many processes one
// firing of the instance.update trigger costs.
//   ucode trigger-forks.uc measure DROPIN [TIMEOUT_S]
//     Damages DROPIN, restarts an unrelated service (uhttpd), then waits in
//     this process (no forks) until the trigger's reconcile has rewritten
//     DROPIN and released the logging lock.
//   ucode trigger-forks.uc control MS
//     Restarts uhttpd the same way and counts over a window of MS (the
//     duration a `measure` took), for a guest without the trigger.
// Prints {"forks":N,"rewritten":bool,"ms":N}: processes created between the
// end of the uhttpd restart and the end of the window (/proc/stat
// `processes`); this process creates none meanwhile.
'use strict';

let fs = require('fs');
const CONTENT = 'log-queries=extra\nlog-async=25\n';
const LOCK = '/var/lock/adblock-fast-monitor.logging.lock';

function created() {
	let m = match(fs.readfile('/proc/stat') ?? '', /\nprocesses ([0-9]+)/);
	return m ? +m[1] : -1;
}
function ms() {
	let c = clock(true);
	return c[0] * 1000 + c[1] / 1000000;
}

let mode = ARGV[0];
let dropin = ARGV[1];
if (mode == 'measure')
	fs.writefile(dropin, 'garbage\n');
system('/etc/init.d/uhttpd restart >/dev/null 2>&1');
let p0 = created(), t0 = ms();
let rewritten = false;
if (mode == 'measure') {
	let deadline = time() + +(ARGV[2] ?? 60);
	while (time() < deadline) {
		if (fs.readfile(dropin) == CONTENT) {
			let f = fs.open(LOCK, 'a');
			if (f?.lock('xn')) {
				f.lock('u');
				f.close();
				rewritten = true;
				break;
			}
			f?.close();
		}
		sleep(50);
	}
}
else {
	sleep(+ARGV[1]);
}
printf('%J\n', { forks: created() - p0, rewritten, ms: int(ms() - t0) });
