// Guest test helper: times one ubus call.
//   ucode time-call.uc OBJECT METHOD '<JSON args>'
// Prints {"ms":N,"reply":…}.
let ubus = require('ubus');
let conn = ubus.connect();
let c0 = clock(true);
let reply = conn.call(ARGV[0], ARGV[1], json(ARGV[2] ?? '{}'));
let c1 = clock(true);
printf('%J\n', { ms: int((c1[0] - c0[0]) * 1000 + (c1[1] - c0[1]) / 1000000), reply, error: reply == null ? ubus.error() : null });
