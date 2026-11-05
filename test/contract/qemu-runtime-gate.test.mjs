import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

test('PR CI owns a self-contained, measured OpenWrt QEMU lifecycle gate', async () => {
  const [workflow, qemu, lifecycle, performance, resident] = await Promise.all([
    readFile('.github/workflows/ci.yml', 'utf8'),
    readFile('scripts/integration/run-openwrt-qemu.sh', 'utf8'),
    readFile('scripts/integration/package-lifecycle.sh', 'utf8'),
    readFile('scripts/integration/measure-performance.mjs', 'utf8'),
    readFile('scripts/integration/measure-monitor-resident.sh', 'utf8')
  ]);

  assert.match(workflow, /qemu-runtime:/);
  assert.match(workflow, /runs-on: ubuntu-24\.04/);
  assert.doesNotMatch(workflow, /OPENWRT_SSH_PRIVATE_KEY|OPENWRT_QEMU_ENABLED|self-hosted/);
  assert.match(workflow, /libguestfs-tools/);
  assert.match(workflow, /actions\/download-artifact@/);
  assert.match(qemu, /openwrt-25\.12\.6-x86-64-generic-ext4-combined\.img\.gz/);
  assert.match(qemu, /f8538784d0288b4133a99ac2a68443e4922ffde6343e80df56a5882364b9d499/);
  assert.match(qemu, /ssh-keygen/);
  assert.match(qemu, /monitor-readonly/);
  assert.match(qemu, /OPENWRT_RUNTIME_TEST="\$PWD\/scripts\/integration\/runtime-dns-lifecycle\.sh"/);
  assert.match(qemu, /guestfish/);
  assert.match(qemu, /-enable-kvm/);
  assert.match(qemu, /-accel tcg,thread=multi/);
  assert.match(qemu, /python3 -m http\.server 18080/);
  assert.match(qemu, /hostfwd=udp::5353-:53/);
  assert.match(lifecycle, /OPENWRT_RUNTIME_TEST/);
  assert.match(lifecycle, /luci-software-upload\.mjs/);
  assert.match(lifecycle, /measure-performance\.mjs/);
  assert.match(lifecycle, /MONITOR_READONLY_LUCI_USERNAME/);
  assert.match(lifecycle, /adblock-fast-monitor\/model\.js/);
  assert.match(performance, /measure-monitor-resident\.sh/);
  assert.match(performance, /dns-probe\.mjs/);
  assert.match(resident, /MONITOR_SATURATION_EVENTS/);
  assert.match(resident, /processTreeBefore/);
  assert.match(resident, /expected_total=\$\(\(before_total \+ MONITOR_SATURATION_EVENTS\)\)/);
  assert.match(resident, /timed out waiting for a fresh ring status/);
  assert.match(resident, /processTreeAfterDns/);
});
