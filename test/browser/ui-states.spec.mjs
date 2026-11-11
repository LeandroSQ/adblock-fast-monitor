// T23 (docs/CONTRACT.md §8.5): each dashboard state rendered from a real
// guest condition created over SSH, and restored afterwards. `healthy`,
// `logging-off` and the query-logging-active note are covered in
// ui-queries.spec.mjs and ui-acl.spec.mjs.
import { expect, test } from '@playwright/test';
import {
  admin, dnsQuery, ensureHealthy, guest, guestWait, login, queries, queryRow, seeQuery, waitAdblockFast
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
    await expect(state(page).getByRole('link', { name: 'Open settings' })).toBeVisible();
  } finally {
    guest('/etc/init.d/dnsmasq start');
  }
  guestWait('pidof dnsmasq >/dev/null', 60);
  await page.reload();
  await expectState(page, 'healthy');
});

test('logging-unavailable(dnsmasq-logs-to-file): dhcp logfacility is a file', async ({ page }) => {
  try {
    guest("uci set dhcp.@dnsmasq[0].logfacility=/tmp/abfm-dnsmasq.log; uci commit dhcp; /etc/init.d/dnsmasq restart");
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

test('logging-unavailable(logging-not-active): query logging on but no instance targeted', async ({ page }) => {
  try {
    guest([
      'uci -q delete adblock-fast-monitor.config.dnsmasq_instance',
      'uci add_list adblock-fast-monitor.config.dnsmasq_instance=abfm_no_such_instance',
      'uci commit adblock-fast-monitor',
      '/etc/init.d/adblock-fast-monitor restart || :'
    ].join('; '));
    guestWait('! grep -qs "^log-queries" /tmp/dnsmasq.*.d/*', 60);
    await login(page, admin);
    await expectState(page, 'logging-unavailable', 'logging-not-active');
    await expect(state(page)).toContainText('No dnsmasq instance logs queries yet');
  } finally {
    guest([
      'uci -q delete adblock-fast-monitor.config.dnsmasq_instance',
      "uci add_list adblock-fast-monitor.config.dnsmasq_instance='*'",
      'uci commit adblock-fast-monitor',
      '/etc/init.d/adblock-fast-monitor restart'
    ].join('; '));
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
    await expect(page.getByRole('button', { name: 'Add to pending' })).toBeDisabled();
    await expect(page.getByRole('button', { name: 'Apply changes' })).toBeDisabled();
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
    await expect(state(page)).toContainText('"Log queries" option is on');
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

test('warnings from info are shown and dismissible (log_file, log_ip)', async ({ page }) => {
  try {
    guest("uci set system.@system[0].log_file=/tmp/abfm-test-syslog; uci set system.@system[0].log_ip=192.0.2.1; uci commit system");
    await login(page, admin);
    for (const w of ['logd-to-flash', 'logd-remote']) {
      const note = page.locator(`[data-warning="${w}"]`);
      await expect(note).toBeVisible();
      await note.getByRole('button', { name: 'Dismiss note' }).click();
      await expect(note).toHaveCount(0);
    }
  } finally {
    guest('uci -q delete system.@system[0].log_file; uci -q delete system.@system[0].log_ip; uci commit system');
  }
  await page.reload();
  await expect(page.locator('[data-warning="logd-to-flash"], [data-warning="logd-remote"]')).toHaveCount(0);
});
