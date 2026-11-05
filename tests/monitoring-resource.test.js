'use strict';

const assert = require('assert');
const fs = require('fs');

const rpc = fs.readFileSync('root/usr/libexec/rpcd/adblock-fast-monitor', 'utf8');
const common = fs.readFileSync('root/usr/lib/adblock-fast-monitor/common.sh', 'utf8');
const collector = fs.readFileSync('root/usr/libexec/adblock-fast-monitor-collector', 'utf8');
const ring = fs.readFileSync('root/usr/libexec/adblock-fast-monitor-ring.uc', 'utf8');
const runtimeAdapter = fs.readFileSync('root/test/openwrt/provision.sh', 'utf8');

assert.match(rpc, /status\) status ;;/);
assert.match(rpc, /activity\) activity ;;/);
assert.match(rpc, /purge\)/);
assert.doesNotMatch(rpc, /^\s*action\)/m);
assert.doesNotMatch(rpc, /\bubus\b|\blogread\b|\bservice\b|\buci\b/);
assert.match(rpc, /limit=100/);
assert.match(rpc, /next_cursor/);
assert.match(rpc, /activity\.tsv is append-only oldest-first/);
assert.match(rpc, /current_rule "\$\{rest:-unknown\}"/);
assert.doesNotMatch(rpc, /\bawk\b|\bsed\b|\btail\b|\bcat\b|\bstat\b/);
assert.match(common, /mkdir -m 0700/);
assert.match(common, /chmod 0600/);
assert.match(common, /stat -c '%u'/);
assert.match(common, /MONITOR_LOCK="\$MONITOR_STATE\/monitor\.lock"/);
assert.match(common, /MONITOR_GENERATION="\$MONITOR_STATE\/generation"/);
assert.match(rpc, /LOCK="\$STATE_DIR\/monitor\.lock"/);
assert.match(rpc, /GENERATION="\$STATE_DIR\/generation"/);
assert.match(rpc, /snapshot_current/);
assert.match(common, /monitor_dnsmasq_release/);
assert.match(common, /previous=__absent__/);
assert.match(common, /MONITOR_RUNTIME=\/var\/run\/adblock-fast-monitor/);
assert.match(common, /MONITOR_DNS_OWNER="\$MONITOR_RUNTIME\/dnsmasq-logqueries\.owner"/);
assert.doesNotMatch(collector, /monitor_add_event|\bwc\b|\btail\b/);
assert.match(collector, /\/usr\/bin\/ucode/);
assert.match(ring, /let events = \[\]/);
assert.match(ring, /if \(length\(events\) > capacity\)/);
assert.match(ring, /reset_if_purged/);
assert.match(ring, /fs\.flock\(lock_file, 'ex'\)/);
assert.match(ring, /generation=' \+ generation/);
assert.match(ring, /time\(\) - last_snapshot < snapshot_interval/);
assert.match(ring, /atomic_write/);
assert.doesNotMatch(ring, /\bwc\b|\btail\b|append\(|adblock-fast-monitor-snapshot/);
assert.match(runtimeAdapter, /nslookup/);
assert.match(runtimeAdapter, /ubus call adblock-fast-monitor status/);
assert.match(runtimeAdapter, /ubus call adblock-fast-monitor purge/);
assert.match(runtimeAdapter, /query-\$i\.monitor-runtime\.test/);

console.log('monitoring resource contracts passed');
