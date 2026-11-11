// Shared helpers for the LuCI browser suite (docs/CONTRACT.md §13 T23–T25).
// Runs on the host next to a guest started by scripts/guest/run-guest-tests.sh
// (GUEST_* exported). Guest conditions are created with real commands over SSH.
import { execFileSync } from 'node:child_process';
import dgram from 'node:dgram';
import { expect } from '@playwright/test';

export const OVERVIEW = '/cgi-bin/luci/admin/services/adblock-fast-monitor/overview';
export const SETTINGS = '/cgi-bin/luci/admin/services/adblock-fast-monitor/settings';

export const admin = {
  username: process.env.MONITOR_WRITE_LUCI_USERNAME || 'root',
  password: process.env.MONITOR_WRITE_LUCI_PASSWORD || process.env.GUEST_ROOT_PASSWORD
};
export const readonly = {
  username: process.env.MONITOR_READONLY_LUCI_USERNAME || process.env.GUEST_READONLY_USER,
  password: process.env.MONITOR_READONLY_LUCI_PASSWORD || process.env.GUEST_READONLY_PASSWORD
};

function requireGuest() {
  for (const name of ['GUEST_SSH_KEY', 'GUEST_SSH_PORT', 'GUEST_RUN_DIR', 'GUEST_DNS_PORT']) {
    if (!process.env[name]) {
      throw new Error(`Browser test prerequisite blocked: ${name} is unset; run via npm run verify:guest -- --browser PKG.apk`);
    }
  }
}

/** Runs a shell command in the guest (BusyBox ash) and returns stdout. */
export function guest(command, { input, allowFail = false } = {}) {
  requireGuest();
  try {
    return execFileSync('ssh', [
      '-i', process.env.GUEST_SSH_KEY, '-p', process.env.GUEST_SSH_PORT,
      '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', '-o', 'StrictHostKeyChecking=no',
      '-o', `UserKnownHostsFile=${process.env.GUEST_RUN_DIR}/known_hosts`, '-o', 'LogLevel=ERROR',
      'root@127.0.0.1', command
    ], { encoding: 'utf8', input, stdio: ['pipe', 'pipe', 'pipe'], timeout: 600_000 });
  } catch (error) {
    if (allowFail) return error.stdout ?? '';
    throw new Error(`guest command failed (${error.status}): ${command}\n${error.stderr ?? ''}${error.stdout ?? ''}`);
  }
}

/** Polls a guest shell condition (exit 0) once a second. */
export function guestWait(condition, seconds = 60) {
  guest(`i=0; until ${condition}; do i=$((i+1)); [ $i -lt ${seconds} ] || exit 1; sleep 1; done`);
}

/** Sends one DNS A query to the guest's dnsmasq from the host (a non-router client). */
export function dnsQuery(name, { timeout = 3000 } = {}) {
  requireGuest();
  const id = Math.floor(Math.random() * 0xffff);
  const labels = name.split('.').map((l) => Buffer.concat([Buffer.from([l.length]), Buffer.from(l, 'ascii')]));
  const header = Buffer.from([id >> 8, id & 0xff, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]);
  const packet = Buffer.concat([header, ...labels, Buffer.from([0, 0, 1, 0, 1])]);
  return new Promise((resolve) => {
    const socket = dgram.createSocket('udp4');
    const timer = setTimeout(() => { socket.close(); resolve(null); }, timeout);
    socket.on('message', (msg) => {
      if (msg.readUInt16BE(0) !== id) return;
      clearTimeout(timer);
      socket.close();
      resolve({ rcode: msg[3] & 0x0f, answers: msg.readUInt16BE(6) });
    });
    socket.send(packet, Number(process.env.GUEST_DNS_PORT), '127.0.0.1');
  });
}

export async function login(page, user, path = OVERVIEW) {
  if (!user.username || !user.password) {
    throw new Error('Browser test prerequisite blocked: provisioned LuCI credentials are required.');
  }
  await page.goto(path);
  const field = page.locator('input[name="luci_username"]');
  // The login form is a JavaScript modal; a logged-in page renders a .cbi-map.
  await page.locator('input[name="luci_username"]:visible, #view .cbi-map').first().waitFor({ timeout: 60_000 });
  if (await field.isVisible()) {
    await field.fill(user.username);
    await page.locator('input[name="luci_password"]').fill(user.password);
    await page.getByRole('button', { name: 'Log in' }).click();
    await page.locator('#view .cbi-map').first().waitFor({ timeout: 60_000 });
  }
  if (!new URL(page.url()).pathname.endsWith(path)) await page.goto(path);
  await page.locator('#view .cbi-map').first().waitFor({ timeout: 60_000 });
}

