// SPDX-License-Identifier: Apache-2.0
// Discovery helpers shared by the daemon, logging.uc and the rpcd plugin:
// the monitor's own UCI, dnsmasq instances and their conf-dirs, and the
// query-logging drop-ins (docs/CONTRACT.md §3, §5). Functions take a uci
// cursor (and, where they act, injected callbacks) so they run unchanged
// against a temporary UCI directory in tests.
'use strict';

const fs = require('fs');

const DROPIN_NAME = 'adblock-fast-monitor.conf';
const DROPIN_CONTENT = 'log-queries=extra\n';
const DNS_MODES_OBSERVABLE = [ 'dnsmasq.servers', 'dnsmasq.addnhosts', 'dnsmasq.conf' ];

// ---------------------------------------------------------------------------
// Monitor configuration (§3)

const UINTS = {
	recent_size: [ 500, 50, 2000 ],
	top_size: [ 256, 32, 1024 ],
	pending_size: [ 512, 64, 4096 ],
	pending_ttl: [ 10, 2, 60 ],
	poll_interval: [ 5, 2, 60 ]
};
const BOOLS = {
	enabled: false, manage_logging: true, record_clients: false, exclude_router: true
};
const TRUE = { '1': true, 'on': true, 'true': true, 'yes': true, 'enabled': true };
const FALSE = { '0': true, 'off': true, 'false': true, 'no': true, 'disabled': true };

function parse_bool(v, def) {
	if (type(v) == 'bool')
		return v;
	if (type(v) != 'string')
		return def;
	return TRUE[v] ? true : (FALSE[v] ? false : def);
}

// Values outside the range clamp to the nearest bound; unparsable values
// fall back to the default.
function parse_uint(v, spec) {
	if (type(v) == 'int')
		return v < spec[1] ? spec[1] : (v > spec[2] ? spec[2] : v);
	if (type(v) != 'string' || !match(v, /^[ \t]*[0-9]+[ \t]*$/))
		return spec[0];
	return parse_uint(+trim(v), spec);
}

function as_list(v) {
	if (v == null)
		return [];
	return type(v) == 'array' ? v : split(trim(`${v}`), /[ \t]+/);
}

function monitor_config(cursor) {
	let s = cursor.get_all('adblock-fast-monitor', 'config') ?? {};
	let out = {};

	for (let k, def in BOOLS)
		out[k] = parse_bool(s[k], def);
	for (let k, spec in UINTS)
		out[k] = parse_uint(s[k], spec);

	let inst = filter(as_list(s.dnsmasq_instance), (n) => n != '');
	out.dnsmasq_instance = length(inst) ? inst : [ '*' ];
	return out;
}

// ---------------------------------------------------------------------------
// dnsmasq instances (§5)

function confdir_of(section, value) {
	let dir = value ?? `/tmp/dnsmasq.${section}.d`;
	if (type(dir) == 'array')
		dir = dir[0];
	dir = split(`${dir}`, ',')[0];
	if (substr(dir, 0, 1) != '/')
		return null;
	while (length(dir) > 1 && substr(dir, -1) == '/')
		dir = substr(dir, 0, -1);
	return dir;
}

// [{section, disabled, confdir|null, uci_logqueries, logfacility}] in UCI order.
function dnsmasq_sections(cursor) {
	let out = [];
	cursor.foreach('dhcp', 'dnsmasq', (s) => {
		push(out, {
			section: s['.name'],
			disabled: parse_bool(s.disabled, false),
			confdir: confdir_of(s['.name'], s.confdir),
			uci_logqueries: parse_bool(s.logqueries, false),
			logfacility: s.logfacility ?? null
		});
	});
	return out;
}

// Sections that get a drop-in under the monitor's dnsmasq_instance filter.
function logging_targets(cursor, cfg) {
	cfg ??= monitor_config(cursor);
	let all = index(cfg.dnsmasq_instance, '*') >= 0;
	return filter(dnsmasq_sections(cursor),
		(s) => !s.disabled && (all || index(cfg.dnsmasq_instance, s.section) >= 0));
}

function dropin_path(confdir) {
	return `${confdir}/${DROPIN_NAME}`;
}

function dropin_exists(confdir) {
	return confdir != null && fs.lstat(dropin_path(confdir))?.type == 'file';
}

