// SPDX-License-Identifier: Apache-2.0
// One-time differential oracle for the browser query log (design B-min):
// replays a dnsmasq log through the ucode data plane that querylog.js
// replaces (abfm.logparse parse_line/classify + abfm.stats correlation and
// pending TTL) and prints, for every correlation key `pid:serial:client/port`
// of a query (router clients included), {domain, decision, source}.
// decision is blocked, allowed, other, no-answer (expired by the TTL) or
// pending.
//
//   ucode querylog-differential.uc FILE      FILE: logread text (*.log) or a
//                                            `log read` reply (*.json)
//
// Run through scripts/hosttools/querylog-differential.sh. It stops working
// once abfm.logparse / abfm.stats are deleted; its committed outputs in
// test/fixtures/logread/differential/ stay as the regression oracle.
'use strict';

push(REQUIRE_SEARCH_PATH, '/src/root/usr/share/ucode/*.uc');

const fs = require('fs');
const logparse = require('abfm.logparse');
const stats = require('abfm.stats');

const MONTHS = { Jan: 1, Feb: 2, Mar: 3, Apr: 4, May: 5, Jun: 6, Jul: 7, Aug: 8, Sep: 9, Oct: 10, Nov: 11, Dec: 12 };
const WDAYS = [ 'Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat' ];
const MONTH_NAMES = [ null, 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec' ];
const FACILITIES = [ 'kern', 'user', 'mail', 'daemon', 'auth', 'syslog', 'lpr', 'news', 'uucp', 'cron', 'authpriv', 'ftp' ];
const PRIOS = [ 'emerg', 'alert', 'crit', 'err', 'warn', 'notice', 'info', 'debug' ];
const CTIME = /^[A-Z][a-z]{2} ([A-Z][a-z]{2}) ([ 0-9][0-9]) ([0-9]{2}):([0-9]{2}):([0-9]{2}) ([0-9]{4}) /;

// logread.c L209 format of one `log read` entry (times in UTC).
function to_line(e) {
	let t = gmtime(int(e.time / 1000));
	let fac = FACILITIES[e.priority >> 3] ?? 'local0', prio = PRIOS[e.priority & 7];
	return sprintf('%s %s %2d %02d:%02d:%02d %d %s.%s %s', WDAYS[t.wday], MONTH_NAMES[t.mon], t.mday,
		t.hour, t.min, t.sec, t.year, fac, prio, e.msg);
}

function line_time(line) {
	let m = match(line, CTIME);
	return m ? timegm({ sec: +m[5], min: +m[4], hour: +m[3], mday: +trim(m[2]), mon: MONTHS[m[1]], year: +m[6] }) : null;
}

let file = ARGV[0];
let data = fs.readfile(file);
if (data == null)
	die(`cannot read ${file}\n`);

let lines;
if (match(file, /\.json$/))
	lines = map(json(data).log, to_line);
else
	lines = filter(split(data, '\n'), (l) => l != '');

let st = stats.create({}, 0);
let ctx = { exclude_router: false, local_domains: [ 'lan' ] };
let out = {};
let pending_names = {};

for (let line in lines) {
	let now = line_time(line);
	let before = { ...st.pending };
	stats.sweep(st, now);
	for (let k in before)
		if (!st.pending[k])
			out[k] = { domain: before[k].name, decision: 'no-answer', source: null };

	let ev = logparse.parse_line(line, st.counters);
	if (!ev)
		continue;
	let key = stats.event_key(ev);
	let name = st.pending[key]?.name;
	let r = stats.ingest(st, ev, ctx, now);
	if (r == 'pending')
		out[key] = { domain: ev.name, decision: 'pending', source: null };
	else if (r == 'decided')
		out[key] = { domain: name, decision: st.recent[name].decision, source: st.recent[name].source };
}

let keys_sorted = sort(keys(out));
let body = map(keys_sorted, (k) => sprintf('  %J: %J', k, out[k]));
print('{\n', join(',\n', body), '\n}\n');
