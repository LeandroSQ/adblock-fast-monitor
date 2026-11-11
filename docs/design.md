# Design notes

Background for [`CONTRACT.md`](CONTRACT.md), which alone is normative: the
history of the design, the reasons behind its decisions and the upstream
facts it was checked against. Budgets, method and measurements are in
[`performance.md`](performance.md).

## History

The first interface (api 1, never released) ran a resident ucode daemon on
the router that followed the system log, parsed and correlated dnsmasq's
query lines and served statistics over ubus. It was replaced before the
first release by the current design (api 2) because a resident process and
per-query work on the router conflict with the resource budgets (CONTRACT
§1, §11): the browser now reads `log read` and does all parsing, and the
router only switches dnsmasq's query logging on. The line grammar and the
classification table were ported from the daemon's ucode to `querylog.js`;
a one-time differential test over the dnsmasq fixtures (T05) guarded the
port. Nothing migrates from api 1, since it was never installed by users.

## Why the decisions hold

- **No resident process (D1).** Query logging is a static dnsmasq option, so
  nothing has to run between configuration changes; logd already keeps the
  lines and LuCI already reads them (`log read`) for its System Log page.
- **No edits to `/etc/config/dhcp` (D2).** A runtime drop-in in the
  instance's confdir lives in tmpfs and disappears with the package, and
  it steps aside for an instance where luci-app-adblock-fast's `logqueries`
  toggle is already on (CONTRACT §14).
  `log-async=25` keeps logging off dnsmasq's query path: with it, api 1's
  measurements on 25.12.6 (dnsmasq 2.93) lost no line at normal rates in
  `dnsmasq.servers` and `dnsmasq.addnhosts` modes.
- **One rebuild per Apply (D5).** adblock-fast's own `allow` is defective and
  `reload`/`restart` absorb list changes without rebuilding (CONTRACT §10,
  §14), so the only reliable way to apply a rule is `adblock-fast dl`.
  Staging in the browser lets many changes share that one rebuild.
- **Admins only (D6).** `log read` grants the whole system log; the
  package reuses that existing grant, as luci-app-adblock-fast and the
  System Log page do, instead of adding a router-side filter. The
  trade-off and the way out are in CONTRACT §14.

## Upstream facts

Verified 2026-11-10 against the pinned sources; CONTRACT §12 points here.

- ucode pin: `PKG_SOURCE_VERSION:=85922056ef7a…` —
  <https://raw.githubusercontent.com/openwrt/openwrt/openwrt-25.12/package/utils/ucode/Makefile>.
  The same file packages the `ucode-mod-io`, `ucode-mod-resolv` and
  `ucode-mod-uloop` modules.
- `io.pipe`, `io.new`, `dup2`, and `read` (a raw `read(2)`) exist
  (`lib/io.c` L501, L772, L1124, L1249). `fs.file#lock` is `flock` with
  `s`/`x`/`n`/`u` (`lib/fs.c` L849). `resolv.query(names,{type,nameserver,timeout,retries})`
  returns `{name:{A:[],AAAA:[],rcode}}` (`lib/resolv.c`) —
  <https://github.com/jow-/ucode/tree/85922056/lib>
- `luci-base` depends on `+rpcd +rpcd-mod-ucode +ucode +ucode-mod-fs +ucode-mod-uci +ucode-mod-ubus …` —
  <https://raw.githubusercontent.com/openwrt/luci/openwrt-25.12/modules/luci-base/Makefile>.
  The `luci.mk` postinst clears caches and runs `rpcd reload` (L238-240).
  `L.hasViewPermission()` is at luci.js L3259.
- rpcd `d99f703`: ucode plugins come from `/usr/share/rpcd/ucode`, are loaded
  once at init, and world-writable scripts are skipped (`ucode.c` L35,
  L1087-1100). Requests can `defer`, `reply` and `error`. SIGHUP re-execs
  rpcd (`main.c` L44, L66) —
  <https://github.com/openwrt/rpcd/blob/d99f703e4035d03fbcfbada3cb697db346c2b984/ucode.c>
- uhttpd `93b05e0` `ubus.c`: the object lookup comes before the ACL check, so
  a missing object gives `-32000 Object not found` and a denied call gives
  `-32002 Access denied` (L120-122, L973-979) —
  <https://github.com/openwrt/uhttpd/blob/93b05e0b65d91c23c5aa8fdde378df1f174ec71d/ubus.c>
- dnsmasq 2.93 (`PKG_UPSTREAM_VERSION:=2.93`, openwrt-25.12
  `package/network/services/dnsmasq/Makefile`):
  - the `log_query` extra format, `config`/`reply`/`cached`/`cached-stale`
    sources, the hosts path as source, `<CNAME>` and `NODATA-IPv4/6`
    (`src/cache.c` L2321-2513);
  - `sanitise` lower-cases names (L2014-2030);
  - `server=/x/` hits log `config x is NXDOMAIN` (`src/domain-match.c` L424);
  - `reply query is duplicate` (`src/forward.c` L1490);
  - `overflow: N log entries lost` (`src/log.c` L203).

  Fetched from the GitHub mirror at tag v2.93,
  <https://github.com/1g4-mirror/dnsmasq/tree/v2.93/src> (upstream gitweb
  requires interactive login for automated clients).
