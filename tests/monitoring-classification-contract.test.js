'use strict';

const assert = require('assert');
const fs = require('fs');

const common = fs.readFileSync('root/usr/lib/adblock-fast-monitor/common.sh', 'utf8');
const collector = fs.readFileSync('root/usr/libexec/adblock-fast-monitor-collector', 'utf8');
const ring = fs.readFileSync('root/usr/libexec/adblock-fast-monitor-ring.uc', 'utf8');

assert.match(common, /uci -q get adblock-fast\.config\.blocked_domain/);
assert.match(common, /\[ "\$count" -lt 1024 \]/);
assert.match(common, /MONITOR_KNOWN_BLOCKED/);
assert.match(collector, /monitor_refresh_known_blocks \|\|/);
assert.match(ring, /fs\.readfile\(state_dir \+ '\/known-blocked\.tsv'\)/);
assert.match(ring, /source == 'config'/);
assert.match(ring, /record\('blocked', domain, 'adblock-fast-config'\)/);
assert.match(ring, /record\('unknown', domain, 'local-config'\)/);
assert.match(ring, /answer == 'NXDOMAIN'/);
assert.match(ring, /record\('allowed', domain, source == 'cache' \? 'cached-nxdomain' : 'upstream-nxdomain'\)/);
assert.match(ring, /record\('allowed', domain, source == 'cache' \? 'cached-response' : 'upstream-reply'\)/);
assert.match(ring, /record\('unknown', domain, 'cname-ambiguous'\)/);
assert.match(ring, /if \(!consume_query\(domain\)\) \{\s*\n\s*return/);
assert.match(ring, /function process_line\(line\) \{[\s\S]*?line = trim\(line\);/);
assert.doesNotMatch(ring, /fs\.popen\([^)]*(known-blocked|adblock-fast)/);

console.log('monitoring classification contracts passed');