/** Route/request predicate for LuCI's ubus JSON-RPC endpoint. */
export function isUbus(url) {
  return url.pathname.startsWith('/ubus');
}

/** The ubus calls ([object, method, args]) in one JSON-RPC request. */
export function ubusCalls(request) {
  if (!isUbus(new URL(request.url()))) return [];
  let body = null;
  try { body = request.postDataJSON(); } catch { return []; }
  return (Array.isArray(body) ? body : [body])
    .filter((c) => c?.method === 'call' && Array.isArray(c.params))
    .map((c) => [c.params[1], c.params[2], c.params[3] ?? {}]);
}

/** Records every `log read` request the page sends: [{at, args}]. */
export function trackLogReads(page) {
  const reads = [];
  page.on('request', (r) => {
    for (const [object, method, args] of ubusCalls(r)) {
      if (object === 'log' && method === 'read') reads.push({ at: Date.now(), args });
    }
  });
  return reads;
}

/** Records every `log read` reply body ({log:[...]}) the page receives. */
export function trackLogReplies(page) {
  const replies = [];
  page.on('response', async (r) => {
    if (!ubusCalls(r.request()).some(([o, m]) => o === 'log' && m === 'read')) return;
    try {
      const body = await r.json();
      for (const reply of Array.isArray(body) ? body : [body]) {
        const log = reply?.result?.[1]?.log;
        if (Array.isArray(log)) replies.push(log.map((e) => e.id));
      }
    } catch { /* navigation aborted the body */ }
  });
  return replies;
}

export const queries = (page) => page.getByRole('table', { name: 'Last queries' });
export const queryRow = (page, domain) => queries(page).locator(`tr[data-domain="${domain}"]`).first();
export const pending = (page) => page.getByRole('table', { name: 'Pending changes' });
export const pendingRow = (page, domain) => pending(page).locator(`tr[data-domain="${domain}"]`);

/** Overrides document.visibilityState and fires visibilitychange, as a tab switch does. */
export async function setVisibility(page, state) {
  await page.evaluate((s) => {
    Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => s });
    Object.defineProperty(document, 'hidden', { configurable: true, get: () => s !== 'visible' });
    document.dispatchEvent(new Event('visibilitychange'));
  }, state);
}

/* ---- guest conditions -------------------------------------------------------- */

const UPSTREAM_CONF = 'abfm-browser-upstream.conf';

export function waitAdblockFast(seconds = 300) {
  guestWait(`ubus call service list '{"name":"adblock-fast"}' | grep -q '"status": "statusSuccess"'`, seconds);
}

const UPSTREAM = [
  // fake upstream: a second dnsmasq on 127.0.0.1:5300 (test-only drop-in)
  'if ! [ -s /tmp/abfm-browser-upstream.pid ] || ! kill -0 "$(cat /tmp/abfm-browser-upstream.pid)" 2>/dev/null; then',
  '  dnsmasq --conf-file=/dev/null --keep-in-foreground --port=5300 --listen-address=127.0.0.1 --bind-interfaces --resolv-file=/tmp/resolv.conf.d/resolv.conf.auto --no-hosts --local-ttl=300 --user=root --pid-file= --address=/example.test/192.0.2.10 --address=/example.test/2001:db8::10 >/dev/null 2>&1 &',
  '  echo $! >/tmp/abfm-browser-upstream.pid',
  'fi',
  'restart=0',
  `for d in /tmp/dnsmasq.*.d; do [ -s "$d/${UPSTREAM_CONF}" ] && continue; printf '%s\\n' 'server=/up.example.test/127.0.0.1#5300' 'server=127.0.0.1#5300' 'no-resolv' 'rebind-domain-ok=/example.test/' >"$d/${UPSTREAM_CONF}"; restart=1; done`,
  '[ $restart = 0 ] || /etc/init.d/dnsmasq restart'
];

/** Starts the fake upstream (idempotent) without touching adblock-fast. */
export function startUpstream() {
  guest(['set -e', ...UPSTREAM].join('\n'));
  guestWait('pidof dnsmasq >/dev/null && nslookup a.up.example.test 127.0.0.1 >/dev/null 2>&1', 60);
}

/*
 * Query logging on (the package's own drop-in), adblock-fast healthy in
 * dnsmasq.servers mode, and a fake upstream that answers *.example.test with
 * A 192.0.2.10 / AAAA 2001:db8::10, so "allowed" answers are deterministic.
 * It serves *.up.example.test and is dnsmasq's only default server, so an
 * allowed name (adblock-fast's `server=/name/#`) resolves through it too;
 * everything else it forwards to the guest's real upstream.
 */
