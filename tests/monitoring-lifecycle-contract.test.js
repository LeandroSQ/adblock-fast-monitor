'use strict';

const assert = require('assert');
const fs = require('fs');

const collector = fs.readFileSync('root/usr/libexec/adblock-fast-monitor-collector', 'utf8');
const ring = fs.readFileSync('root/usr/libexec/adblock-fast-monitor-ring.uc', 'utf8');
const rpc = fs.readFileSync('root/usr/libexec/rpcd/adblock-fast-monitor', 'utf8');
const view = fs.readFileSync('root/www/luci-static/resources/view/adblock-fast-monitor/overview.js', 'utf8');
const runner = fs.readFileSync('scripts/integration/run-local-linux-validation.sh', 'utf8');

/* A dead log stream returns from ucode and transitions to a truthful degraded
 * status. Ring retention is arrival-ordered, not timestamp-ordered, so wall
 * clock jumps cannot grow retained memory or corrupt cursor ordering. */
assert.match(collector, /\/usr\/bin\/ucode[\s\S]*monitor_set state degraded/);
assert.match(ring, /if \(length\(events\) > capacity\)[\s\S]*shift\(events\)/);
assert.match(ring, /timestamp: time\(\)/);
assert.doesNotMatch(ring, /sort\(|timestamp.*[<>]/);

assert.match(rpc, /case "\$cursor" in \*\[!0-9\]\*\|''\) cursor=0/);
assert.match(rpc, /case "\$filter" in ''\|all\|"\$decision"\)/);
assert.match(view, /document\.createTextNode/);
assert.doesNotMatch(view, /\.innerHTML\s*=/);
assert.match(view, /document\.hidden/);
assert.match(view, /MAX_CURSOR_HISTORY/);
assert.match(runner, /sdk-package-source\.sha256/);
assert.match(runner, /cmp -s "\$source_manifest" "\$sdk_package_manifest"/);

console.log('monitor lifecycle and dashboard contracts passed');
