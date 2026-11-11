// Prepares the guest once for the browser suite:
// - points adblock-fast at the deterministic local fixture list;
// - turns on query logging and starts a fake upstream for *.up.example.test.
import { ensureHealthy, guest, startUpstream, waitAdblockFast } from './lib/guest.mjs';

export default async function globalSetup() {
  const fixtures = process.env.GUEST_FIXTURE_URL;
  if (!fixtures) throw new Error('Browser test prerequisite blocked: GUEST_FIXTURE_URL is unset');
  // the heartbeat name below must resolve before adblock-fast restarts
  startUpstream();
  guest([
    'set -e',
    'while uci -q delete adblock-fast.@file_url[0]; do :; done',
    's=$(uci add adblock-fast file_url)',
    `uci set adblock-fast.$s.url='${fixtures}/lists/primary.txt'`,
    'uci set adblock-fast.$s.name=fixture',
    'uci set adblock-fast.$s.action=block',
    'uci set adblock-fast.$s.enabled=1',
    'uci -q delete adblock-fast.config.allowed_domain || :',
    'uci -q delete adblock-fast.config.blocked_domain || :',
    'uci set adblock-fast.config.enabled=1',
    'uci set adblock-fast.config.dns=dnsmasq.servers',
    // a name the fake upstream answers, so no rebuild needs internet DNS
    "uci set adblock-fast.config.heartbeat_domain='hb.up.example.test'",
    'uci set adblock-fast.config.config_update_enabled=0',
    'uci commit adblock-fast',
    '/etc/init.d/adblock-fast enable',
    '/etc/init.d/adblock-fast restart >/dev/null 2>&1 || :'
  ].join('\n'));
  waitAdblockFast();
  ensureHealthy();
}
