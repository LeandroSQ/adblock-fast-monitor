import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const read = path => readFile(path, 'utf8');

test('package installs the target-neutral collector runtime and both RPC plugins', async () => {
  const makefile = await read('Makefile');
  assert.match(makefile, /^  PKGARCH:=all$/m);
  assert.match(makefile, /DEPENDS:=.*\+ucode/);
  assert.doesNotMatch(makefile, /rpcd-mod-uci/);
  assert.match(makefile, /adblock-fast-monitor-metadata\.uc/);
  assert.match(makefile, /adblock-fast-monitor-ring\.uc \$\(1\)\/usr\/libexec\/adblock-fast-monitor-ring\.uc/);
  assert.match(makefile, /adblock-fast-monitor\/model\.js \$\(1\)\/www\/luci-static\/resources\/adblock-fast-monitor\/model\.js/);
  assert.doesNotMatch(makefile, /adblock-fast-monitor-snapshot/);
  assert.match(makefile, /rpcd\/adblock-fast-monitor \$\(1\)\/usr\/libexec\/rpcd\/adblock-fast-monitor/);
  assert.match(makefile, /rpcd\/adblock-fast-monitor-actions \$\(1\)\/usr\/libexec\/rpcd\/adblock-fast-monitor-actions/);
});

test('pinned 25.12.6 feed rejection prevents unavailable RPC dependencies', async () => {
  const fixture = JSON.parse(await read('test/fixtures/openwrt-25.12.6-package-availability.json'));
  assert.equal(fixture.release, '25.12.6');
  assert.equal(fixture.target, 'x86/64');
  assert.deepEqual(fixture.unavailablePackageDependencies, [{
    name: 'rpcd-mod-uci',
    observedError: 'ERROR: unable to select packages:\n  rpcd-mod-uci (no such package)'
  }]);
});

test('ACL keeps destructive purge write-gated and separates action RPC methods', async () => {
  const acl = JSON.parse(await read('root/usr/share/rpcd/acl.d/luci-app-adblock-fast-monitor.json'));
  const rules = acl['luci-app-adblock-fast-monitor'];
  assert.deepEqual(rules.read.ubus['adblock-fast-monitor'], ['status', 'activity']);
  assert.deepEqual(rules.write.ubus['adblock-fast-monitor'], ['purge']);
  assert.deepEqual(rules.write.ubus['adblock-fast-monitor-actions'], ['action', 'job']);
});

test('LuCI menu exposes separate overview and settings routes', async () => {
  const menu = JSON.parse(await read('root/usr/share/luci/menu.d/luci-app-adblock-fast-monitor.json'));
  assert.equal(menu['admin/services/adblock-fast-monitor'].action.type, 'firstchild');
  assert.equal(menu['admin/services/adblock-fast-monitor/settings'].action.path, 'adblock-fast-monitor/settings');
});

test('service and UCI configuration expose the documented lifecycle contract', async () => {
  const [config, init, settings, overview] = await Promise.all([
    read('root/etc/config/adblock-fast-monitor'),
    read('root/etc/init.d/adblock-fast-monitor'),
    read('root/www/luci-static/resources/view/adblock-fast-monitor/settings.js'),
    read('root/www/luci-static/resources/view/adblock-fast-monitor/overview.js')
  ]);
  assert.match(config, /^config monitor 'config'$/m);
  for (const option of ['enabled', 'max_events', 'poll_interval', 'own_logqueries']) {
    assert.match(config, new RegExp(`^\\s*option ${option} `, 'm'));
  }
  assert.doesNotMatch(config, /\bowner_value\b/);
  assert.doesNotMatch(settings, /\bowner_value\b/);
  assert.match(overview, /method:\s*'purge'/);
  assert.match(overview, /session\.access\('ubus', 'adblock-fast-monitor', 'purge'\)/);
  assert.match(overview, /this\.canPurge = canPurge === true/);
  assert.match(init, /mkdir -p \/var\/run\/adblock-fast-monitor/);
  assert.match(init, /chmod 0700 \/var\/run\/adblock-fast-monitor/);
  assert.match(init, /procd_set_param command \/usr\/libexec\/adblock-fast-monitor-collector/);
  assert.match(init, /adblock-fast-monitor-collector cleanup/);
});
