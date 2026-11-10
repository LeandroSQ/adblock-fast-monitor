// T22 (§2 install) through LuCI only. Driven by
// test/guest/package-luci-install.host.sh, which builds and serves a feed
// signed with a throwaway key; skipped in ordinary browser runs.
//
// Env: MONITOR_BASE_URL, MONITOR_WRITE_LUCI_USERNAME/PASSWORD (root),
// GUEST_READONLY_USER/PASSWORD, GUEST_SSH_KEY/PORT, GUEST_RUN_DIR,
// ABFM_KEY_URL (browser-reachable), ABFM_KEY_FILE, ABFM_FEED_URL
// (guest-reachable), ABFM_SIGNED_APK, ABFM_UNSIGNED_APK.
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { test, expect } from '@playwright/test';

const env = process.env;
const PKG = 'luci-app-adblock-fast-monitor';
const KEY_PATH = '/etc/apk/keys/adblock-fast-monitor.pem';

test.skip(env.ABFM_INSTALL_TEST !== '1', 'run by test/guest/package-luci-install.host.sh (ABFM_INSTALL_TEST=1)');
test.describe.configure({ mode: 'serial' });
test.setTimeout(20 * 60 * 1000);
test.use({ actionTimeout: 60_000 });

function guest(command, { check = true } = {}) {
  try {
    return execFileSync('ssh', ['-i', env.GUEST_SSH_KEY, '-p', env.GUEST_SSH_PORT, '-o', 'BatchMode=yes',
      '-o', 'StrictHostKeyChecking=no', '-o', `UserKnownHostsFile=${env.GUEST_RUN_DIR}/known_hosts`,
      '-o', 'LogLevel=ERROR', 'root@127.0.0.1', command], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  } catch (err) {
    if (check) throw new Error(`guest command failed: ${command}\n${err.stdout}${err.stderr}`);
    return null;
  }
}
const guestOk = (command) => guest(command, { check: false }) !== null;
const sha256 = (data) => createHash('sha256').update(data).digest('hex');
const rpcdId = () => guest('ubus -v list session').match(/@([0-9a-f]+)/)[1];

async function rpc(sid, object, method, args = {}) {
  const res = await fetch(`${env.MONITOR_BASE_URL}/ubus`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'call', params: [sid, object, method, args] })
  });
  return res.json();
}
async function login(user, password) {
  const r = await rpc('00000000000000000000000000000000', 'session', 'login', { username: user, password });
  return r.result?.[1]?.ubus_rpc_session;
}

async function luciLogin(page) {
  await page.goto('/cgi-bin/luci/');
  await page.locator('input[name="luci_username"]').fill(env.MONITOR_WRITE_LUCI_USERNAME);
  await page.locator('input[name="luci_password"]').fill(env.MONITOR_WRITE_LUCI_PASSWORD);
  await page.getByRole('button', { name: 'Log in' }).click();
  await expect(page.locator('#maincontent')).toBeVisible();
}

async function openSoftware(page) {
  await page.goto('/cgi-bin/luci/admin/system/package-manager');
  // Buttons stay disabled for read-only views and the list loads asynchronously.
  await expect(page.getByRole('button', { name: 'Upload Package…' })).toBeEnabled({ timeout: 120_000 });
  await expect(page.locator('#packages .tr').first()).toBeVisible({ timeout: 120_000 });
}

// Waits for the "Executing package manager" dialog, returns its text, dismisses it.
async function finishPackageManager(page) {
  const modal = page.locator('.modal');
  const dismiss = modal.getByText('Dismiss', { exact: true });
  await expect(dismiss).toBeVisible({ timeout: 10 * 60 * 1000 });
  const text = await modal.innerText();
  await dismiss.click();
  await expect(modal).toBeHidden();
  return text;
}

async function uploadAndInstall(page, file) {
  await openSoftware(page);
  await page.getByRole('button', { name: 'Upload Package…' }).click();
  const modal = page.locator('.modal');
  await modal.locator('input[type="file"]').setInputFiles(file);
  await modal.getByRole('button', { name: 'Upload', exact: true }).click();
  await expect(modal.getByText('Manually install package')).toBeVisible({ timeout: 120_000 });
  await modal.getByText('Install', { exact: true }).click();
  return finishPackageManager(page);
}

