'use strict';

const assert = require('assert');
const fs = require('fs');

const common = fs.readFileSync('root/usr/lib/adblock-fast-monitor/common.sh', 'utf8');
const settings = fs.readFileSync('root/www/luci-static/resources/view/adblock-fast-monitor/settings.js', 'utf8');
const regression = fs.readFileSync('root/test/monitoring-dnsmasq-logqueries-regression.sh', 'utf8');

assert.match(common, /uci -q set dhcp\.@dnsmasq\[0\]\.logqueries=1/);
assert.doesNotMatch(common, /logqueries=extra/);
assert.match(common, /previous=.*__absent__/);
assert.match(common, /if \[ "\$current" = "\$applied" \]/);
assert.match(settings, /boolean setting to detailed query logging/);
assert.match(regression, /get dhcp\.@dnsmasq\[0\]\.logqueries\)" = 1/);
assert.match(regression, /log-queries=extra/);
assert.match(regression, /monitor_dnsmasq_release/);

console.log('dnsmasq boolean logging contracts passed');
