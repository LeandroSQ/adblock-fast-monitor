// SPDX-License-Identifier: Apache-2.0
// T23 (docs/CONTRACT.md §8.5): each page state rendered from a real guest
// condition created over SSH, and restored afterwards; the query-logging
// line and its risks. `healthy` is covered in ui-queries.spec.mjs and
// turning logging off and on in ui-acl.spec.mjs.
import { expect, test } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import {
  admin, dnsQuery, ensureHealthy, fakeDnsmasq, guest, guestWait, login, queries, queryRow, readonly, seeQuery,
  stageFromRow, trackCalls, waitAdblockFast
} from './lib/guest.mjs';

test.describe.configure({ mode: 'serial' });

const state = (page) => page.locator('#abfm-state');

async function expectState(page, name, reason = '') {
  await expect(state(page)).toHaveAttribute('data-state', name, { timeout: 60_000 });
  await expect(state(page)).toHaveAttribute('data-reason', reason);
}

test.beforeAll(() => ensureHealthy());
test.afterAll(() => ensureHealthy());

test('logging-unavailable(dnsmasq-not-running): dnsmasq stopped', async ({ page }) => {
  try {
    guest('/etc/init.d/dnsmasq stop');
    // procd's view (the fake upstream is also a dnsmasq process)
    guestWait(`! ubus call service list '{"name":"dnsmasq"}' | grep -q '"running": true'`, 30);
    await login(page, admin);
    await expectState(page, 'logging-unavailable', 'dnsmasq-not-running');
    await expect(state(page)).toContainText('dnsmasq is not running.');
    await expect(state(page)).toHaveClass(/alert-message warning/);
  } finally {
    guest('/etc/init.d/dnsmasq start');
  }
  guestWait('pidof dnsmasq >/dev/null', 60);
  await page.reload();
  await expectState(page, 'healthy');
});

test('logging-unavailable(dnsmasq-logs-to-file): dhcp logfacility is a file', async ({ page }) => {
  try {
    guest('uci set dhcp.@dnsmasq[0].logfacility=/tmp/abfm-dnsmasq.log; uci commit dhcp; /etc/init.d/dnsmasq restart');
    await login(page, admin);
    await expectState(page, 'logging-unavailable', 'dnsmasq-logs-to-file');
    await expect(state(page)).toContainText('writes its log to a file');
  } finally {
    guest('uci -q delete dhcp.@dnsmasq[0].logfacility; uci commit dhcp; /etc/init.d/dnsmasq restart; rm -f /tmp/abfm-dnsmasq.log');
  }
  ensureHealthy();
  await page.reload();
  await expectState(page, 'healthy');
});

// query_logging is on but the drop-in is gone (e.g. removed by hand): nothing
// re-creates it until the init script runs again, so no instance logs.
test('logging-unavailable(logging-not-active): query logging on but no drop-in in place', async ({ page }) => {
  try {
    guest('rm -f /tmp/dnsmasq.*.d/adblock-fast-monitor.conf');
    await login(page, admin);
    await expectState(page, 'logging-unavailable', 'logging-not-active');
    await expect(state(page)).toContainText('Query logging is on, but no dnsmasq instance logs queries yet');
  } finally {
    guest('/etc/init.d/adblock-fast-monitor restart');
  }
  ensureHealthy();
  await page.reload();
  await expectState(page, 'healthy');
});

// `apk del adblock-fast` is refused while this package (which depends on it)
// is installed, so "not installed" is created on the path `info` reads
// (§6.1: /etc/init.d/adblock-fast and /etc/config/adblock-fast both exist):
// the init script is moved aside and moved back (ensureHealthy).
test('adblock-fast-missing: no actions are offered', async ({ page }) => {
  await login(page, admin);
  const row = await seeQuery(page, 'ads.example.test', { decision: 'blocked' });
  await expect(row.getByRole('button', { name: 'Allow ads.example.test' })).toBeVisible();
  try {
    guest('mv /etc/init.d/adblock-fast /root/abfm-adblock-fast.init');
    await page.reload();
    await expectState(page, 'adblock-fast-missing');
    await expect(state(page)).toContainText('adblock-fast is not installed');
    await expect(queryRow(page, 'ads.example.test')).toBeVisible({ timeout: 30_000 });
    await expect(queries(page).getByRole('button', { name: /^(Allow|Block) / })).toHaveCount(0);
    await expect(page.locator('#abfm-changes')).toBeHidden();
  } finally {
    guest('[ -x /etc/init.d/adblock-fast ] || mv /root/abfm-adblock-fast.init /etc/init.d/adblock-fast');
  }
  waitAdblockFast();
  await page.reload();
  await expectState(page, 'healthy');
  await expect(queryRow(page, 'ads.example.test').getByRole('button', { name: 'Allow ads.example.test' }))
    .toBeVisible({ timeout: 30_000 });
});

