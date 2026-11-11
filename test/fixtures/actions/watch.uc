// SPDX-License-Identifier: Apache-2.0
// Guest test helper: calls luci.adblock-fast-monitor apply over ubus, then
// polls job.json every 2 ms and records each distinct job state.
//   ucode watch.uc '<apply request JSON>' [timeout_s]
// Prints {"apply":…, "apply_ms":N, "states":[…], "job":…, "af_delta":[…]};
// af_delta: every distinct line seen in /tmp/.uci/adblock-fast meanwhile.
let ubus = require('ubus');
let fs = require('fs');

function ms() {
	let c = clock(true);
	return c[0] * 1000 + c[1] / 1000000;
}

let req = json(ARGV[0] ?? '{}');
let deadline = time() + +(ARGV[1] ?? 600);
let conn = ubus.connect();
let t0 = ms();
let reply = conn.call('luci.adblock-fast-monitor', 'apply', req);
let apply_ms = int(ms() - t0);
let states = [], delta = {};
if (reply?.ok && reply?.job_id) {
	push(states, reply.state);
	while (time() < deadline) {
		let j = null;
		try { j = json(fs.readfile('/var/run/adblock-fast-monitor/job.json') ?? 'null'); } catch (e) {}
		for (let l in split(fs.readfile('/tmp/.uci/adblock-fast') ?? '', '\n'))
			if (l != '') delta[l] = true;
		let s = (j?.id == reply.job_id) ? j.state : null;
		if (s && s != states[length(states) - 1])
			push(states, s);
		if (s == 'applied' || s == 'partial' || s == 'failed')
			break;
		sleep(2);
	}
}
let job = conn.call('luci.adblock-fast-monitor', 'job', {})?.job;
printf('%J\n', { apply: reply, apply_ms, states, job, af_delta: keys(delta) });
