# luci-app-adblock-fast-monitor — v1 interface contract (FROZEN)

Status: **frozen at API version 1**. Implementers (WU1 data plane, WU2 actions,
WU3 LuCI UI, WU4 packaging, WU5 CI, WU6 performance) code against this file.
Changing any name, field, type, bound, state, or error code needs a contract
change: edit this file and bump `api` in the same commit. Every response that
this package defines includes `"api": 1`.

Targets: OpenWrt 25.12.6, adblock-fast 1.2.4-r4, LuCI openwrt-25.12, ucode
`85922056`, procd `58eb263`, rpcd `d99f703`, dnsmasq 2.93, ubox `6f78fa4`.
The package is standalone. It depends on adblock-fast and never forks or
patches it.

This file supersedes `MONITORING_API.md`, `RULE_ACTION_API.md`,
`INTEGRATION_CONTRACT.md` and `RUNTIME_TEST_REQUIREMENTS.md` (§15).

---

## 1. Architecture (fixed decisions)

| # | Decision |
|---|---|
| D1 | **One resident ucode daemon** (`monitord.uc`). procd execs it directly: the shebang is `#!/usr/bin/ucode`, with no shell parent. It runs **only** while `adblock-fast-monitor.config.enabled=1`. When disabled, `start_service` returns before `procd_open_instance`, so the package runs no process. The daemon spawns `logread` with a **string** executable, parses dnsmasq `log-queries=extra` lines with one anchored regex, keeps all state in bounded RAM structures, and **publishes its own ubus object** `adblock-fast-monitor` through `ucode-mod-ubus`. It writes no snapshot, lock or generation files, and no shell read plugin exists. |
| D2 | **No edits to `/etc/config/dhcp`.** Query logging comes from a tmpfs drop-in, `<confdir>/adblock-fast-monitor.conf` containing `log-queries=extra`, written for each targeted dnsmasq instance. It is removed on disable or stop. dnsmasq restarts **only** when the set of drop-ins changes **and** dnsmasq is running. |
| D3 | **Classification** is computed from the log line alone (§4.4). The `source` field records attribution. |
| D4 | **Statistics** are cumulative since daemon start or the last purge. They are bounded: recent-domains LRU, Space-Saving top-N maps, and a pending-correlation map with a TTL (§4.5). |
| D5 | **Rule changes are staged in the browser**; the server keeps no shadow rules. One `apply` call sends the whole batch to the rpcd ucode plugin `luci.adblock-fast-monitor`. `apply` validates the batch, writes **only** `/etc/config/adblock-fast`, commits, and spawns **one** detached job. The job runs the adblock-fast runtime step (one rebuild; adblock-fast's own `allow` is not usable, §14.1), then verifies each domain against real DNS answers from `127.0.0.1`. One job runs at a time, enforced by `flock` on a file descriptor. |

Process inventory: none while disabled. While enabled, there is exactly one
`ucode monitord.uc` process plus one `/sbin/logread` child. A job, when
running, adds one `ucode job.uc` process plus adblock-fast's own children.

---

## 2. Package file inventory (final)

| Path | Mode | Owner WU | Purpose |
|---|---|---|---|
| `/etc/config/adblock-fast-monitor` | 0644 conffile | WU4 | §3 |
| `/etc/init.d/adblock-fast-monitor` | 0755 | WU1 | procd init, `START=18` (before dnsmasq `START=19`) |
| `/usr/libexec/adblock-fast-monitor/monitord.uc` | 0755 | WU1 | resident daemon (D1) |
| `/usr/libexec/adblock-fast-monitor/logging.uc` | 0755 | WU1 | `enable` / `disable` / `status` of the dnsmasq drop-ins (§5) |
| `/usr/libexec/adblock-fast-monitor/job.uc` | 0755 | WU2 | detached apply job (§7) |
| `/usr/share/ucode/abfm/logparse.uc` | 0644 | WU1 | pure functions: `parse_line(str)` and `classify(event, ctx)` (§4.3–4.4) |
| `/usr/share/ucode/abfm/stats.uc` | 0644 | WU1 | pure bounded structures (§4.5) |
| `/usr/share/ucode/abfm/domain.uc` | 0644 | WU2 | grammar, protected domains, public-suffix guard, `plan()` (§6.4–6.6) |
| `/usr/share/ucode/abfm/system.uc` | 0644 | WU1+WU2 | discovery of UCI, dnsmasq instances/confdirs and adblock-fast state |
| `/usr/share/rpcd/ucode/luci.adblock-fast-monitor` | 0644, **not** world-writable | WU2 | rpcd ucode plugin (§6) |
| `/usr/share/rpcd/acl.d/luci-app-adblock-fast-monitor.json` | 0644 | WU4 | §9 |
| `/usr/share/luci/menu.d/luci-app-adblock-fast-monitor.json` | 0644 | WU3 | menu (same as today; depends on ACL `luci-app-adblock-fast-monitor`) |
| `/www/luci-static/resources/view/adblock-fast-monitor/overview.js` | 0644 | WU3 | dashboard + staging + apply |
| `/www/luci-static/resources/view/adblock-fast-monitor/settings.js` | 0644 | WU3 | `form.Map('adblock-fast-monitor')` |
| `/www/luci-static/resources/adblock-fast-monitor/model.js` | 0644 | WU3 | pure UI logic: state derivation (§8.1), staging reducer (§8.2) |

Runtime paths. Everything is tmpfs, so nothing survives a reboot by design.

| Path | Writer | Content |
|---|---|---|
| `/var/run/adblock-fast-monitor/` | init / plugin, 0700 root | directory |
| `/var/run/adblock-fast-monitor/job.json` | plugin + job, 0600, atomic rename | last job (§7) |
| `/var/run/adblock-fast-monitor/uci/` | plugin, 0700 | private UCI savedir for `apply` |
| `/var/lock/adblock-fast-monitor.lock` | plugin + job | `flock` target (§7.3) |
| `<confdir>/adblock-fast-monitor.conf` | `logging.uc`, 0644 | the single line `log-queries=extra` |

The `abfm.*` modules are imported as `import … from 'abfm.<name>'`, which is
ucode's default search path `/usr/share/ucode/`. Each module must load under a
ucode interpreter built at pin `85922056` on the CI host, with no OpenWrt
runtime present. That is what makes the unit tests possible (§13).

**Removed** by the owning WU in their first commit: `adblock-fast-monitor-collector`,
`-ring.uc`, `-classifier*.uc`, `-metadata.uc`, `-job` (sh),
`/usr/libexec/rpcd/adblock-fast-monitor{,-actions}` (sh exec plugins),
`/usr/lib/adblock-fast-monitor/common.sh`, and `root/test/*.sh`. WU5 replaces
`root/test/*.sh` with executed tests. Both the `/tmp/adblock-fast-monitor/`
state directory and the
`/var/run/adblock-fast-monitor/dnsmasq-logqueries.owner` record cease to exist.

**Package dependencies.** WU4 owns the Makefile. v1 depends on: `+luci-base`
(which pulls in `rpcd`, `rpcd-mod-ucode`, `ucode`, `ucode-mod-fs`,
`ucode-mod-uci` and `ucode-mod-ubus`), `+adblock-fast`, `+ucode-mod-uloop`,
`+ucode-mod-io` and `+ucode-mod-resolv`. `jsonfilter` is dropped.
`PKGARCH:=all`. Postinst and postrm must do what `luci.mk` does:
`rm -f /tmp/luci-indexcache.*; rm -rf /tmp/luci-modulecache/; /etc/init.d/rpcd reload`
(SIGHUP makes rpcd re-exec, which loads the new plugin and ACL). Prerm runs
`/etc/init.d/adblock-fast-monitor stop`, which removes the drop-ins. Install
through LuCI → System → Software must work **without** `--allow-untrusted`,
using a key added on the "Repository Public Keys" page. WU4 owns key custody.

---

## 3. Configuration `/etc/config/adblock-fast-monitor`

One section: `config monitor 'config'`. Values outside their range are
clamped to the nearest bound. Values that don't parse fall back to the default.
Every consumer clamps the same way.

| Option | Type | Default | Range | Consumer | Meaning |
|---|---|---|---|---|---|
| `enabled` | bool | `0` | | init | `0`: no daemon and no drop-ins |
| `manage_logging` | bool | `1` | | init → `logging.uc` | `1`: write drop-ins; `0`: the user provides `log-queries=extra` |
| `dnsmasq_instance` | list | `*` | `*` or dhcp `dnsmasq` section names | `logging.uc` | instances that get a drop-in. `*` means every instance with `disabled!=1` |
| `recent_size` | uint | `500` | 50–2000 | daemon | capacity of the recent-domains LRU |
| `top_size` | uint | `256` | 32–1024 | daemon | entries **tracked** in each Space-Saving map |
| `pending_size` | uint | `512` | 64–4096 | daemon | capacity of the correlation map |
| `pending_ttl` | uint (s) | `10` | 2–60 | daemon | lifetime of a query that has no answer yet |
| `record_clients` | bool | `0` | | daemon | `1`: keep the last client IP for each recent domain |
| `exclude_router` | bool | `1` | | daemon | `1`: ignore queries from `127.0.0.1` and `::1` (the job's verification, adblock-fast heartbeat) |
| `poll_interval` | uint (s) | `5` | 2–60 | UI | refresh period for status and domains |

v0 options `max_events` and `own_logqueries` are ignored and are not rendered.
Settings saves go through LuCI `uci.apply`. procd reload trigger: the daemon
restarts, dnsmasq is untouched unless the drop-in set changes, and counters
reset (documented in the UI).

---

## 4. Data plane — daemon `monitord.uc` (WU1)

### 4.1 Lifecycle (init script)

```
start_service:
  config_load adblock-fast-monitor
  enabled!=1         -> logging.uc disable ; return          # no instance => procd stops any old one
  manage_logging=1   -> logging.uc enable  else logging.uc disable
  procd_open_instance
    command /usr/libexec/adblock-fast-monitor/monitord.uc   # exec'd directly
    respawn 3600 5 5
    file /etc/config/adblock-fast-monitor
  procd_close_instance
stop_service:    logging.uc disable
service_triggers: procd_add_reload_trigger adblock-fast-monitor
```

Daemon startup, in this order:

1. `uloop.init()`, then `ubus.connect()`.
2. `io.pipe()`. Save fd 1 with `io.new(1).dup()`, `dup2` the pipe writer onto
   fd 1, then call
   `uloop.process('/sbin/logread', ['-f', '-e', '^dnsmasq\\['], {}, on_exit)`.
   Restore fd 1 and close the writer.
3. Set `O_NONBLOCK` on the reader and register it with `uloop.handle(reader, cb, uloop.ULOOP_READ)`.
4. `publish('adblock-fast-monitor', methods)`.
5. `uloop.run()`.

Equivalent mechanisms are allowed only if they keep: a string executable, a
known child pid, a nonblocking raw `read(2)` with no stdio `fread`, and child
exit detection.

Exit rules (exit code ≠ 0, so procd respawns):
- logread exits, or the reader returns EOF.
- ubus `publish` or `connect` fails.
- the ubus connection is lost.
- a method handler throws. Handlers **must** wrap their bodies in
  `try/catch`, because an uncaught exception halts uloop in ucode `ubus.c`.

On SIGTERM: libubox uloop cancels `run()`. The daemon sends SIGTERM to the
logread pid and exits 0.

Idle cost: the daemon arms **no timer while the pending map is empty**. The
TTL sweep timer is armed only while there are pending entries, and only for
`pending_ttl` seconds at a time.

### 4.2 Input framing

- Read at most 16 × 4096 bytes per wakeup and split on `\n`.
- Any partial line longer than 1024 bytes (logd `LOG_LINE_SIZE`) is discarded
  up to the next `\n`, and `dropped.input_overflow++`.
- If more than 64 KiB is buffered, all of it is discarded, and
  `dropped.input_overflow++`.

### 4.3 Line grammar (POSIX ERE, as ucode `regexp`)

The output of logread follows `logread.c` L209: `ctime` (24 characters),
then a space, `facility.prio`, a space, and the message. The message keeps the
`dnsmasq[pid]: ` tag, because logd strips only `<prio>` and the 16-character
syslog timestamp (`syslog.c` L174-186).

```
PREFIX = ^[A-Z][a-z]{2} [A-Z][a-z]{2} [ 0-9][0-9] [0-9]{2}:[0-9]{2}:[0-9]{2} [0-9]{4} [a-z0-9]+\.[a-z]+ dnsmasq\[([0-9]+)\]: (.*)$
BODY   = ^(TCP |UDP )?([0-9]+) ([^ /]+)/([0-9]+) ([^ ]+) ([a-z0-9_.-]+) (from|is|to) ([^ ]+)( \([^()]*\))?$
LOST   = ^overflow: ([0-9]+) log entries lost$
```

`BODY` groups, in order: `proto`, `serial`, `client`, `port`, `source`, `name`,
`verb`, `answer`, `extra`. dnsmasq lower-cases names and replaces names that
contain non-printable characters with `<name unprintable>` (`cache.c`
L2014-2030). `BODY` therefore rejects that placeholder, uppercase, spaces and
injected tokens. A label like `victim.com is 0.0.0.0.x` leaves trailing tokens,
so the anchored `$` fails.

`parse_line` returns `null` and `counters.rejected_lines++` for any line that
matches `PREFIX` but neither `BODY` nor `LOST`. Lines that don't match
`PREFIX` are ignored silently. A `LOST` match adds its count to
`dropped.dnsmasq_reported`.

`parse_line` returns
`{pid, serial, client, port, source, name, verb, answer}` with integers for
`pid`, `serial` and `port`. The correlation key is `pid + ':' + serial`,
because serials are per dnsmasq instance.

Real line shapes follow the format `"%s%u %s/%u %s %s%s%s %s%s"`
(`cache.c` L2511). Each example below is prefixed with
`Tue Nov 10 01:09:19 2026 daemon.info dnsmasq[1234]: `:

```
41 192.168.1.10/53211 query[A] ads.example.com from 192.168.1.10
41 192.168.1.10/53211 config ads.example.com is NXDOMAIN            # dnsmasq.servers / dnsmasq.conf block
42 192.168.1.10/53212 query[AAAA] ads.example.com from 192.168.1.10
42 192.168.1.10/53212 /var/run/adblock-fast/dnsmasq.addnhosts ads.example.com is ::   # addnhosts block
43 192.168.1.10/53213 query[A] tracker.example.net from 192.168.1.10
43 192.168.1.10/53213 /var/run/adblock-fast/dnsmasq.addnhosts tracker.example.net is 127.0.0.1
44 192.168.1.10/53214 query[A] www.example.org from 192.168.1.10
44 192.168.1.10/53214 forwarded www.example.org to 1.1.1.1
44 192.168.1.10/53214 reply www.example.org is <CNAME>
44 192.168.1.10/53214 reply cdn.example.org is 93.184.216.34
45 192.168.1.10/53215 query[HTTPS] www.example.org from 192.168.1.10
45 192.168.1.10/53215 cached www.example.org is NODATA-IPv6           # (any cached/cached-stale)
46 192.168.1.10/53216 query[A] router.lan from 192.168.1.10
46 192.168.1.10/53216 /tmp/hosts/dhcp.cfg01411c router.lan is 192.168.1.1
47 fd00::10/40000 query[type=65] x.example.com from fd00::10
47 fd00::10/40000 reply x.example.com is SERVFAIL (EDE: network error)
48 192.168.1.10/53218 reply query is duplicate                        # ignored (forward.c L1490)
overflow: 12 log entries lost
```

### 4.4 Classification (`classify`)

A query starts a pending entry. The **first** terminal line with the same key
decides the outcome. Later lines for that key are ignored, including CNAME
follow-ups. Lines whose key is unknown are counted in
`counters.orphan_lines`. "Local" means the name is single-label, is under
`arpa`, is `localhost`, or equals or is under a dhcp `domain` value or a
`local` value with its slashes stripped. Those values are read from
`/etc/config/dhcp`, refreshed at most every 300 s, and only lazily when a
`config` line arrives (no timer).

| `source` | `verb` | Condition | Decision | `source` attribution |
|---|---|---|---|---|
| `query[T]` | `from` | `client` ∈ {127.0.0.1, ::1} and `exclude_router=1` | — (entry ignored) | — |
| `query[T]` | `from` | otherwise | start pending (`qtype=T`); `queries++` | — |
| `forwarded` | `to` | | none (not terminal) | — |
| `config` | `is` | name is local | `other` | `local` |
| `config` | `is` | `answer` ∈ {`NXDOMAIN`,`NODATA`,`NODATA-IPv4`,`NODATA-IPv6`,`0.0.0.0`,`::`,`127.0.0.1`} | **`blocked`** | `config` |
| `config` | `is` | any other answer (`address=`, `<CNAME>`) | `other` | `config` |
| `/var/run/adblock-fast/dnsmasq.addnhosts` | `is` | | **`blocked`** | `addnhosts` |
| any other `/…` path | `is` | | `other` | `hosts` |
| `DHCP` | `is` | | `other` | `dhcp` |
| `reply` | `is` | `answer`=`duplicate` | ignore line | — |
| `reply` | `is` | `answer` ∈ {`SERVFAIL`,`REFUSED`,`FORMERR`} or all digits | `other` | `error` |
| `reply` | `is` | otherwise (IP, `<CNAME>`, `<TYPE>`, `NXDOMAIN`, `NODATA*`) | **`allowed`** | `upstream` |
| `cached`, `cached-stale` | `is` | | **`allowed`** | `cache` |
| `auth` | `is` | | `other` | `auth` |
| anything else | | | ignore line | — |

- The answer `not implemented` contains a space, so the line is rejected and
  the entry expires.
- A `blocked` decision with source `config` means "dnsmasq answered from local
  configuration". That includes adblock-fast's `server=/x/` and `local=/x/`
  lines and any user `address=/x/0.0.0.0`.
- Decisions are only meaningful when adblock-fast's `dns` is one of
  `dnsmasq.servers`, `dnsmasq.addnhosts` or `dnsmasq.conf`. In the `ipset` and
  `nftset` modes, blocking happens in the firewall, so the reason
  `dns-mode-unsupported` is raised (§4.6).

### 4.5 Bounded structures and counters

All time values are Unix epoch **seconds**, as integers.

| Structure | Bound | Policy |
|---|---|---|
| pending map, `{key → {name, qtype, client, t}}` | `pending_size` | When full, insertion evicts the oldest entry (`dropped.pending_evicted++`). An entry older than `pending_ttl` is removed with `expired++`. |
| recent LRU, `{domain → row}` | `recent_size` | The decided domain moves to the newest position. When full, the least recently seen entry is evicted. **Deduplicated by query name**: A, AAAA and HTTPS lookups update one row. |
| `top_blocked`, `top_allowed` | `top_size` each | Space-Saving: a new key arriving at a full map replaces the minimum entry with `count=min+1, error=min`. |
| per-row `qtypes` | 8 | Set of distinct `qtype` strings. Excess types are dropped. |

The recent row is the item type of `domains` (§4.6):
`{domain, decision, source, count, blocked, allowed, first_seen, last_seen, qtypes, client?}`.
`decision` and `source` hold the **last** outcome. `count` covers every
decided query, while `blocked` and `allowed` count only their own decisions.
`client` is present only when `record_clients=1`.

Counters are monotonic since `stats_since`.

```
queries            accepted query lines (router queries excluded when exclude_router=1)
blocked, allowed, other   decided outcomes
expired            pending entries removed by TTL (no classifiable answer)
pending            current pending map size (gauge)
dropped.input_overflow    reader discards (§4.2)
dropped.pending_evicted   pending entries evicted when the map was full
dropped.dnsmasq_reported  sum of "overflow: N log entries lost"
rejected_lines, orphan_lines   diagnostics
```

Invariant: `queries = blocked + allowed + other + expired + pending + dropped.pending_evicted`.

`block_pct = round(1000·blocked/(blocked+allowed))/10`, or `null` when the
denominator is 0. "True drops" are the three `dropped.*` counters only.
Normal LRU eviction is **not** a drop.

### 4.6 ubus object `adblock-fast-monitor`

Errors use one shape across both objects:
`{"api":1,"ok":false,"error":{"code":"<code>","message":"<text>"}}`, with
ubus status 0. Any unknown request field is ignored. A field with the wrong
type gives `invalid-argument`.

#### `status` (read)

Request `{}`. Response:

```json
{ "api":1, "ok":true,
  "state":"running",                       // "running" | "degraded"
  "reasons":[],                            // degraded reasons, see below
  "daemon":{"pid":2101,"started_at":1762747000,"now":1762747359,"stats_since":1762747000,"purged_at":null},
  "counters":{"queries":1200,"blocked":180,"allowed":990,"other":20,"expired":4,"pending":6,
              "dropped":{"input_overflow":0,"pending_evicted":0,"dnsmasq_reported":0},
              "rejected_lines":0,"orphan_lines":3},
  "block_pct":15.4,
  "last_event_at":1762747358,
  "limits":{"recent_size":500,"top_size":256,"pending_size":512,"pending_ttl":10},
  "adblock_fast":{"dns":"dnsmasq.servers"} }
```

The daemon sets `reasons` (any of these makes `state="degraded"`):

| Code | Raised when |
|---|---|
| `input-overflow` | `dropped.input_overflow` increased in the last 60 s |
| `pending-overflow` | `dropped.pending_evicted` increased in the last 60 s |
| `dnsmasq-log-overflow` | a `LOST` line arrived in the last 60 s |
| `dns-mode-unsupported` | adblock-fast `dns` is not one of `dnsmasq.servers`, `dnsmasq.addnhosts` or `dnsmasq.conf` (UCI is read at start and on every `status` call) |

#### `domains` (read)

Request:

```json
{ "view":"recent",        // "recent" | "top_blocked" | "top_allowed"   (default "recent")
  "decision":"blocked",   // recent only: "blocked" | "allowed" | "other"  (optional)
  "q":"example",          // optional substring, ^[a-z0-9_.-]{1,64}$ (lower-cased first)
  "offset":0,             // int ≥ 0, default 0
  "limit":50 }            // int 1–100, default 50 (clamped)
```

Response for `recent`: items are sorted by `last_seen` descending, then by
`domain` ascending.

```json
{ "api":1,"ok":true,"view":"recent","total":137,"offset":0,"now":1762747359,"stats_since":1762747000,
  "items":[{"domain":"ads.example.com","decision":"blocked","source":"config","count":12,"blocked":12,"allowed":0,
            "first_seen":1762747010,"last_seen":1762747350,"qtypes":["A","AAAA","HTTPS"],"client":"192.168.1.10"}] }
```

For `top_*`, items are `{"domain":"…","count":42,"error":0}`, sorted by
`count` descending, then by `domain` ascending. `total` is the number of
tracked entries that match `q`. Errors: `invalid-argument`.

#### `purge` (write)

Request `{}`. This clears counters, the recent LRU, both top maps and the
pending map. It sets `purged_at = stats_since = now`. It never touches DNS or
adblock-fast. Response:
`{"api":1,"ok":true,"stats_since":1762747400}`.

**Absent object.** When the daemon is not running, uhttpd looks up the object
**before** checking the ACL and returns JSON-RPC error `-32000 "Object not found"`
(`uhttpd ubus.c` L973-979). LuCI's `rpc.js` rejects that call with
`RPCError` carrying `-32000`. The UI maps that error to `object=false`.

---

## 5. Query-logging drop-ins (`logging.uc`, WU1)

- **Targets.** Every `dhcp` section of type `dnsmasq` that has `disabled!=1`,
  filtered by `dnsmasq_instance`. Anonymous sections use their UCI-generated
  names (for example `cfg01411c`).
- **Confdir.** `confdir = uci dhcp.<s>.confdir`, defaulting to
  `/tmp/dnsmasq.<s>.d` (`dnsmasq.init` L1172). Everything from the first `,`
  is cut. The result must be absolute; otherwise the instance is reported as
  `confdir-invalid` and skipped. The file name ends in `.conf` so that common
  conf-dir suffix filters keep it.
- **`enable`.** For each target that does **not** already have
  `dhcp.<s>.logqueries=1`, write `<confdir>/adblock-fast-monitor.conf`
  atomically (tmp + rename, 0644), creating the confdir 0755 if needed.
  Remove drop-ins for instances that are no longer targeted.
- **`disable`.** Remove every `*/adblock-fast-monitor.conf` under the confdirs
  of **all** dnsmasq sections.
- **Restart.** If the set of drop-in files changed **and** `ubus call service list '{"name":"dnsmasq"}'`
  shows a running instance, run `/etc/init.d/dnsmasq restart` exactly once.
  At boot (`START=18` < dnsmasq `19`) dnsmasq is not running yet, so nothing
  restarts.
- **Ownership.** The drop-in's existence is the ownership record. It lives on
  tmpfs, so it disappears at reboot together with its effect. `/etc/config/dhcp`
  is never written.
- **`status`** prints JSON
  `{"instances":[{"section":"cfg01411c","confdir":"/tmp/dnsmasq.cfg01411c.d","dropin":true,"uci_logqueries":false,"running":true}]}`.
  The plugin's `info` method reproduces this through `abfm.system`.

---

## 6. Actions backend — rpcd ucode plugin `luci.adblock-fast-monitor` (WU2)

rpcd loads plugins once at startup from `/usr/share/rpcd/ucode/`. The plugin
runs **inside rpcd's single-threaded uloop**, so every method must return or
defer within **200 ms**. Long work (file scans, DNS, adblock-fast) goes to a
child process or the job. For `rules.listed`, the call may be deferred
(`req.defer()` and `req.reply()`), with the scan running in a fork+exec'd
`grep` read through a non-blocking pipe (not a `uloop.task`, whose
long-lived fork shares rpcd's pages copy-on-write); on a 10 s timeout,
`listed` is `null`. Plugin regexes avoid bounded repetition (`{m,n}`): musl
expands it into an automaton that costs milliseconds per match.

rpcd validates arguments against each method's declared signature before
the plugin runs: an undeclared field or a field of the wrong JSON type is
answered with ubus status `UBUS_STATUS_INVALID_ARGUMENT` (2), not with a
JSON error. Declared fields: `info {}`, `rules {domains: array}`,
`apply {ops: array, confirm_rebuild: bool, rebuild: bool, dry_run: bool}`,
`job {job_id: string}`.

### 6.1 `info` (read)

Request `{}`. All values are cheap UCI reads, `stat` calls and one ubus
`service list` call. Response:

```json
{ "api":1,"ok":true,
  "monitor":{"enabled":true,"manage_logging":true,"poll_interval":5,
             "service":{"running":true,"pid":2101},"object":true},
  "adblock_fast":{"installed":true,"enabled":true,"status":"statusSuccess",
                  "dns":"dnsmasq.servers","output_file":"/var/run/adblock-fast/dnsmasq.servers",
                  "output_exists":true,"external_config":false,"pending_uci_changes":false},
  "dnsmasq":{"running":true,"instances":[{"section":"cfg01411c","confdir":"/tmp/dnsmasq.cfg01411c.d",
             "dropin":true,"uci_logqueries":false,"logfacility_file":false}]},
  "warnings":["query-logging-active"] }
```

Field sources:
- `adblock_fast.installed`: `/etc/init.d/adblock-fast` and
  `/etc/config/adblock-fast` both exist.
- `adblock_fast.status`: from `service list` data, or `null`.
- `output_file`: from the `dns` mode (§10).
- `external_config`: `dnsmasq_config_file_url` is non-empty.
- `pending_uci_changes`: `/tmp/.uci/adblock-fast` holds a delta other than
  `adblock-fast.<section>.size='N'`. adblock-fast itself saves (without
  committing) every `file_url` size after each download when
  `update_config_sizes=1` (the default); that bookkeeping is ignored.
- `dnsmasq.instances[]` lists every `dnsmasq` section with `disabled≠1`;
  `confdir` is `null` when invalid (`confdir-invalid`), and `targeted` tells
  whether `dnsmasq_instance` selects it.

| `warnings` code | Condition |
|---|---|
| `query-logging-active` | at least one drop-in exists, or `uci_logqueries` is set (logd ring floods; informational) |
| `logd-to-flash` | `system.@system[0].log_file` is set |
| `logd-remote` | `system.@system[0].log_ip` is set |

**Logging-unavailable reasons.** The UI derives these from `info` (§8.1):
- `dnsmasq-not-running`
- `dnsmasq-logs-to-file`: `dhcp.<s>.logfacility` contains `/`
- `logging-not-active`: no targeted instance has `dropin` or `uci_logqueries`
- `confdir-invalid`

### 6.2 `rules` (read)

Request: `{"domains":["ads.example.com","www.example.org"]}`. The list is
optional and limited to **50** entries; each entry is normalized like `apply`
items (§6.4). Response:

```json
{ "api":1,"ok":true,
  "allowed_domain":["cdn.jsdelivr.net"], "blocked_domain":["ads.example.com"],
  "truncated":false,                       // each list capped at 2048 entries
  "domains":{
    "ads.example.com":{"manual":"block","manual_parent":null,"listed":true,"effective":"blocked",
                       "actions":["allow","unblock"]},
    "www.example.org":{"manual":null,"manual_parent":null,"listed":false,"effective":"allowed",
                       "actions":["block"]} } }
```

Per-domain fields:
- **`manual`**: `"allow"` or `"block"` when the exact name is in
  `allowed_domain` or `blocked_domain`, otherwise `null`.
- **`manual_parent`**: the nearest parent entry in either list, as
  `{"list":"allow"|"block","domain":"…"}`, or `null`.
- **`listed`** (whether adblock-fast's active output blocks the name): `true`,
  `false`, or `null` when unknown or the scan timed out. It is evaluated by
  `dns` mode:
  - `dnsmasq.servers` and `dnsmasq.conf`: the longest matching suffix line
    (`server=/S/` or `local=/S/`) is a block line, not `server=/S/#`.
  - `dnsmasq.addnhosts`: an exact `127.0.0.1 D` or `:: D` line exists.
  - other modes: `null`.

  Results are cached in plugin memory per output-file
  `(dev, ino, size, mtime)` (LRU of 512 names). One scan per call, whatever
  the number of domains.
- **`effective`**:
  - `"blocked"` if `listed=true`.
  - `"allowed"` if `listed=false` or `manual="allow"`.
  - `"unknown"` otherwise.
- **`actions`**, in this order:
  - `allow` if `effective≠"allowed"`;
  - `unblock` if `manual="block"`;
  - `block` if `effective≠"blocked"`;
  - `unallow` if `manual="allow"`.

  The UI renders only these actions.

### 6.3 `apply` (write)

Request:

```json
{ "ops":[{"op":"allow","domain":"ads.example.com"},{"op":"block","domain":"tracker.example.net"}],
  "confirm_rebuild":false,   // must be true when mode=rebuild
  "rebuild":false,           // true + ops:[] = run one rebuild for already-persisted UCI
  "dry_run":false }
```

Pipeline. The call is all-or-nothing, and it rejects at the first failing
step.

1. Shape check (`invalid-request`): 0–64 ops (`batch-too-large`).
   `ops:[]` without `rebuild:true` gives `batch-empty`.
2. Each op is normalized and validated (§6.4–6.5). The error carries `index`
   and `domain`.
3. Duplicate identical ops collapse. Two different ops for one domain give
   `conflict`.
4. Preconditions:
   - `adblock-fast-missing`;
   - `external-config` (`dnsmasq_config_file_url` is set);
   - `unsupported-dns-mode` (`dns` is `smartdns.*` or `unbound.*`);
   - `pending-uci-changes` (the user has unsaved LuCI changes for
     adblock-fast; adblock-fast's own `allow` would commit them).
5. `plan()` (§6.6) produces `effective_op`, `change` and `mode`.
   A `block` whose name equals, or falls under, an `allowed_domain` entry that
   stays after the batch gives `allow-overrides`, because the rebuild removes
   allowed names after it adds blocks (adblock-fast.uc L2005-2030).
6. If `mode="rebuild"` and `confirm_rebuild≠true`, the response is
   `{"ok":false,"error":{"code":"confirm-required",…},"mode":"rebuild","plan":[…]}`.
7. `dry_run:true` stops here and returns the plan with `ok:true`.
8. Take the lock with `xn`. If that fails, or the queued window of §7.3
   applies, return `busy` with `job_id`.
9. Still under the lock, open a UCI cursor with savedir
   `/var/run/adblock-fast-monitor/uci`. Apply each `change` with exact
   `list_append` or `list_remove` on `adblock-fast.config.allowed_domain` or
   `blocked_domain`, then `commit('adblock-fast')`. The ucode `uci` module
   commit emits **no** procd `config.change`, so adblock-fast's reload trigger
   doesn't fire. On failure: `uci-error`.
10. Write `job.json` with `state:"queued"` and release the lock.
11. Spawn
    `setsid /usr/libexec/adblock-fast-monitor/job.uc <job_id> </dev/null >/dev/null 2>&1 &`
    via `system()` (`setsid` when present). The job closes the sockets,
    pipes and epoll descriptors it inherits from rpcd before doing anything. On failure, the error is `spawn-failed` with
    `persisted:true`.

If every op is a `noop` and `rebuild` is false, the response is
`{"ok":true,"noop":true,"job_id":null,"plan":[…]}` and no job starts.

Success response:

```json
{ "api":1,"ok":true,"job_id":"j1762747400-3f2a","state":"queued","mode":"rebuild","may_escalate":false,
  "plan":[{"op":"allow","domain":"ads.example.com","effective_op":"allow","change":["allow:add","block:remove"]},
          {"op":"unblock","domain":"x.example.com","effective_op":"allow","change":["allow:add"]}] }
```

`change` lists the UCI mutations: `allow:add`, `allow:remove`, `block:add`
and `block:remove`. An empty list means noop. `may_escalate` is reserved for
`fast-allow` and is always `false` in v1 (§6.6).

Error codes: `invalid-request`, `batch-empty`, `batch-too-large`,
`invalid-domain`, `protected-domain`, `public-suffix`, `conflict`,
`allow-overrides`, `adblock-fast-missing`, `external-config`,
`unsupported-dns-mode`, `pending-uci-changes`, `confirm-required`, `busy`,
`uci-error`, `spawn-failed`.

### 6.4 Domain grammar and normalization (`abfm.domain`)

Normalization:
1. trim the input;
2. lower-case it;
3. strip **one** trailing `.`.

Valid when all of these hold:
- total length ≤ 253;
- 2–127 labels;
- each label 1–63 characters from `[a-z0-9_-]`, not starting or ending with
  `-`. Underscores are allowed anywhere, for `_dmarc` and SRV labels;
- the last label is not all digits, which rejects IPv4 literals;
- no `*`, `/`, `:` or spaces;
- Unicode only as `xn--` punycode.

Anything else is `invalid-domain`.

### 6.5 Protected domains and the public-suffix guard (no PSL file)

`protected-domain` (block, unallow):
- the name equals or falls under: `localhost`, `arpa`, `local`, `internal`,
  `home.arpa`, the dhcp `domain` and `local` values, the system hostname, or
  adblock-fast's `heartbeat_domain` (a blocked heartbeat fails adblock-fast's
  restart check);
- or it is the host of any enabled `file_url.url` or of `config_update_url`
  (blocking those breaks list downloads).

`public-suffix` (all ops). The name is rejected when any of these holds:
- (a) it has fewer than 2 labels (already excluded by §6.4);
- (b) it has exactly 2 labels and the first is one of
  `ac co com edu gob gouv gov gv go govt ltd mil net nic nom or org plc sch ne int mod`
  (this covers `co.uk`, `com.au`, `ac.jp` and similar);
- (c) it equals an entry of the embedded list `ABFM_PRIVATE_SUFFIXES_V1`:
  `github.io gitlab.io blogspot.com appspot.com herokuapp.com cloudfront.net amazonaws.com s3.amazonaws.com azurewebsites.net azureedge.net cloudapp.net trafficmanager.net windows.net pages.dev workers.dev vercel.app netlify.app firebaseapp.com web.app duckdns.org dyndns.org no-ip.org ddns.net myqnapcloud.com synology.me fastly.net akamaized.net edgekey.net edgesuite.net googleusercontent.com fbcdn.net cdn.cloudflare.net r2.dev ngrok.io ngrok-free.app onrender.com fly.dev`.

Changing the list requires a contract change. This is a guard against
catastrophic over-broad rules, not a full PSL check. Known limitation: a
3-label ccTLD suffix that is not listed (for example `pvt.k12.ma.us`) passes.

### 6.6 Plan, operation semantics and mode selection

Let `A` be the current `allowed_domain`, `B` the current `blocked_domain`, and
`D` the domain. Membership is exact.

| op | `effective_op` | UCI change |
|---|---|---|
| `allow` | `allow` | `D∉A` → `allow:add`; `D∈B` → `block:remove` |
| `unblock` | `D∈B` → `unblock`; otherwise **`allow`** (the domain comes from a downloaded list or a parent rule) | `D∈B`: `block:remove`. Otherwise as `allow`. |
| `block` | `block` | `D∈A` → `allow:remove`; `D∉B` → `block:add` |
| `unallow` | `unallow` | `D∈A` → `allow:remove`; otherwise noop |

Mode:
- **`persist-only`**: adblock-fast `enabled≠1`. UCI is written and there is
  no runtime step.
- **`fast-allow`**: reserved; v1 never selects it. adblock-fast 1.2.4-r4's
  `allow` does not remove the blocking line, deletes unrelated lines and
  clears the service status (§10, §14.1), so there is no correct fast path
  that only uses adblock-fast.
- **`rebuild`**: every other batch with at least one change, and
  `rebuild:true`. The UI must obtain explicit confirmation:
  "downloads all lists over WAN, restarts DNS, may take minutes". The user
  stages many changes and pays for one rebuild per Apply.

---

## 7. Job (`job.uc`, WU2)

### 7.1 `job` (read)

Request: `{"job_id":"j1762747400-3f2a"}`. The ID is optional; omitting it
means the latest job. A non-matching ID gives `not-found`. Response:

```json
{ "api":1,"ok":true,"job":{
  "id":"j1762747400-3f2a",            // ^j[0-9]{10}-[0-9a-f]{4}$
  "state":"verifying",                 // queued|applying|verifying|applied|partial|failed
  "mode":"rebuild",                    // rebuild|persist-only (fast-allow reserved)
  "phase":"verify",                    // null|uci|allow|rebuild|verify
  "created_at":1762747400,"started_at":1762747400,"finished_at":null,
  "persisted":true,                    // UCI committed by apply
  "escalated":false,                   // reserved for fast-allow; always false in v1
  "adblock_fast_status":"statusSuccess",
  "error":null,                        // or {"code":"…","message":"…"}
  "items":[{"op":"allow","domain":"ads.example.com","effective_op":"allow","change":["allow:add"],
            "expect":"allowed","result":"ok","observed":"allowed",
            "answer":{"rcode":"NOERROR","a":["93.184.216.34"],"aaaa":[]},"reason":null}] } }
```

`job` is `null` when no job has run since boot.

`items[].expect`:
- `allow` and `unblock` → `"allowed"`;
- `block` → `"blocked"`;
- `unallow` → `"any"`, with the observed state reported only.

`items[].result`:
- `pending`: not verified yet;
- `ok`: observed matches the expectation, or the op was a noop;
- `mismatch`: the expectation failed (for example
  `reason:"parent-blocked"` when a parent list entry still blocks a
  `dnsmasq.conf`/`addnhosts` name);
- `unverified`: DNS gave `SERVFAIL`/`TIMEOUT`, or the mode is
  `ipset`/`nftset`;
- `skipped`: `persist-only`.

`reason` (string or `null`):
- `parent-blocked`: a parent entry still blocks the name, for example under
  `dnsmasq.conf` or `addnhosts`;
- `still-listed`: after `unblock`, a downloaded list still blocks the name,
  and the UI offers `allow`;
- `not-blocked`: after `block`, the name still resolves;
- `dns-error`: `SERVFAIL`, `TIMEOUT` or `REFUSED`;
- `dns-mode-unsupported`: the mode is `ipset` or `nftset`.

### 7.2 Execution

1. Acquire the lock (§7.3), retrying `xn` for up to 10 s. On failure:
   `failed`, `lock-failed`. A job whose `job.json` no longer holds its id in
   state `queued` exits without changes.
2. Set `state="applying"`.
3. Run the runtime step for the mode:
   - **`rebuild`**: wait while another adblock-fast CLI run
     (`/lib/adblock-fast/cli.uc`, e.g. one orphaned by a killed job) is
     still working (at most 15 min), then run `/etc/init.d/adblock-fast dl`
     with `phase="rebuild"`.
     There is **no timeout** (BusyBox `timeout` is off, and a half-built list
     is worse). Success means status `statusSuccess`, an empty
     `data.errors` (adblock-fast reports `statusSuccess` with
     `errorDownloadingList` when a list server is down but manual
     `blocked_domain` entries exist) and the output file exists. Otherwise:
     `failed`, `rebuild-failed`, with the status and error codes in the
     message. UCI stays persisted; there is no rollback. The UI offers "Run
     rebuild", which is `apply{ops:[],rebuild:true,confirm_rebuild:true}`.
   - **`persist-only`**: skip; set item results to `skipped`, then
     `applied`.
4. `state="verifying"`, `phase="verify"`. One `resolv.query(domains, {type:['A','AAAA'], nameserver:['127.0.0.1'], timeout:3000, retries:1})`.
   `observed`:
   - `blocked`: some A or AAAA value is in {0.0.0.0, 127.0.0.1, ::}, or the
     rcode is NXDOMAIN or NOERROR-empty **and** `rules.listed=true`;
   - `allowed`: a non-sinkhole A, AAAA or CNAME, or NXDOMAIN with
     `listed=false`;
   - `unknown`: anything else.

   dnsmasq was restarted by the runtime step, so its cache is empty.
   `exclude_router` keeps these lookups out of the statistics.
5. Terminal state:
   - `applied`: every item is `ok` or `skipped`;
   - `partial`: anything else short of a failure;
   - `failed`: `error` is set.

Then release the lock.

Job error codes: `lock-failed`, `rebuild-failed`, `interrupted`,
`start-timeout`; `rebuild-required` and `allow-failed` are reserved for
`fast-allow`.

### 7.3 Lock and busy semantics

- Lock: `fs.open('/var/lock/adblock-fast-monitor.lock','ae')` (`O_CLOEXEC`,
  so adblock-fast's children never inherit it) and `.lock('xn')` (`flock`).
  The kernel releases it when the holder dies, so a stale lock cannot exist.
- `apply` holds the lock only for steps 8–10.
- `busy` when either:
  - the lock can't be taken; or
  - `job.json.state="queued"` and `now - created_at < 30`. This covers the
    spawn hand-off window, during which rpcd processes calls serially.
- When `job` reads a non-terminal state while the lock is free, it reports
  the job as failed:
  - `start-timeout` if the state is `queued` and older than 30 s;
  - `interrupted` if the state is `applying` or `verifying`.

  It persists that failure.

### 7.4 State machine

```
(none) --apply--> queued --job acquires lock--> applying --runtime ok--> verifying --> applied | partial
                    |                              \--error--> failed{rebuild-failed|lock-failed}
                    \--not started 30 s--> failed{start-timeout}      applying|verifying --holder died--> failed{interrupted}
```

`job.json` lives on tmpfs, so after a reboot `job` returns `null`. UCI
changes persist.

---

## 8. LuCI UI (WU3)

### 8.1 UI states (`model.deriveState(uciEnabled, info, statusResult, now)`)

The first matching row wins:

| State | Condition | UI |
|---|---|---|
| `access-denied` | `info` rejects with `-32002` | message only |
| `adblock-fast-missing` | `info.adblock_fast.installed=false` | error; no actions |
| `disabled` | UCI `enabled≠1` | "Monitoring is off", link to Settings; actions still available |
| `starting` | enabled, `info.monitor.service.running`, status call gave `-32000`, less than 15 s since the first such observation | spinner |
| `not-running` | enabled, status gave `-32000`, and (not `service.running` or 15 s elapsed) | error with hint (`logread -e adblock-fast-monitor`) |
| `logging-unavailable(reason)` | object present and one of: `!info.dnsmasq.running` → `dnsmasq-not-running`; an instance with `logfacility_file` → `dnsmasq-logs-to-file`; no instance with `dropin` or `uci_logqueries` → `logging-not-active` | warning; stats shown greyed |
| `degraded(reasons)` | `status.state="degraded"` | warning listing `status.reasons` |
| `healthy` | otherwise | normal |
| *overlay* `stale` | last successful `status` older than 3 × `poll_interval` | keep the last data, marked "stale since …" |

`info.warnings` render as dismissible notes in any state. Every timestamp is
shown in local time, and durations are humanized.

### 8.2 Staging (client-side only)

- `localStorage["adblock-fast-monitor.pending.v1"] = {"v":1,"items":[{"op":"allow","domain":"…","ts":1762747400}]}`,
  at most 64 items.
- Adding an op for D replaces any pending op for D. Adding the inverse of a
  pending op (allow↔unallow, block↔unblock) removes it.
- Domains are normalized as in §6.4 before they are stored.
- **Apply.**
  1. `apply{dry_run:true}`. If the mode is `rebuild` or `may_escalate`, show a
     `ui.showModal` confirmation that names the cost.
  2. `apply` with `confirm_rebuild` set from that confirmation.
  3. When it returns `queued`, move the items to `inflight{job_id}`.
  4. Poll `job` every 2 s until it is terminal.
  5. Items with `ok`, `skipped` or noop leave the list. `mismatch`,
     `unverified` and failed items return to pending with their reason.
  6. `busy` → show the current job.
- **Discard** clears the pending list.
- Write controls (row actions, Apply, Purge) are not rendered when
  `!L.hasViewPermission()` (luci.js L3259).

### 8.3 Data calls

| Call | Cadence |
|---|---|
| `status`, `domains` | every `poll_interval` s while `document.visibilityState=="visible"` |
| `info` | at load and every 30 s |
| `rules` | for the visible rows (≤ 50) when the page or filter changes |
| `job` | 2 s while non-terminal |

Rules:
- At most one request of each kind may be in flight.
- A filter change cancels the pending refresh and refetches immediately.
- The live region announces state changes only, not refresh ticks.
- All dynamic text goes through `E()` and text nodes, never `innerHTML`.
- Views must `'require rpc'`, `'require uci'`, `'require ui'`, `'require form'`
  and `'require view'` explicitly.

---

## 9. ACL `/usr/share/rpcd/acl.d/luci-app-adblock-fast-monitor.json`

```json
{
  "luci-app-adblock-fast-monitor": {
    "description": "Grant access to Adblock Fast Monitor",
    "read": {
      "ubus": {
        "adblock-fast-monitor": [ "status", "domains" ],
        "luci.adblock-fast-monitor": [ "info", "rules", "job" ]
      },
      "uci": [ "adblock-fast-monitor", "adblock-fast" ]
    },
    "write": {
      "ubus": {
        "adblock-fast-monitor": [ "purge" ],
        "luci.adblock-fast-monitor": [ "apply" ]
      },
      "uci": [ "adblock-fast-monitor" ]
    }
  }
}
```

rpcd checks `uci get` against the `read` grant specifically. Writes to
adblock-fast's UCI happen only through `apply`, never through a LuCI `uci`
write grant.

---

## 10. adblock-fast facts this contract relies on (1.2.4-r4)

| Item | Value |
|---|---|
| UCI | `adblock-fast.config`: `enabled`, `dns`, `allowed_domain` (list), `blocked_domain` (list), `dnsmasq_config_file_url`, `heartbeat_domain`, `config_update_url`, `file_url` sections (`url`, `enabled`, `action`) |
| Output file by `dns` | `dnsmasq.servers` → `/var/run/adblock-fast/dnsmasq.servers` (`server=/D/`, allow `server=/D/#`); `dnsmasq.addnhosts` → `/var/run/adblock-fast/dnsmasq.addnhosts` (`127.0.0.1 D`, `:: D`); `dnsmasq.conf`/`ipset`/`nftset` → `/var/run/adblock-fast/adblock-fast.dnsmasq` (`local=/D/`, `ipset=/D/adb`, `nftset=/D/4#inet#fw4#adb4…`) |
| `allow` fast path | **defective, not used** (§14.1). Requires the output file; refuses with an external config; for each D runs `sed -i '\:/\(/D\|.D\):d'`, appends `server=/D/#` in servers mode, adds `allowed_domain`, commits, refreshes the `/dev/shm` config cache, restarts the resolver once and then publishes an empty `status` to procd. Its exit code is not meaningful. |
| `update_config_sizes` | default `1`: after a download adblock-fast `save`s (never commits) each `file_url`'s `size`, leaving a delta in `/tmp/.uci/adblock-fast` (§6.1). |
| Rebuild | any change to `allowed_domain` or `blocked_domain` makes `start` choose `download`; `dl` forces it. Allowed names are removed with `/(^|\.)D$/d` **after** blocked names are appended. |
| Status | `ubus call service list '{"name":"adblock-fast"}'` → `.adblock-fast.data.status` (`statusSuccess`, `statusFail`, …) and `.data.errors[].code`; a download failure of one list still ends `statusSuccess` with `errorDownloadingList` when the output file could be built |
| `heartbeat_domain` | `-` does **not** disable the heartbeat (it falls back to the default `heartbeat.mossdef.org`); the heartbeat must resolve within `heartbeat_sleep_timeout` or the start fails |
| Trigger | the init registers `config.change` → `reload`. The ucode `uci` commit does not emit it, while LuCI `uci.apply` does. |

---

## 11. Performance budgets (placeholders — WU6 owns the numbers)

| ID | Metric | Budget |
|---|---|---|
| P1 | processes and RSS with `enabled=0` | 0 extra processes (**hard**) |
| P2 | daemon + logread PSS, idle and at the `recent_size=2000` cap | TBD MiB |
| P3 | idle wakeups of the daemon with no DNS traffic, over 60 s | 0 timer wakeups (**hard**); TBD total |
| P4 | daemon CPU at 50 and 200 qps of real queries | TBD % |
| P5 | DNS p95 latency delta, on vs off, same load | within noise, TBD ms |
| P6 | logd, dnsmasq and rpcd CPU/RSS deltas, on vs off | TBD |
| P7 | `status` / `domains` handler time at full tables | TBD ms |
| P8 | `apply` return time (rpcd blocking) | ≤ 200 ms (**hard**) |
| P9 | `rules` time to the deferred reply on a 100k-line output file | TBD s; rpcd never blocked > 200 ms |
| P10 | dnsmasq restarts caused by the monitor (boot, enable, settings save) | 0 / 1 / 0 (**hard**) |

---

## 12. Upstream facts (verified 2026-11-10)

- ucode pin: `PKG_SOURCE_VERSION:=85922056ef7a…` —
  https://raw.githubusercontent.com/openwrt/openwrt/openwrt-25.12/package/utils/ucode/Makefile.
  The same file packages the `ucode-mod-io`, `ucode-mod-resolv` and
  `ucode-mod-uloop` modules.
- `uloop.process` accepts only a **string** executable (`lib/uloop.c` L1012)
  and does not capture stdout. `process.delete()` does not kill the child —
  https://github.com/jow-/ucode/blob/85922056/lib/uloop.c
- `conn.publish(name, {m:{args,call}})` exists (`lib/ubus.c` L1889).
  Returning an object replies, returning an integer sets the ubus status, and
  any exception other than `exit` halts uloop (L1574-1632) —
  https://github.com/jow-/ucode/blob/85922056/lib/ubus.c
- `io.pipe`, `io.new`, `dup2`, and `read` (a raw `read(2)`) exist
  (`lib/io.c` L501, L772, L1124, L1249). `fs.file#lock` is `flock` with
  `s`/`x`/`n`/`u` (`lib/fs.c` L849). `resolv.query(names,{type,nameserver,timeout,retries})`
  returns `{name:{A:[],AAAA:[],rcode}}` (`lib/resolv.c`) —
  https://github.com/jow-/ucode/tree/85922056/lib
- `luci-base` depends on `+rpcd +rpcd-mod-ucode +ucode +ucode-mod-fs +ucode-mod-uci +ucode-mod-ubus …` —
  https://raw.githubusercontent.com/openwrt/luci/openwrt-25.12/modules/luci-base/Makefile.
  The `luci.mk` postinst clears caches and runs `rpcd reload` (L238-240).
  `L.hasViewPermission()` is at luci.js L3259.
- rpcd `d99f703`: ucode plugins come from `/usr/share/rpcd/ucode`, are loaded
  once at init, and world-writable scripts are skipped (`ucode.c` L35,
  L1087-1100). Requests can `defer`, `reply` and `error`. SIGHUP re-execs
  rpcd (`main.c` L44, L66) —
  https://github.com/openwrt/rpcd/blob/d99f703e4035d03fbcfbada3cb697db346c2b984/ucode.c
- uhttpd `93b05e0` `ubus.c`: the object lookup comes before the ACL check, so
  a missing object gives `-32000 Object not found` and a denied call gives
  `-32002 Access denied` (L120-122, L973-979) —
  https://github.com/openwrt/uhttpd/blob/93b05e0b65d91c23c5aa8fdde378df1f174ec71d/ubus.c
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
  https://github.com/1g4-mirror/dnsmasq/tree/v2.93/src (upstream gitweb
  requires interactive login for automated clients).
- `dnsmasq.init` (openwrt-25.12): `START=19` (L4);
  `logqueries` → `--log-queries=extra` (L990); `logfacility` (L1026);
  conf-dir `confdir` defaulting to `/tmp/dnsmasq${cfg:+.$cfg}.d`, created if
  missing (L1172-1178) —
  https://raw.githubusercontent.com/openwrt/openwrt/openwrt-25.12/package/network/services/dnsmasq/files/dnsmasq.init
- ubox `6f78fa4`:
  - `logread -e` compiles a **BRE** (`regcomp` without `REG_EXTENDED`) and
    matches it against the message, which includes the `dnsmasq[pid]:` tag
    (`log/logread.c` L160, L363);
  - output format at L209;
  - logd strips `<prio>` and the 16-character timestamp (`log/syslog.c`
    L174-186);
  - `LOG_LINE_SIZE` is 1024 (`log/syslog.h`).

  https://github.com/openwrt/ubox/tree/6f78fa496bf36c55864a41e353df7d13f04b1077/log
- adblock-fast 1.2.4-r4 (openwrt-25.12 `net/adblock-fast`): `dns_modes` and
  sinkholes (`files/lib/adblock-fast/adblock-fast.uc` L35-78), triggers (L28,
  L1032), `enabled` check (L1075), rebuild allow removal (L2020), and
  `allow()` (L2661-2725). UCI schema in `files/etc/init.d/adblock-fast`
  `load_validate_config` —
  https://github.com/openwrt/packages/tree/openwrt-25.12/net/adblock-fast/files
- BusyBox defaults (openwrt-25.12 `package/utils/busybox/Config-defaults.in`):
  `STAT n`, `TIMEOUT n`; `FLOCK`, `SETSID`, `KILL`, `GREP`, `AWK` and
  `NSLOOKUP` are `y`.

---

## 13. Test obligations

Every test must **execute** behaviour. Source-regex and doc-regex tests are
not accepted and are deleted (WU5).

Environments:
- **U**: a ucode interpreter built on the CI host at pin `85922056`, loading
  the real `abfm.*` modules.
- **G**: an OpenWrt 25.12.6 QEMU guest with the installed APK, real dnsmasq
  and real adblock-fast, served deterministic local list fixtures.
- **B**: Playwright against LuCI on G.

| ID | Contract item | Test (must assert) | Env | Owner |
|---|---|---|---|---|
| T01 | §4.3 grammar | every example line parses to the expected fields; `LOST` adds its count | U | WU1 |
| T02 | §4.3 rejection | spoofed labels, `<name unprintable>`, extra tokens, uppercase and `not implemented` → `null` + `rejected_lines` | U | WU1 |
| T03 | §4.4 table | each table row → decision/source; local-name exclusions; `duplicate` ignored; first-terminal-wins with CNAME | U | WU1 |
| T04 | §4.5 bounds | pending eviction and TTL (`expired`), the counter invariant, LRU dedup across A/AAAA/HTTPS, Space-Saving count/error, `block_pct` null | U | WU1 |
| T05 | §4.6 `domains` | views, filter, `q` validation, paging, sort order, `limit` clamp, `client` only with `record_clients=1` | U+G | WU1 |
| T06 | D1, §4.1 | `enabled=0` → no process, no object, no drop-in. Enable → exactly 1 ucode + 1 logread; the object appears | G | WU1 |
| T07 | §4.1 exit | killing logread → daemon exits ≠ 0 → procd respawns → object back; stop/restart leaves no orphan logread | G | WU1 |
| T08 | §5, P10 | the enable/disable drop-in set is correct; dnsmasq pid changes exactly once when the set changes, never on a settings-only save, never at boot; `/etc/config/dhcp` stays byte-identical | G | WU1 |
| T09 | §4.4 live | real queries from a non-router source against `dnsmasq.servers` and `dnsmasq.addnhosts` fixtures → `blocked`/`allowed`/`other` counts and sources match; cached second query → `cache` | G | WU1 |
| T10 | §4.6 reasons | `dns=dnsmasq.nftset` → `dns-mode-unsupported`; a flood triggers `input-overflow` or `dnsmasq-log-overflow` | G | WU1 |
| T11 | §6.1, §8.1 | `info` fields and warnings for `log_file`, `log_ip` and dhcp `logfacility` set to a path | G | WU2 |
| T12 | §6.4–6.5 | grammar, normalization, protected set (incl. heartbeat and list hosts), PSL guard lists (positive and negative) | U | WU2 |
| T13 | §6.6 | plan table: `unblock`→`allow` translation, conflicts, `allow-overrides`, noop, mode selection | U | WU2 |
| T14 | §6.3 pipeline | each error code is produced by a real `ubus call` on G; `dry_run` has no side effects; `pending-uci-changes` | G | WU2 |
| T15 | §7 allow | allow of a listed name: UCI persisted, one dnsmasq restart, one adblock-fast run, DNS answer flips, job `applied` | G | WU2 |
| T16 | §14.1 collateral | allow `ads.example.com` with the fixture containing `bads.example.com` (what adblock-fast's own `allow` deletes): `ads` resolves, `bads` stays blocked; the upstream `allow` defects are recorded | G | WU2 |
| T17 | §7 rebuild | block, unblock and unallow each run one `dl`; state sequence `queued→applying→verifying→applied`; reboot → UCI persists and `job` is `null` | G | WU2 |
| T18 | §7.2 failure | list server down → `failed/rebuild-failed`, `persisted:true` | G | WU2 |
| T19 | §7.3 | second apply → `busy`; `kill -9` of the job → `interrupted`, lock free, next apply accepted | G | WU2 |
| T20 | §6.2 | `rules` `listed`/`effective`/`actions` for servers and addnhosts fixtures; rpcd responsive (a parallel `session list` < 200 ms) during the scan | G | WU2 |
| T21 | §9 | a read-only principal: allowed status, domains, info, rules, job and `uci get` on both configs; denied purge, apply and `uci set`; a missing object gives `-32000` | G | WU4 |
| T22 | §2 install | LuCI Software upload with the key added through LuCI (no `--allow-untrusted`) → objects work without a manual rpcd restart; removal removes the drop-ins and files | B+G | WU4 |
| T23 | §8.1 | each UI state is rendered from a real guest condition (disable, kill the daemon, stop dnsmasq, set logfacility, nftset mode, block the network → stale) | B | WU3 |
| T24 | §8.2 | staging persists across reload; replace/cancel rules; one `apply` per batch; confirm modal for rebuild; job progress; failed items return to pending | B | WU3 |
| T25 | §8.2 ACL | a read-only user sees no write controls; Settings loads and saves for an admin | B | WU3 |
| T26 | §11 | P1–P10 measured on the guest with raw results recorded | G | WU6 |

---

## 14. Risks and deviations found while verifying upstream facts

None of the coordinator decisions is impossible at these pins. The
constraints below are encoded above.

1. **adblock-fast `allow` is defective (verified on the 25.12.6 guest).** Its
   sed address `\:/\(/D\|.D\):d` starts with a literal `/`, so it matches
   `//D` or `/` + one character + `D`. It therefore never deletes
   `server=/D/` (or `local=/D/`, and nothing at all in addnhosts files): D
   stays blocked, because dnsmasq answers `server=/D/` locally even when
   `server=/D/#` is appended. It does delete the block of names that are D
   with one extra leading character (allowing `ads.example.com` unblocks
   `bads.example.com`), and it publishes an empty `status`. v1 therefore
   applies every change with one rebuild (§6.6, §7.2), and the job never
   calls `allow`.
2. **`uloop.process` cannot capture output.** stdout must be redirected with
   `io.pipe` + `dup2` around the call (§4.1). Killing the child needs its pid
   and `kill`; `delete()` doesn't kill.
3. **rpcd ucode plugins run in-process and single-threaded.** File scans and
   DNS must not run synchronously in `rules` or `apply` (§6, P8, P9). A job
   started with `system('… &')` inherits rpcd's open fds; the job must not
   use them.
4. **`dnsmasq.ipset` and `dnsmasq.nftset` don't block at the DNS layer,** so
   the monitor can't observe their blocks (`dns-mode-unsupported`). smartdns
   and unbound are out of scope for v1.
5. **Verification by DNS alone can't tell an upstream NXDOMAIN from a local
   one.** `observed` combines the answer with output-file membership.
6. **A `reload_config` or LuCI `uci.apply` for adblock-fast between `apply`
   and the end of the job** would start a concurrent adblock-fast reload. The
   job is not protected against this; it is detected through status checks.
7. **Starting at `START=18`** relies on logd and ubus being up (procd starts
   them earlier). WU1 verifies this on the guest (T08).

---

## 15. Superseded documents and tests

- `MONITORING_API.md`, `RULE_ACTION_API.md`, `INTEGRATION_CONTRACT.md` and
  `RUNTIME_TEST_REQUIREMENTS.md` are now one-line pointers to this file.
- `test/contract/domain-rule-action-api.test.mjs` and
  `test/unit/domain-rule-action.test.mjs` assert the old doc text and fail by
  design. WU5 deletes them, along with all other source-regex tests (review
  H7).
