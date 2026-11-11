// SPDX-License-Identifier: Apache-2.0
// Discovery helpers shared by logging.uc and the rpcd plugin: the package's
// own UCI, dnsmasq instances and their conf-dirs, and the query-logging
// drop-ins (docs/CONTRACT.md §3, §5). Functions take a uci
// cursor (and, where they act, injected callbacks) so they run unchanged
// against a temporary UCI directory in tests.
'use strict';

const fs = require('fs');

const DROPIN_NAME = 'adblock-fast-monitor.conf';
// log-async: dnsmasq queues up to 25 log lines instead of blocking the
// query path on syslog writes; a full queue is reported by dnsmasq as
// "overflow: N log entries lost" (the browser parser counts it, §8).
const DROPIN_CONTENT = 'log-queries=extra\nlog-async=25\n';

// ---------------------------------------------------------------------------
// Package configuration (§3)

const TRUE = { '1': true, 'on': true, 'true': true, 'yes': true, 'enabled': true };
const FALSE = { '0': true, 'off': true, 'false': true, 'no': true, 'disabled': true };

function parse_bool(v, def) {
	if (type(v) == 'bool')
		return v;
	if (type(v) != 'string')
		return def;
	return TRUE[v] ? true : (FALSE[v] ? false : def);
}

function as_list(v) {
	if (v == null)
		return [];
	return type(v) == 'array' ? v : split(trim(`${v}`), /[ \t]+/);
}