// The page's `log read` really fails: logd is stopped, so the `log` ubus
// object does not exist and the very first read is rejected.
test('error: log read rejected with no earlier data', async ({ page }) => {
  try {
    guest('/etc/init.d/log stop');
    guestWait('! ubus list log >/dev/null 2>&1', 30);
    await login(page, admin);
    await expectState(page, 'error');
    await expect(state(page)).toContainText('The system log cannot be read.');
    await expect(page.locator('#abfm-read-error')).toBeVisible();
    await expect(queries(page).locator('tr.placeholder')).toContainText('No queries seen yet.');
  } finally {
    guest('/etc/init.d/log start');
  }
  guestWait('ubus list log >/dev/null 2>&1', 30);
  ensureHealthy();
  await page.reload();
  await expectState(page, 'healthy');
});

// BE's logd-restart trigger only runs while this app's query_logging is on.
// With the user's own dhcp `logqueries` instead, a logd restart leaves the
// jailed dnsmasq writing to a dead /dev/log: the page says so.
test('log-stalled notice: logd restarted, dnsmasq silent since, recovered by a dnsmasq restart', async ({ page }) => {
  try {
    guest([
      'uci set adblock-fast-monitor.config.query_logging=0', 'uci commit adblock-fast-monitor',
      '/etc/init.d/adblock-fast-monitor restart',
      'uci set dhcp.@dnsmasq[0].logqueries=1', 'uci commit dhcp', '/etc/init.d/dnsmasq restart'
    ].join('; '));
    guestWait('! grep -qs "^log-queries" /tmp/dnsmasq.*.d/* && pidof dnsmasq >/dev/null', 60);
    await login(page, admin);
    await expectState(page, 'healthy');
    await expect(page.locator('#abfm-logging-elsewhere')).toContainText('dnsmasq\'s own settings');
    await expect(page.locator('#abfm-logging').getByRole('button')).toHaveCount(0);
    await seeQuery(page, 'before.up.example.test');
    await expect(page.locator('#abfm-log-stalled')).toHaveCount(0);

    guest('/etc/init.d/log restart');
    guestWait('ubus list log >/dev/null 2>&1', 30);
    await dnsQuery('after.up.example.test');
    const notice = page.locator('#abfm-log-stalled');
    await expect(notice).toBeVisible({ timeout: 60_000 });
    await expect(notice).toContainText('query logging may have stopped');
    await expect(notice).toContainText('/etc/init.d/dnsmasq restart');
    await expect(queries(page).locator('tr[data-domain="after.up.example.test"]')).toHaveCount(0);

    guest('/etc/init.d/dnsmasq restart');
    await expect(notice).toHaveCount(0, { timeout: 60_000 });
    await seeQuery(page, 'recovered.up.example.test');
  } finally {
    guest('uci -q delete dhcp.@dnsmasq[0].logqueries; uci commit dhcp; uci set adblock-fast-monitor.config.query_logging=1; uci commit adblock-fast-monitor; /etc/init.d/dnsmasq restart');
  }
  ensureHealthy();
});

test('the query-logging line names the risks when the system log leaves RAM (log_file, log_ip)', async ({ page }) => {
  try {
    guest('uci set system.@system[0].log_file=/root/abfm-test-syslog; uci set system.@system[0].log_ip=192.0.2.1; uci commit system');
    await login(page, admin);
    await expect(page.locator('#abfm-logging [data-warning="logd-to-flash"]')).toContainText('persistent storage');
    await expect(page.locator('#abfm-logging [data-warning="logd-remote"]')).toContainText('remote log server');
  } finally {
    guest('uci -q delete system.@system[0].log_file; uci -q delete system.@system[0].log_ip; uci commit system');
  }
  await page.reload();
  await expect(page.locator('[data-warning]')).toHaveCount(0);
});