// dhcp `domain` values and `local` values with slashes stripped (§4.4).
function local_domains(cursor) {
	let out = [];
	let add = (v) => {
		for (let d in as_list(v)) {
			d = lc(trim(replace(d, /\//g, '')));
			if (d != '' && index(out, d) < 0)
				push(out, d);
		}
	};
	cursor.foreach('dhcp', 'dnsmasq', (s) => { add(s.domain); add(s.local); });
	return out;
}

// adblock-fast's `dns` mode, or null when adblock-fast has no config.
function adblock_fast_dns(cursor) {
	let s = cursor.get_all('adblock-fast', 'config');
	if (!s)
		return null;
	return s.dns ?? 'dnsmasq.servers';
}

// ---------------------------------------------------------------------------
// procd service state

// {running: bool, instances: {name: running}} for a procd service.
function service_state(conn, name) {
	let res = conn?.call('service', 'list', { name });
	let inst = res?.[name]?.instances ?? {};
	let out = { running: false, instances: {} };
	for (let k, v in inst) {
		out.instances[k] = !!v?.running;
		if (v?.running)
			out.running = true;
	}
	return out;
}

// §5 `status`: one entry per dnsmasq section. An invalid confdir is
// reported with confdir null and reason "confdir-invalid".
function logging_status(cursor, conn) {
	let svc = service_state(conn, 'dnsmasq');
	let out = [];
	for (let s in dnsmasq_sections(cursor)) {
		let e = {
			section: s.section,
			confdir: s.confdir,
			dropin: dropin_exists(s.confdir),
			uci_logqueries: s.uci_logqueries,
			running: !!svc.instances[s.section]
		};
		if (s.confdir == null)
			e.reason = 'confdir-invalid';
		push(out, e);
	}
	return { instances: out };
}

// ---------------------------------------------------------------------------
// Drop-in management (§5)

function mkdir_p(dir) {
	if (fs.stat(dir)?.type == 'directory')
		return true;
	let parent = replace(dir, /\/[^\/]+$/, '');
	if (parent != '' && parent != dir && !mkdir_p(parent))
		return false;
	return !!fs.mkdir(dir, 0o755) || fs.stat(dir)?.type == 'directory';
}

function write_dropin(confdir) {
	let path = dropin_path(confdir);
	let cur = fs.readfile(path);
	if (cur == DROPIN_CONTENT && fs.lstat(path)?.type == 'file')
		return true;

	if (!mkdir_p(confdir))
		return false;

	let tmp = `${confdir}/.${DROPIN_NAME}.tmp`;
	let f = fs.open(tmp, 'w', 0o644);
	if (!f)
		return false;
	let ok = f.write(DROPIN_CONTENT) == length(DROPIN_CONTENT);
	f.close();
	ok = ok && fs.chmod(tmp, 0o644) && fs.rename(tmp, path);
	if (!ok)
		fs.unlink(tmp);
	return ok;
}

function remove_dropin(confdir) {
	let path = dropin_path(confdir);
	if (fs.lstat(path) && !fs.unlink(path))
		return false;
	return true;
}

// mode 'enable' | 'disable'. opts: {cursor, running(): bool, restart(): void}.
// Returns {changed, restarted, errors: [{section, error}], dropins: [paths]}.
function logging_apply(mode, opts) {
	let cursor = opts.cursor;
	let sections = dnsmasq_sections(cursor);
	let want = {};
	let errors = [];

	if (mode == 'enable') {
		for (let s in logging_targets(cursor)) {
			if (s.confdir == null)
				push(errors, { section: s.section, error: 'confdir-invalid' });
			else if (!s.uci_logqueries)
				want[s.confdir] = true;
		}
	}
	else if (mode != 'disable') {
		die(`unknown mode ${mode}`);
	}

	let before = [], after = [];
	let dirs = {};
	for (let s in sections)
		if (s.confdir != null)
			dirs[s.confdir] = true;
	for (let d in want)
		dirs[d] = true;

	for (let d in dirs) {
		if (dropin_exists(d))
			push(before, dropin_path(d));
		if (want[d]) {
			if (!write_dropin(d))
				push(errors, { confdir: d, error: 'write-failed' });
		}
		else if (!remove_dropin(d)) {
			push(errors, { confdir: d, error: 'remove-failed' });
		}
		if (dropin_exists(d))
			push(after, dropin_path(d));
	}

	let changed = join('\n', sort(before)) != join('\n', sort(after));
	let restarted = false;
	if (changed && opts.running()) {
		opts.restart();
		restarted = true;
	}

	return { changed, restarted, errors, dropins: after };
}

// --- adblock-fast discovery (WU2) ---
// adblock-fast state for the rpcd plugin (docs/CONTRACT.md §6.1, §6.5, §10).
// Reads go through the caller's cursor, which must use the plugin's private
// savedir so LuCI's unsaved changes never leak into the result.

const AF_INIT = '/etc/init.d/adblock-fast';
const AF_CONFIG = '/etc/config/adblock-fast';
const AF_PENDING = '/tmp/.uci/adblock-fast';
const AF_DEFAULT_HEARTBEAT = 'heartbeat.mossdef.org';
const AF_DEFAULT_UPDATE_URL = 'https://cdn.jsdelivr.net/gh/openwrt/packages/net/adblock-fast/files/adblock-fast.config.update';

// Unsaved LuCI changes for adblock-fast in a uci delta file. adblock-fast
// itself saves (without committing) file_url sizes after each download when
// update_config_sizes=1; that bookkeeping is not a user change.
function adblock_fast_pending(path) {
	for (let l in split(fs.readfile(path ?? AF_PENDING) ?? '', '\n'))
		if (l != '' && !match(l, /^adblock-fast\.[^.]+\.size='[0-9]*'$/))
			return true;
	return false;
}

function adblock_fast_state(cursor, conn) {
	const dom = require('abfm.domain');
	let cfg = cursor.get_all('adblock-fast', 'config') ?? {};
	let dns = adblock_fast_dns(cursor) ?? 'dnsmasq.servers';
	let output_file = dom.DNSMASQ_MODES[dns] ?? null;
	let data = conn?.call('service', 'list', { name: 'adblock-fast' })?.['adblock-fast']?.data;
	let hb = cfg.heartbeat_domain;
	return {
		installed: !!(fs.access(AF_INIT) && fs.access(AF_CONFIG)),
		enabled: parse_bool(cfg.enabled, false),
		status: data?.status || null,
		dns,
		output_file,
		output_exists: !!(output_file && fs.access(output_file)),
		external_config: !!(cfg.dnsmasq_config_file_url ?? ''),
		pending_uci_changes: adblock_fast_pending(),
		allowed: filter(as_list(cfg.allowed_domain), (d) => d != ''),
		blocked: filter(as_list(cfg.blocked_domain), (d) => d != ''),
		// adblock-fast maps '-' (and unset) to its default heartbeat (§10).
		heartbeat_domain: (hb && hb != '-') ? hb : AF_DEFAULT_HEARTBEAT,
		config_update_url: cfg.config_update_url || AF_DEFAULT_UPDATE_URL,
	};
}

// §6.5 inputs: names protected equal-or-under, and list hosts protected exactly.
function adblock_fast_protected(cursor, af) {
	const dom = require('abfm.domain');
	let names = [ af.heartbeat_domain, ...local_domains(cursor),
		cursor.get_first('system', 'system', 'hostname') ];
	let hosts = [ dom.url_host(af.config_update_url) ];
	cursor.foreach('adblock-fast', 'file_url', (s) => {
		if (parse_bool(s.enabled, true))
			push(hosts, dom.url_host(s.url));
	});
	return { names, hosts };
}

// pid of the first running instance of a procd service, or null.
function service_pid(conn, name) {
	for (let k, v in conn?.call('service', 'list', { name })?.[name]?.instances ?? {})
		if (v?.running)
			return v.pid ?? null;
	return null;
}

// §6.1 `dnsmasq`: logging_status() for every enabled section, plus whether
// it logs to a file and whether dnsmasq_instance targets it.
function dnsmasq_info(cursor, conn) {
	let secs = {};
	for (let s in dnsmasq_sections(cursor))
		secs[s.section] = s;
	let targeted = map(logging_targets(cursor), (s) => s.section);
	let instances = [], running = false;
	for (let e in logging_status(cursor, conn).instances) {
		if (e.running)
			running = true;
		let s = secs[e.section];
		if (s.disabled)
			continue;
		e.logfacility_file = index(s.logfacility ?? '', '/') >= 0;
		e.targeted = index(targeted, e.section) >= 0;
		push(instances, e);
	}
	return { running, instances };
}

return {
	DROPIN_NAME,
	DROPIN_CONTENT,
	DNS_MODES_OBSERVABLE,
	parse_bool,
	parse_uint,
	monitor_config,
	confdir_of,
	dnsmasq_sections,
	logging_targets,
	dropin_path,
	local_domains,
	adblock_fast_dns,
	service_state,
	logging_status,
	logging_apply,
	adblock_fast_pending,
	adblock_fast_state,
	adblock_fast_protected,
	service_pid,
	dnsmasq_info
};
