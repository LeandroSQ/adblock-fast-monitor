// Prepares the guest once for the browser suite:
// - ABFM_UI_STUB=1 only: installs the test-only backend stubs from
//   fixtures/stub (used before the real backends land; never shipped);
// - points adblock-fast at the deterministic local fixture list;
// - enables monitoring with a 2 s refresh.
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { ensureHealthy, guest, waitAdblockFast } from './lib/guest.mjs';

export default async function globalSetup() {
  if (process.env.ABFM_UI_STUB === '1') {
    const dir = fileURLToPath(new URL('./fixtures/stub', import.meta.url));
    const ssh = ['ssh', '-i', process.env.GUEST_SSH_KEY, '-p', process.env.GUEST_SSH_PORT, '-o', 'BatchMode=yes',
      '-o', 'StrictHostKeyChecking=no', '-o', `UserKnownHostsFile=${process.env.GUEST_RUN_DIR}/known_hosts`,
      '-o', 'LogLevel=ERROR', 'root@127.0.0.1'];
    const q = (s) => `'${s.replace(/'/g, "'\\''")}'`;
    const result = spawnSync('bash', ['-c',
      `tar -C ${q(dir)} -cf - . | ${ssh.map(q).join(' ')} 'rm -rf /tmp/abfm-ui-stub && mkdir -p /tmp/abfm-ui-stub && tar -C /tmp/abfm-ui-stub -xf - && sh /tmp/abfm-ui-stub/install.sh'`],
    { encoding: 'utf8' });
    if (result.status !== 0) throw new Error(`stub install failed:\n${result.stderr}${result.stdout}`);
    console.log('browser suite: using the test-only backend stubs (ABFM_UI_STUB=1)');
  }

  const fixtures = process.env.GUEST_FIXTURE_URL;
  if (!fixtures) throw new Error('Browser test prerequisite blocked: GUEST_FIXTURE_URL is unset');
  guest([
    'set -e',
    'for s in $(uci show adblock-fast | sed -n "s/^adblock-fast\\.\\([^.=]*\\)=file_url$/\\1/p"); do uci delete adblock-fast.$s; done',
    's=$(uci add adblock-fast file_url)',
    `uci set adblock-fast.$s.url='${fixtures}/lists/primary.txt'`,
    'uci set adblock-fast.$s.name=fixture',
    'uci set adblock-fast.$s.action=block',
    'uci set adblock-fast.$s.enabled=1',
    'uci -q delete adblock-fast.config.allowed_domain || :',
    'uci -q delete adblock-fast.config.blocked_domain || :',
    'uci set adblock-fast.config.enabled=1',
    'uci set adblock-fast.config.dns=dnsmasq.servers',
    "uci set adblock-fast.config.heartbeat_domain='-'",
    'uci set adblock-fast.config.config_update_enabled=0',
    'uci commit adblock-fast',
    '/etc/init.d/adblock-fast enable',
    '/etc/init.d/adblock-fast restart >/dev/null 2>&1 || :'
  ].join('\n'));
  waitAdblockFast();
  ensureHealthy();
}