test('info is refreshed every 30 s while visible: a stopped dnsmasq shows without a reload', async ({ page }) => {
  const infos = trackCalls(page, 'luci.adblock-fast-monitor', 'info');
  await login(page, admin);
  await expectState(page, 'healthy');
  const loaded = infos.length;
  try {
    guest('/etc/init.d/dnsmasq stop');
    guestWait(`! ubus call service list '{"name":"dnsmasq"}' | grep -q '"running": true'`, 30);
    await expect(state(page)).toHaveAttribute('data-reason', 'dnsmasq-not-running', { timeout: 40_000 });
    expect(infos.length).toBeGreaterThan(loaded);
    expect(infos.length).toBeLessThanOrEqual(loaded + 2);
  } finally {
    guest('/etc/init.d/dnsmasq start');
  }
  guestWait('pidof dnsmasq >/dev/null', 60);
  ensureHealthy();
});

// adblock-fast's mode is read from its UCI by `info`; it is changed there
// without a restart and restored by ensureHealthy.
test('ipset/nftset mode: the page explains why everything is allowed and hides % blocked', async ({ page }) => {
  try {
    guest('uci set adblock-fast.config.dns=dnsmasq.nftset; uci commit adblock-fast');
    await login(page, admin);
    await expectState(page, 'healthy');
    const note = page.locator('#abfm-dns-mode');
    await expect(note).toHaveAttribute('data-mode', 'firewall');
    await expect(note).toContainText('blocks in the firewall');
    await seeQuery(page, 'ads.example.test');
    const stat = page.locator('[data-stat="blocked_pct"]');
    await expect(stat).toContainText('Not shown: adblock-fast blocks in the firewall in this DNS mode.');
    await expect(stat.getByRole('progressbar')).toBeHidden();
  } finally {
    guest('uci set adblock-fast.config.dns=dnsmasq.servers; uci commit adblock-fast');
  }
  await page.reload();
  await expect(page.locator('#abfm-dns-mode')).toHaveCount(0);
  await expect(page.locator('[data-stat="blocked_pct"]').getByRole('progressbar')).toHaveAttribute('title', /^\d+ %$/, { timeout: 30_000 });
});

test('no Block for names the server protects (§6.5); allowing them is still offered', async ({ page }) => {
  await login(page, admin);
  const c = '192.0.2.67';
  fakeDnsmasq([
    `910001 ${c}/41001 query[A] svc.internal from ${c}`, `910001 ${c}/41001 reply svc.internal is 192.0.2.5`,
    `910002 ${c}/41002 query[A] nas.lan from ${c}`, `910002 ${c}/41002 reply nas.lan is 192.0.2.6`,
    `910003 ${c}/41003 query[A] open.example.test from ${c}`, `910003 ${c}/41003 reply open.example.test is 192.0.2.7`,
    `910004 ${c}/41004 query[A] ads.svc.internal from ${c}`, `910004 ${c}/41004 config ads.svc.internal is NXDOMAIN`
  ]);
  await expect(queryRow(page, 'open.example.test').getByRole('button', { name: 'Block open.example.test' })).toBeVisible({ timeout: 30_000 });
  for (const d of ['svc.internal', 'nas.lan']) {
    await expect(queryRow(page, d)).toHaveAttribute('data-decision', 'allowed');
    await expect(queryRow(page, d).getByRole('button')).toHaveCount(0);
  }
  await expect(queryRow(page, 'ads.svc.internal').getByRole('button', { name: 'Allow ads.svc.internal' })).toBeVisible();
});