// Unknown options (for example ones an older build wrote) are ignored.
function monitor_config(cursor) {
	let s = cursor.get_all('adblock-fast-monitor', 'config') ?? {};
	return { query_logging: parse_bool(s.query_logging, false) };
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

// Sections that get a drop-in: every dnsmasq section with disabled!=1.
function logging_targets(cursor) {
	return filter(dnsmasq_sections(cursor), (s) => !s.disabled);
}

function dropin_path(confdir) {
	return `${confdir}/${DROPIN_NAME}`;
}

function dropin_exists(confdir) {
	return confdir != null && fs.lstat(dropin_path(confdir))?.type == 'file';
}

// dhcp `domain` values and `local` values with slashes stripped (§6.1).
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

// logd ring size in KiB as ubox log.init computes `-S`: log_buffer_size,
// else log_size, else 64 (§6.1; it bounds how many queries the page sees).
function logd_size_kib(cursor) {
	let pick = (v) => (type(v) == 'string' && match(v, /^[0-9]+$/) && +v > 0) ? +v : null;
	return pick(cursor.get_first('system', 'system', 'log_buffer_size'))
		?? pick(cursor.get_first('system', 'system', 'log_size')) ?? 64;
}

// §6.1 `logd-to-flash`: logd also writes the log to `log_file`, and that
// file is not on tmpfs (/tmp, /var -> /tmp, /dev/shm), so every logged query
// is written to flash.
function log_file_persistent(path) {
	if (type(path) != 'string' || path == '')
		return false;
	return !match(path, /^\/(tmp|var|dev\/shm)(\/|$)/);
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

// {running: bool, instances: {name: running}, pids: [pid of each running
// instance]} for a procd service.
function service_state(conn, name) {
	let res = conn?.call('service', 'list', { name });
	let inst = res?.[name]?.instances ?? {};
	let out = { running: false, instances: {}, pids: [] };
	for (let k, v in inst) {
		out.instances[k] = !!v?.running;
		if (v?.running) {
			out.running = true;
			if (type(v.pid) == 'int' && v.pid > 0)
				push(out.pids, v.pid);
		}
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

function log_socket_id(root) {
	let st = fs.stat(`${root ?? ''}/dev/log`);
	return st ? sprintf('%d:%d:%d', st.dev?.major, st.dev?.minor, st.inode) : null;
}

function ppid_of(root, pid) {
	// "pid (comm) state ppid ...": comm may hold spaces and parentheses.
	let stat = fs.readfile(`${root}/proc/${pid}/stat`) ?? '';
	let m = match(substr(stat, rindex(stat, ')') + 1), /^ [A-Za-z] ([0-9]+)/);
	return m ? +m[1] : null;
}

// pids of the procd dnsmasq service's processes whose /dev/log is not the
// current logd socket. procd jails dnsmasq (`procd_add_jail dnsmasq ubus
// log`) with /dev/log bind-mounted at start; when logd restarts it creates a
// new socket inode, the jail keeps the dead one, and dnsmasq's reconnect
// attempts never reach logd again, so it logs nothing until it restarts (§4,
// §14). Only the service's instance pids (`instances`, from `service list`)
// and their direct children (the jailed dnsmasq ujail forks) are considered:
// any other dnsmasq, for example one in its own chroot or container, is not
// ours to restart and would otherwise look stale forever. `root` is a path
// prefix for tests ('' on the router). Empty when /dev/log is missing.
function dnsmasq_log_stale(root, instances) {
	root ??= '';
	let cur = log_socket_id(root);
	if (!cur || !length(instances))
		return [];
	let want = {};
	for (let p in instances)
		want[p] = true;
	let out = [];
	for (let pid in fs.lsdir(`${root}/proc`) ?? []) {
		if (!match(pid, /^[0-9]+$/) || trim(fs.readfile(`${root}/proc/${pid}/comm`) ?? '') != 'dnsmasq')
			continue;
		if (!want[pid] && !want[ppid_of(root, pid)])
			continue;
		let st = fs.stat(`${root}/proc/${pid}/root/dev/log`);
		if (st && sprintf('%d:%d:%d', st.dev?.major, st.dev?.minor, st.inode) != cur)
			push(out, +pid);
	}
	return sort(out);
}

// Loop guard for the stale restart (§4, P10): at most one restart per logd
// socket. `stamp` records the socket a stale restart was made for; when
// dnsmasq is still stale against that same socket, another restart would not
// help, so none is made. Returns the stale pids that justify a restart (and
// records the socket), or [].
function dnsmasq_stale_restart(root, instances, stamp) {
	let stale = dnsmasq_log_stale(root, instances);
	if (!length(stale))
		return [];
	let cur = log_socket_id(root);
	if (trim(fs.readfile(stamp) ?? '') == cur)
		return [];
	fs.writefile(stamp, cur + '\n');
	return stale;
}

// mode 'enable' | 'disable'. opts: {cursor, running(): bool, restart(reason): void,
// stale(): bool (optional)}. With mode 'enable', a running dnsmasq whose
// /dev/log is stale (opts.stale) is restarted once even when the drop-in set
// is unchanged: the P10 exception of §11. reason: 'changed' | 'stale'.
// Returns {changed, restarted, stale, errors: [{section, error}], dropins: [paths]}.
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
	let stale = mode == 'enable' && length(after) > 0 && !!opts.stale?.();
	let restarted = false;
	if ((changed || stale) && opts.running()) {
		opts.restart(changed ? 'changed' : 'stale');
		restarted = true;
	}

	return { changed, restarted, stale, errors, dropins: after };
}

// ---------------------------------------------------------------------------
// adblock-fast state for the rpcd plugin (docs/CONTRACT.md §6.1, §6.5, §10).
// Reads go through the caller's cursor, which must use the plugin's private
// savedir so nobody's uncommitted changes leak into the result.

const AF_INIT = '/etc/init.d/adblock-fast';
const AF_CONFIG = '/etc/config/adblock-fast';
const AF_PENDING = '/tmp/.uci/adblock-fast';
const AF_DEFAULT_HEARTBEAT = 'heartbeat.mossdef.org';
const AF_DEFAULT_UPDATE_URL = 'https://cdn.jsdelivr.net/gh/openwrt/packages/net/adblock-fast/files/adblock-fast.config.update';

// Uncommitted changes for adblock-fast in the default uci savedir (/tmp/.uci:
// `uci set` without commit from the CLI or a script). `dl` would read them, so
// apply refuses (§6.3). LuCI's own staged changes live per session in
// /var/run/rpcd/uci-<sid> and are not seen here (§14). adblock-fast itself
// saves (without committing) file_url sizes after each download when
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

// §6.1 `dnsmasq`: logging_status() for every enabled section, plus whether
// it logs to a file.
function dnsmasq_info(cursor, conn) {
	let secs = {};
	for (let s in dnsmasq_sections(cursor))
		secs[s.section] = s;
	let instances = [], running = false;
	for (let e in logging_status(cursor, conn).instances) {
		if (e.running)
			running = true;
		let s = secs[e.section];
		if (s.disabled)
			continue;
		e.logfacility_file = index(s.logfacility ?? '', '/') >= 0;
		push(instances, e);
	}
	return { running, instances };
}

return {
	DROPIN_NAME,
	DROPIN_CONTENT,
	parse_bool,
	monitor_config,
	confdir_of,
	dnsmasq_sections,
	logging_targets,
	dropin_path,
	local_domains,
	logd_size_kib,
	log_file_persistent,
	adblock_fast_dns,
	service_state,
	logging_status,
	logging_apply,
	log_socket_id,
	dnsmasq_log_stale,
	dnsmasq_stale_restart,
	adblock_fast_pending,
	adblock_fast_state,
	adblock_fast_protected,
	dnsmasq_info
};