export function ensureHealthy() {
  guest([
    'set -e',
    '[ -x /etc/init.d/adblock-fast ] || mv /root/abfm-adblock-fast.init /etc/init.d/adblock-fast',
    '[ -f /etc/config/adblock-fast ] || mv /root/abfm-adblock-fast.config /etc/config/adblock-fast',
    'uci set adblock-fast-monitor.config.query_logging=1',
    'uci commit adblock-fast-monitor',
    'changed=0',
    '[ "$(uci -q get adblock-fast.config.dns)" = dnsmasq.servers ] || { uci set adblock-fast.config.dns=dnsmasq.servers; uci commit adblock-fast; changed=1; }',
    'if [ -n "$(uci -q get dhcp.@dnsmasq[0].logfacility)" ]; then uci delete dhcp.@dnsmasq[0].logfacility; uci commit dhcp; /etc/init.d/dnsmasq restart; fi',
    'pidof dnsmasq >/dev/null || /etc/init.d/dnsmasq start',
    '[ $changed = 0 ] || /etc/init.d/adblock-fast restart >/dev/null 2>&1',
    '/etc/init.d/adblock-fast-monitor restart',
    ...UPSTREAM
  ].join('\n'));
  guestWait('pidof dnsmasq >/dev/null && grep -qs "^log-queries" /tmp/dnsmasq.*.d/* && nslookup a.up.example.test 127.0.0.1 >/dev/null 2>&1', 60);
  waitAdblockFast();
}

/** Writes lines to the system log as dnsmasq would (`dnsmasq[1]: …`). */
export function fakeDnsmasq(lines) {
  guest(`logger -t 'dnsmasq[1]'`, { input: lines.map((l) => `${l}\n`).join('') });
}

/*
 * Sends one A query for `name` from the host (10.0.2.2) and waits for its
 * row. The query is sent again only when dnsmasq never answered it (a UDP
 * packet lost on the way): an answered query is in the log, so a missing
 * row is a failure, not a reason to retry.
 */
export async function seeQuery(page, name, { decision, tries = 5 } = {}) {
  const row = decision
    ? queries(page).locator(`tr[data-domain="${name}"][data-decision="${decision}"]`).first()
    : queryRow(page, name);
  for (let i = 0; i < tries; i++) {
    if (await dnsQuery(name)) break;
    if (i === tries - 1) throw new Error(`dnsmasq never answered ${name}`);
  }
  await expect(row).toBeVisible({ timeout: 60_000 });
  return row;
}

/** Records every call of `object`.`method` the page sends: [{at, args}]. */
export function trackCalls(page, object, method) {
  const calls = [];
  page.on('request', (r) => {
    for (const [o, m, args] of ubusCalls(r)) {
      if (o === object && m === method) calls.push({ at: Date.now(), args });
    }
  });
  return calls;
}

/*
 * Holds the page's `log read` requests while `hold()` is active: they reach
 * the router only after `release()`, so their replies show the log as it is
 * then. Returns {hold, release, held}.
 */
export async function holdLogReads(page) {
  let holding = false;
  const held = [];
  await page.route((url) => isUbus(url), async (route) => {
    const isRead = ubusCalls(route.request()).some(([o, m]) => o === 'log' && m === 'read');
    if (holding && isRead) held.push(route);
    else await route.continue();
  });
  return {
    held,
    hold() { holding = true; },
    async release() {
      holding = false;
      for (const r of held.splice(0)) await r.continue();
    }
  };
}

/*
 * Validates every reply of luci.adblock-fast-monitor the page receives
 * against the api-2 schemas (lib/schemas.mjs). Returns {replies, errors}.
 */
export function checkReplies(page, validate) {
  const out = { replies: [], errors: [] };
  page.on('response', async (r) => {
    const calls = ubusCalls(r.request());
    if (!calls.some(([o]) => o === 'luci.adblock-fast-monitor')) return;
    let body;
    try { body = await r.json(); } catch { return; }
    const replies = Array.isArray(body) ? body : [body];
    const reqs = (() => { try { const b = r.request().postDataJSON(); return Array.isArray(b) ? b : [b]; } catch { return []; } })();
    for (const rep of replies) {
      const req = reqs.find((q) => q.id === rep.id);
      if (!req || req.params?.[1] !== 'luci.adblock-fast-monitor') continue;
      const method = req.params[2];
      const data = rep.result?.[1];
      if (rep.result?.[0] !== 0 || !data) { out.errors.push(`${method}: ubus status ${JSON.stringify(rep.result ?? rep.error)}`); continue; }
      out.replies.push([method, data]);
      for (const e of validate(method, data)) out.errors.push(`${method} ${JSON.stringify(data).slice(0, 300)}: ${e}`);
    }
  });
  return out;
}