// rpcd computes a session's grants at login: the ACL file is changed, rpcd
// reloaded, and a new login of the read-only user (root has every grant)
// gets no `info` (§9) while `log read` still works.
test('access-denied: the account may not call info', async ({ page }) => {
  const acl = '/usr/share/rpcd/acl.d/luci-app-adblock-fast-monitor.json';
  try {
    guest(`cp ${acl} /tmp/abfm-acl.bak && sed -i 's/"info", //; s/"info",//; s/, "info"//' ${acl} && ! grep -q '"info"' ${acl} && /etc/init.d/rpcd reload`);
    guestWait('ubus list luci.adblock-fast-monitor >/dev/null 2>&1', 30);
    await login(page, readonly);
    await expectState(page, 'access-denied');
    await expect(state(page)).toContainText('may not read the monitor status');
    await seeQuery(page, 'denied.up.example.test');
    await expect(queries(page).getByRole('button')).toHaveCount(0);
  } finally {
    guest(`[ ! -f /tmp/abfm-acl.bak ] || mv /tmp/abfm-acl.bak ${acl}; /etc/init.d/rpcd reload`);
  }
  guestWait('ubus list luci.adblock-fast-monitor >/dev/null 2>&1', 30);
});

test('logging-off: Turn on query logging asks first while the system log leaves RAM (log_ip)', async ({ page }) => {
  try {
    guest('uci set adblock-fast-monitor.config.query_logging=0; uci commit adblock-fast-monitor; /etc/init.d/adblock-fast-monitor restart; uci set system.@system[0].log_ip=192.0.2.1; uci commit system');
    await login(page, admin);
    await expectState(page, 'logging-off');
    await expect(state(page)).toContainText('DNS query logging is off, so no queries can be shown.');
    // nothing to show: the statistics and the list are hidden
    await expect(page.locator('#abfm-stats')).toBeHidden();
    await expect(page.locator('#abfm-queries-section')).toBeHidden();
    await state(page).getByRole('button', { name: 'Turn on query logging' }).click();
    const modal = page.locator('.modal');
    await expect(modal.locator('[data-risk="logd-remote"]')).toContainText('remote log server');
    await modal.getByRole('button', { name: 'Cancel' }).click();
    expect(guest('uci -q get adblock-fast-monitor.config.query_logging').trim()).toBe('0');
    expect(guest('uci -q changes adblock-fast-monitor').trim()).toBe('');
    await state(page).getByRole('button', { name: 'Turn on query logging' }).click();
    await modal.getByRole('button', { name: 'Turn on' }).click();
    await expect.poll(() => guest('uci -q get adblock-fast-monitor.config.query_logging').trim(), { timeout: 120_000 }).toBe('1');
    guestWait('grep -qs "^log-queries" /tmp/dnsmasq.*.d/*', 60);
  } finally {
    guest('uci -q delete system.@system[0].log_ip; uci commit system; uci set adblock-fast-monitor.config.query_logging=1; uci commit adblock-fast-monitor');
  }
  ensureHealthy();
});

// S4: axe on the app's own nodes (LuCI's theme is out of scope: color
// contrast is the theme's), in the main states.
async function axe(page, include, exclude = []) {
  let b = new AxeBuilder({ page }).include(include).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'])
    .disableRules(['color-contrast']);
  for (const e of exclude) b = b.exclude(e);
  const r = await b.analyze();
  return r.violations.map((v) => `${v.id}: ${v.nodes.map((n) => n.target.join(' ')).join(', ')}`);
}

test('accessibility: no axe violations on the page, its changes bar, its dialog and the logging-off state', async ({ page }) => {
  await login(page, admin);
  await seeQuery(page, 'ads.example.test', { decision: 'blocked' });
  expect(await axe(page, '#abfm-overview')).toEqual([]);
  // the changes bar and the confirmation dialog
  await queryRow(page, 'ads.example.test').getByRole('button', { name: 'Allow ads.example.test' }).click();
  await stageFromRow(page, 'block', 'axe.up.example.test');
  expect(await axe(page, '#abfm-overview')).toEqual([]);
  await page.getByRole('button', { name: 'Apply and save' }).click();
  await expect(page.locator('.modal')).toBeVisible();
  expect(await axe(page, '.modal')).toEqual([]);
  await page.locator('.modal').getByRole('button', { name: 'Cancel' }).click();
  await page.getByRole('button', { name: 'Discard', exact: true }).click();
  try {
    guest('uci set adblock-fast-monitor.config.query_logging=0; uci commit adblock-fast-monitor; /etc/init.d/adblock-fast-monitor restart');
    await page.reload();
    await expectState(page, 'logging-off');
    expect(await axe(page, '#abfm-overview')).toEqual([]);
  } finally {
    guest('uci set adblock-fast-monitor.config.query_logging=1; uci commit adblock-fast-monitor');
  }
  ensureHealthy();
});
