// Shared helpers for the LuCI browser suite (docs/CONTRACT.md §13 T23–T25).
// Runs on the host next to a guest started by scripts/guest/run-guest-tests.sh
// (GUEST_* exported). Guest conditions are created with real commands over SSH.
import { execFileSync } from 'node:child_process';
import dgram from 'node:dgram';
import { expect } from '@playwright/test';

export const OVERVIEW = '/cgi-bin/luci/admin/services/adblock-fast-monitor/overview';
export const SETTINGS = '/cgi-bin/luci/admin/services/adblock-fast-monitor/settings';
export const POLL = 2;

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

export function banner(page) {
  return page.locator('#abfm-health');
}

export async function expectState(page, state, { timeout = 60_000 } = {}) {
  await expect(banner(page)).toHaveAttribute('data-state', state, { timeout });
}

/* ---- guest conditions -------------------------------------------------------- */

export function waitAdblockFast(seconds = 300) {
  guestWait(`ubus call service list '{"name":"adblock-fast"}' | grep -q '"status": "statusSuccess"'`, seconds);
}

/** Enabled monitor, logging active, adblock-fast healthy in dnsmasq.servers mode. */
export function ensureHealthy() {
  guest([
    'set -e',
    '[ -x /etc/init.d/adblock-fast ] || mv /root/abfm-adblock-fast.init /etc/init.d/adblock-fast',
    '[ -f /etc/config/adblock-fast ] || mv /root/abfm-adblock-fast.config /etc/config/adblock-fast',
    'uci set adblock-fast-monitor.config.enabled=1',
    `uci set adblock-fast-monitor.config.poll_interval=${POLL}`,
    'uci set adblock-fast-monitor.config.manage_logging=1',
    'uci commit adblock-fast-monitor',
    'changed=0',
    '[ "$(uci -q get adblock-fast.config.dns)" = dnsmasq.servers ] || { uci set adblock-fast.config.dns=dnsmasq.servers; uci commit adblock-fast; changed=1; }',
    'if [ -n "$(uci -q get dhcp.@dnsmasq[0].logfacility)" ]; then uci delete dhcp.@dnsmasq[0].logfacility; uci commit dhcp; /etc/init.d/dnsmasq restart; fi',
    'pidof dnsmasq >/dev/null || /etc/init.d/dnsmasq start',
    '[ $changed = 0 ] || /etc/init.d/adblock-fast restart >/dev/null 2>&1',
    '/etc/init.d/adblock-fast-monitor start'
  ].join('\n'));
  guestWait('ubus list adblock-fast-monitor >/dev/null 2>&1 && pidof dnsmasq >/dev/null', 60);
  waitAdblockFast();
}

/** Sends queries until the monitor has recorded `name` (the real logread path). */
export async function seeDomain(page, name, tries = 20) {
  for (let i = 0; i < tries; i++) {
    await dnsQuery(name);
    const out = guest(`ubus call adblock-fast-monitor domains '{"q":"${name}"}' 2>/dev/null || :`, { allowFail: true });
    if (out.includes(`"${name}"`)) return;
    await page.waitForTimeout(1000);
  }
  throw new Error(`monitor never recorded ${name}`);
}