const packageFiles = () => guest(`apk info -qL ${PKG}`).split('\n').filter((l) => l && !l.endsWith(' contains:')).map((l) => `/${l}`);

test('LuCI: unsigned upload refused, key by URL, signed upload, remove, feed install', async ({ page }) => {
  await luciLogin(page);

  await test.step('an unsigned package is refused by "Upload Package…" (no --allow-untrusted in LuCI)', async () => {
    const out = await uploadAndInstall(page, env.ABFM_UNSIGNED_APK);
    expect(out).toMatch(/UNTRUSTED/);
    expect(out).toMatch(/failed with code/);
    expect(guestOk(`apk info -e ${PKG}`)).toBe(false);
  });

  await test.step('the signed package is refused while its key is not trusted', async () => {
    const out = await uploadAndInstall(page, env.ABFM_SIGNED_APK);
    expect(out).toMatch(/UNTRUSTED/);
    expect(guestOk(`apk info -e ${PKG}`)).toBe(false);
  });

  await test.step('System → Administration → Repository Public Keys: add the key by URL', async () => {
    await page.goto('/cgi-bin/luci/admin/system/admin/repokeys');
    await page.locator('#key-input').fill(env.ABFM_KEY_URL);
    await page.getByRole('button', { name: 'Add key' }).click();
    await expect(page.getByText('adblock-fast-monitor.pem', { exact: true })).toBeVisible({ timeout: 60_000 });
    expect(guest(`sha256sum < ${KEY_PATH}`).split(' ')[0]).toBe(sha256(readFileSync(env.ABFM_KEY_FILE, 'utf8').trim()));
  });

  let before;
  await test.step('System → Software → Upload Package…: the signed package installs', async () => {
    guest('touch /tmp/luci-indexcache.abfm-probe; mkdir -p /tmp/luci-modulecache && touch /tmp/luci-modulecache/abfm-probe');
    before = rpcdId();
    const out = await uploadAndInstall(page, env.ABFM_SIGNED_APK);
    expect(out).not.toMatch(/failed with code|UNTRUSTED/);
    expect(guestOk(`apk info -e ${PKG}`)).toBe(true);
  });

  await test.step('postinst cleared the LuCI caches and reloaded rpcd (no manual restart)', async () => {
    expect(guestOk('ls /tmp/luci-indexcache.abfm-probe')).toBe(false);
    expect(guestOk('ls /tmp/luci-modulecache/abfm-probe')).toBe(false);
    expect(rpcdId()).not.toBe(before);
    expect(guestOk('pidof rpcd')).toBe(true);
  });

  await test.step('menu entry and ACL work for the logged-in admin and a read-only principal', async () => {
    await page.goto('/cgi-bin/luci/admin/status/overview');
    await expect(page.locator('a[href$="/admin/services/adblock-fast-monitor"]').first()).toBeAttached();
    const sid = await login(env.GUEST_READONLY_USER, env.GUEST_READONLY_PASSWORD);
    expect(sid).toMatch(/^[0-9a-f]{32}$/);
    expect((await rpc(sid, 'uci', 'get', { config: 'adblock-fast-monitor' })).result?.[0]).toBe(0);
    expect(guestOk('ubus list luci.adblock-fast-monitor'), 'rpcd plugin registered without a manual restart').toBe(true);
    const info = await rpc(sid, 'luci.adblock-fast-monitor', 'info');
    expect(info.result?.[0]).toBe(0);
    expect(info.result?.[1]?.ok).toBe(true);
    expect((await rpc(sid, 'luci.adblock-fast-monitor', 'apply', { ops: [] })).error?.code).toBe(-32002);
  });

  let files, dhcp;
  await test.step('monitoring on before removal (drop-ins exist)', async () => {
    files = packageFiles();
    dhcp = guest('sha256sum /etc/config/dhcp');
    guest('uci set adblock-fast-monitor.config.enabled=1 && uci commit adblock-fast-monitor && /etc/init.d/adblock-fast-monitor restart');
    expect(guestOk('i=0; until ubus list adblock-fast-monitor >/dev/null 2>&1; do i=$((i+1)); [ $i -lt 30 ] || exit 1; sleep 1; done'),
      'daemon object after enabling').toBe(true);
    expect(guest('ls /tmp/dnsmasq*.d/adblock-fast-monitor.conf 2>/dev/null || true').trim()).not.toBe('');
  });

  await test.step('System → Software → Installed → Remove… removes everything', async () => {
    before = rpcdId();
    await openSoftware(page);
    await page.locator('li[data-mode="installed"]').click();
    await page.locator('input[name="filter"]').fill(PKG);
    await page.locator(`div.btn[data-package="${PKG}"]`).click();
    await page.locator('.modal').getByText('Remove', { exact: true }).click();
    const out = await finishPackageManager(page);
    expect(out).not.toMatch(/failed with code/);
    expect(guestOk(`apk info -e ${PKG}`)).toBe(false);
    const left = files.filter((f) => f !== '/etc/config/adblock-fast-monitor' && guestOk(`test -e ${f}`));
    expect(left).toEqual([]);
    expect(guest('ls /tmp/dnsmasq*.d/adblock-fast-monitor.conf 2>/dev/null || true').trim()).toBe('');
    expect(guestOk("ps w | grep -q '[a]dblock-fast-monitor'")).toBe(false);
    expect(guestOk('ubus list adblock-fast-monitor')).toBe(false);
    expect(guestOk('ubus list luci.adblock-fast-monitor')).toBe(false);
    expect(guest('sha256sum /etc/config/dhcp')).toBe(dhcp);
    expect(rpcdId()).not.toBe(before);
    // The modified conffile (enabled=1) is kept, as apk does for changed conffiles.
    expect(guest('uci -q get adblock-fast-monitor.config.enabled', { check: false })?.trim()).toBe('1');
    expect(guestOk(`test -e ${KEY_PATH}`)).toBe(true);
  });

  await test.step('System → Software → Configure apk: add the feed; Update lists…; Install… from the feed', async () => {
    await openSoftware(page);
    await page.getByRole('button', { name: 'Configure apk' }).click();
    const area = page.locator('.modal textarea[name="/etc/apk/repositories.d/customfeeds.list"]');
    await expect(area).toBeVisible();
    await area.fill(`${await area.inputValue()}\n${env.ABFM_FEED_URL}\n`);
    await page.locator('.modal').getByText('Save', { exact: true }).click();
    await expect(page.locator('.modal')).toBeHidden({ timeout: 60_000 });
    expect(guest('cat /etc/apk/repositories.d/customfeeds.list')).toContain(env.ABFM_FEED_URL);

    await page.getByRole('button', { name: 'Update lists…' }).click();
    const update = await finishPackageManager(page);
    expect(update).not.toMatch(/UNTRUSTED/);

    await page.locator('input[name="filter"]').fill(PKG);
    const install = page.locator(`div.btn[data-package="${PKG}"][data-action="install"]`);
    await expect(install).toBeVisible({ timeout: 60_000 });
    await install.click();
    await page.locator('.modal').getByText('Install', { exact: true }).click();
    const out = await finishPackageManager(page);
    expect(out).not.toMatch(/failed with code|UNTRUSTED/);
    expect(guestOk(`apk info -e ${PKG}`)).toBe(true);
    expect(guestOk('ubus list luci.adblock-fast-monitor')).toBe(true);
    // The kept config (enabled=1) starts the daemon on reinstall.
    expect(guestOk('i=0; until ubus list adblock-fast-monitor; do i=$((i+1)); [ $i -lt 30 ] || exit 1; sleep 1; done')).toBe(true);
  });

  await test.step('sysupgrade keeps the key and the feed line', async () => {
    const keep = guest('sysupgrade -l');
    expect(keep).toContain(KEY_PATH);
    expect(keep).toContain('/etc/apk/repositories.d/customfeeds.list');
  });
});