- `dnsmasq.init` (openwrt-25.12): `START=19` (L4);
  `logqueries` → `--log-queries=extra` (L990); `logfacility` (L1026);
  conf-dir `confdir` defaulting to `/tmp/dnsmasq${cfg:+.$cfg}.d`, created if
  missing (L1172-1178) —
  <https://raw.githubusercontent.com/openwrt/openwrt/openwrt-25.12/package/network/services/dnsmasq/files/dnsmasq.init>
- ubox `6f78fa4`:
  - output format at L209;
  - logd strips `<prio>` and the 16-character timestamp (`log/syslog.c`
    L174-186);
  - `LOG_LINE_SIZE` is 1024 (`log/syslog.h`).

  <https://github.com/openwrt/ubox/tree/6f78fa496bf36c55864a41e353df7d13f04b1077/log>
- adblock-fast 1.2.4-r4 (openwrt-25.12 `net/adblock-fast`): `dns_modes` and
  sinkholes (`files/lib/adblock-fast/adblock-fast.uc` L35-78), triggers (L28,
  L1032), `enabled` check (L1075), rebuild allow removal (L2020), and
  `allow()` (L2661-2725). UCI schema in `files/etc/init.d/adblock-fast`
  `load_validate_config` —
  <https://github.com/openwrt/packages/tree/openwrt-25.12/net/adblock-fast/files>
- BusyBox defaults (openwrt-25.12 `package/utils/busybox/Config-defaults.in`):
  `STAT n`, `TIMEOUT n`; `FLOCK`, `SETSID`, `KILL`, `GREP`, `AWK` and
  `NSLOOKUP` are `y`.

- ubox `6f78fa4` logd (`log/logd.c` L86-93, L95-158, `log/syslog.c` L44,
  L209-214, `log/log.init` L28-39):
  - `log read {lines, stream, oneshot}` with `stream:false` replies
    `{log:[{msg, id, priority, source, time}]}`: the **last** `lines`
    entries, oldest first; `time` is epoch **milliseconds**; `msg` keeps the
    `dnsmasq[1]:` tag and the space after it. Without `lines` the reply holds the **whole** ring;
    an explicit `lines:0` returns nothing.
  - ids come from `current_id++`, so they are consecutive across all
    sources: a cursor and a gap detector. A logd restart starts again at 0.
  - each ring entry costs a 32-byte head plus the message padded to 4 bytes;
    the ring size is `-S` from `log_buffer_size`, else `log_size`, else
    64 KiB; a fresh 25.12 install sets `log_size='128'`.
  - logd sends a ubus notification per line to subscribers; `log write`
    appends a line.
- ubus (25.12): a message is capped at 1 MiB; ubusd disconnects a client that
  sends more (`ubusd_main.c` L154-155), so an oversized `log read` reply would
  knock logd off ubus.
- uhttpd `93b05e0` serves `GET /ubus/subscribe/<object>` as server-sent
  events, authorized by `Authorization: Bearer <sid>` and the ACL method
  `:subscribe` on that object (`ubus.c` L150, L427-468, L491-494). A refused
  subscription is still HTTP 200, but `application/json` with a
  `Permission denied` error instead of `text/event-stream` (L436-439).
- A session with luci-base's write grant reaches rpcd's `uci set` for any
  config; rpcd's own uci ACL then refuses configs outside the session's `uci`
  write grant with ubus status 6 (verified for `adblock-fast`, T21).
- LuCI openwrt-25.12: `luci-app-adblock-fast` grants `"log":["read"]` and
  polls `log read` (1000 lines every 5 s, no cursor); the System Log page
  does the same (`tools/views.js` LogreadBox). `L.Poll` never pauses for a
  hidden tab (luci.js L1158-1209). `E(tag, {}, "string")` sets
  **innerHTML** (luci.js L1394); only an array child becomes a text node
  (L1383).
- dnsmasq 2.93 `sanitise()` only rejects non-printable bytes and lower-cases
  (`cache.c` L2014-2030); for a PTR lookup the answer field is the target
  **name** (L2351, L2407-2410), so `<`, `>`, `"`, `/`, `=` and `(` from a
  remote rDNS owner reach the log unchanged.
- rpcd `d99f703` `uci.c` L289-315: LuCI's `uci set` through rpcd stages
  changes in the per-session savedir `/var/run/rpcd/uci-<sid>`, not in
  `/tmp/.uci`.

### Facts only api 1 relied on

Kept for reference; the current package does not use them.

- `uloop.process` accepts only a **string** executable (`lib/uloop.c` L1012)
  and does not capture stdout. `process.delete()` does not kill the child —
  <https://github.com/jow-/ucode/blob/85922056/lib/uloop.c>
- `conn.publish(name, {m:{args,call}})` exists (`lib/ubus.c` L1889).
  Returning an object replies, returning an integer sets the ubus status, and
  any exception other than `exit` halts uloop (L1574-1632) —
  <https://github.com/jow-/ucode/blob/85922056/lib/ubus.c>
- ubox `6f78fa4` `logread -e` compiles a **BRE** (`regcomp` without
  `REG_EXTENDED`) and matches it against the message, which includes the
  `dnsmasq[pid]:` tag (`log/logread.c` L160, L363).
