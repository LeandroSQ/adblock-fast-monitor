// SPDX-License-Identifier: Apache-2.0
// Pure parsing and classification of dnsmasq `log-queries=extra` lines as
// printed by `logread -f` (docs/CONTRACT.md §4.2-4.4). No I/O, no state
// outside the framer closure.
'use strict';

const LINE_MAX = 1024;          // logd LOG_LINE_SIZE
const BUFFER_MAX = 65536;
const ADDNHOSTS = '/var/run/adblock-fast/dnsmasq.addnhosts';

const PREFIX = /^[A-Z][a-z]{2} [A-Z][a-z]{2} [ 0-9][0-9] [0-9]{2}:[0-9]{2}:[0-9]{2} [0-9]{4} [a-z0-9]+\.[a-z]+ dnsmasq\[([0-9]+)\]: (.*)$/;
const BODY = /^(TCP |UDP )?([0-9]+) ([^ \/]+)\/([0-9]+) ([^ ]+) ([a-z0-9_.:-]+) (from|is|to) ([^ ]+)( \([^()]*\))?$/;
const LOST = /^overflow: ([0-9]+) log entries lost$/;
const QUERY_LOG = /^(TCP |UDP )?[0-9]+ /;
const QUERY = /^query\[([^]]+)\]$/;
const DIGITS = /^[0-9]+$/;

// Special-use TLDs that OpenWrt answers locally (rfc6761.conf). `test` is
// deliberately absent: it carries no real traffic and the test fixtures use
// it to stand for listed ad domains.
const SPECIAL = [ 'localhost', 'local', 'invalid', 'onion', 'bind', 'arpa' ];
const ROUTER = { '127.0.0.1': true, '::1': true };
const CONFIG_BLOCK = {
	'NXDOMAIN': true, 'NODATA': true, 'NODATA-IPv4': true, 'NODATA-IPv6': true,
	'0.0.0.0': true, '::': true, '127.0.0.1': true
};
const REPLY_ERROR = { 'SERVFAIL': true, 'REFUSED': true, 'FORMERR': true };

// Returns {pid, serial, client, port, source, name, verb, answer} or null.
// A query-log line (serial first) that does not match BODY increments
// counters.rejected_lines; a LOST line adds to dropped.dnsmasq_reported.
// dnsmasq's informational lines ("started", "read /etc/hosts", ...) are
// ignored silently.
function parse_line(line, counters) {
	let m = match(line, PREFIX);
	if (!m)
		return null;

	let b = match(m[2], BODY);
	if (!b) {
		let lost = match(m[2], LOST);
		if (counters) {
			if (lost)
				counters.dropped.dnsmasq_reported += +lost[1];
			else if (match(m[2], QUERY_LOG))
				counters.rejected_lines++;
		}
		return null;
	}

	return {
		pid: +m[1],
		serial: +b[2],
		client: b[3],
		port: +b[4],
		source: b[5],
		name: b[6],
		verb: b[7],
		answer: b[8]
	};
}

function under(name, domain) {
	let n = length(name), d = length(domain);
	return n == d ? name == domain
		: (n > d && substr(name, n - d - 1) == '.' + domain);
}

// §4.4 "local": single label, an address (reverse lookups are logged as the
// address), under a special-use TLD (arpa, localhost, local, invalid, onion,
// bind), or equal to / under a dhcp `domain` or `local` value (lower-case,
// slashes already stripped).
function is_local(name, local_domains) {
	if (index(name, '.') < 0 || index(name, ':') >= 0 || match(name, /^[0-9.]+$/))
		return true;

	for (let d in SPECIAL)
		if (under(name, d))
			return true;

	for (let d in (local_domains ?? []))
		if (d != '' && under(name, d))
			return true;

	return false;
}

// ctx: {exclude_router, local_domains, qname} where local_domains is an
// array or a function returning one (called lazily, only for `config`
// lines) and qname, when set, is the name of the pending query; locality is
// judged on it because reverse lookups log the address, not the arpa name.
// Returns null (ignore), {kind:'query', qtype} or {kind:'decide', decision, source}.
function classify(ev, ctx) {
	if (ctx?.exclude_router && ROUTER[ev.client])
		return null;

	let src = ev.source, ans = ev.answer;

	if (ev.verb == 'from') {
		let q = match(src, QUERY);
		return q ? { kind: 'query', qtype: q[1] } : null;
	}

	if (ev.verb != 'is')
		return null;

	if (src == 'config') {
		let locals = ctx?.local_domains;
		if (type(locals) == 'function')
			locals = locals();
		if (is_local(ctx?.qname ?? ev.name, locals))
			return { kind: 'decide', decision: 'other', source: 'local' };
		if (CONFIG_BLOCK[ans])
			return { kind: 'decide', decision: 'blocked', source: 'config' };
		return { kind: 'decide', decision: 'other', source: 'config' };
	}

	if (src == ADDNHOSTS)
		return { kind: 'decide', decision: 'blocked', source: 'addnhosts' };

	if (substr(src, 0, 1) == '/')
		return { kind: 'decide', decision: 'other', source: 'hosts' };

	switch (src) {
	case 'DHCP':
		return { kind: 'decide', decision: 'other', source: 'dhcp' };

	case 'reply':
		if (ans == 'duplicate')
			return null;
		if (REPLY_ERROR[ans] || match(ans, DIGITS))
			return { kind: 'decide', decision: 'other', source: 'error' };
		return { kind: 'decide', decision: 'allowed', source: 'upstream' };

	case 'cached':
	case 'cached-stale':
		return { kind: 'decide', decision: 'allowed', source: 'cache' };

	case 'auth':
		return { kind: 'decide', decision: 'other', source: 'auth' };
	}

	return null;
}

// §4.2 framing. feed(chunk) returns the complete lines of at most LINE_MAX
// bytes; on_overflow() is called once per discard (over-long line, or more
// than BUFFER_MAX bytes buffered).
function framer(on_overflow) {
	let buf = '', skipping = false;

	return {
		feed: function(chunk) {
			if (skipping) {
				let nl = index(chunk, '\n');
				if (nl < 0)
					return [];
				chunk = substr(chunk, nl + 1);
				skipping = false;
			}

			buf += chunk;
			if (length(buf) > BUFFER_MAX) {
				buf = '';
				skipping = substr(chunk, -1) != '\n';
				on_overflow?.();
				return [];
			}

			let lines = split(buf, '\n');
			buf = pop(lines);

			let out = [];
			for (let l in lines) {
				if (length(l) > LINE_MAX)
					on_overflow?.();
				else
					push(out, l);
			}

			if (length(buf) > LINE_MAX) {
				buf = '';
				skipping = true;
				on_overflow?.();
			}

			return out;
		},

		buffered: function() {
			return length(buf);
		}
	};
}

return {
	LINE_MAX,
	BUFFER_MAX,
	ADDNHOSTS,
	parse_line,
	is_local,
	classify,
	framer
};
