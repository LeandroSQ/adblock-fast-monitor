#!/usr/bin/ucode
// Harness self-test stand-in (ABFM_PERF_SELFTEST=1 only; never shipped).
// Exercises the daemon-side measurements (P2-P6) with a process shaped like
// the contract's daemon: a `logread -f -e ^dnsmasq\[` child, the §4.3
// regexes on every line, a bounded recent table of recent_size rows. It
// blocks in read(2) with no timer. It is NOT the monitor and publishes no
// ubus object, so P7-P10 stay unmeasured in a self-test run.
import * as fs from 'fs';

const PREFIX = /^[A-Z][a-z]{2} [A-Z][a-z]{2} [ 0-9][0-9] [0-9]{2}:[0-9]{2}:[0-9]{2} [0-9]{4} [a-z0-9]+\.[a-z]+ dnsmasq\[([0-9]+)\]: (.*)$/;
const BODY = /^(TCP |UDP )?([0-9]+) ([^ \/]+)\/([0-9]+) ([^ ]+) ([a-z0-9_.-]+) (from|is|to) ([^ ]+)( \([^()]*\))?$/;

let cap = +(trim(fs.popen('uci -q get adblock-fast-monitor.config.recent_size')?.read('all') ?? '') || 500);
cap = max(50, min(2000, cap));
let rows = {}, order = [], live = 0, pending = {}, npending = 0;

let lr = fs.popen("exec /sbin/logread -f -e '^dnsmasq\\['", 'r');
for (let line = lr.read('line'); line != null; line = lr.read('line')) {
	let m = match(rtrim(line, '\n'), PREFIX);
	if (!m) continue;
	let b = match(m[2], BODY);
	if (!b) continue;
	let key = m[1] + ':' + b[2];
	if (b[7] == 'from') {
		if (npending >= 512) { pending = {}; npending = 0; }
		pending[key] = { name: b[6], qtype: b[5], t: time() };
		npending++;
		continue;
	}
	let p = pending[key];
	if (b[7] != 'is' || !p) continue;
	delete pending[key];
	npending--;
	let decision = (b[5] == 'config' || substr(b[5], 0, 1) == '/') ? 'blocked' : 'allowed';
	let r = rows[p.name];
	if (!r) {
		r = rows[p.name] = { domain: p.name, decision, source: b[5], count: 0, blocked: 0, allowed: 0,
			first_seen: time(), last_seen: 0, qtypes: [] };
		push(order, p.name);
		if (++live > cap) {
			while (length(order) && live > cap) {
				let old = shift(order);
				if (rows[old]) { delete rows[old]; live--; }
			}
		}
	}
	r.count++;
	r[decision]++;
	r.decision = decision;
	r.last_seen = time();
	if (index(r.qtypes, p.qtype) < 0 && length(r.qtypes) < 8) push(r.qtypes, p.qtype);
}
exit(1);
