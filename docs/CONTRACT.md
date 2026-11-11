# luci-app-adblock-fast-monitor — interface contract, api 2

Status: **frozen at API version 2**. All code implements this file. Changing
any name, field, type, bound, state or error code needs a contract change:
edit this file and bump `api` in the same commit. Every response that this
package defines includes `"api": 2`. api 2 is the first released interface,
so nothing migrates from an earlier one ([history](design.md#history)).

Targets: OpenWrt 25.12.6, adblock-fast 1.2.4-r4, LuCI openwrt-25.12, ucode
`85922056`, procd `58eb263`, rpcd `d99f703`, dnsmasq 2.93, ubox `6f78fa4`,
uhttpd `93b05e0`. The package is standalone. It depends on adblock-fast and
never forks or patches it.

---

## 1. Architecture (fixed decisions)

| # | Decision |
|---|---|
| D1 | **No resident process.** The init script (`START=18`) is a procd service with **no instance**: on start, stop, reload and boot it only reconciles the query-logging drop-ins through `logging.uc` (§4, §5) and exits; procd runs the same `logging.uc reconcile` directly from one trigger (§4). Nothing of this package runs between those calls, except one `job.uc` during an Apply (D5). |
| D2 | **No edits to `/etc/config/dhcp`.** Query logging comes from a tmpfs drop-in, `<confdir>/adblock-fast-monitor.conf` containing `log-queries=extra` and `log-async=25`, written for each enabled dnsmasq instance while `query_logging=1`. It is removed when `query_logging=0` or on stop. dnsmasq restarts **only** when the set of drop-ins changes **and** dnsmasq is running (P10). |
| D3 | **The browser reads and processes the log.** The page calls core logd `log read` through uhttpd (§8.1), the same call LuCI's System Log page and luci-app-adblock-fast make, and parses, correlates and classifies dnsmasq's lines in a pure JS module (`querylog.js`, §8.2–8.3). The router does no per-query work for this package. |
| D4 | **Statistics are the page's own:** computed over the rows the page keeps (≤ 500) and counters since the page was opened (§8.2). Nothing is stored on the router; closing the page discards them. |
| D5 | **Rule changes are staged in the browser**; the server keeps no shadow rules. One `apply` call sends the whole batch (`allow`/`block` ops) to the rpcd ucode plugin `luci.adblock-fast-monitor`. `apply` validates the batch, writes **only** `/etc/config/adblock-fast`, commits, and spawns **one** detached job. The job runs `adblock-fast dl` (one rebuild; adblock-fast's own `allow` is defective, §14.1, and `reload`/`restart` absorb list changes without rebuilding, §10), then verifies each domain against real DNS answers from `127.0.0.1`. One job runs at a time, enforced by `flock` on a file descriptor. |
| D6 | **Admins only.** The read grant includes core `log read`, i.e. the **whole system log** (kernel, auth, DHCP host names and MACs, every DNS client address) — the same grant luci-app-adblock-fast and LuCI's System Log use. LuCI has no UI for non-admin users, but rpcd logins with partial ACLs can be created by hand: grant this app only to users who may read the system log. |

Process inventory: none, in every state (installed, `query_logging` 0 or 1,
after boot). A reconcile adds one short-lived `ucode logging.uc`; an Apply
adds one `ucode job.uc` plus adblock-fast's own children until it ends.

---

## 2. Package file inventory

| Path | Mode | Purpose |
|---|---|---|
| `/etc/config/adblock-fast-monitor` | 0644 conffile | §3 |
| `/etc/init.d/adblock-fast-monitor` | 0755 | procd init, `START=18` (before dnsmasq `START=19`), no instance (§4) |
| `/usr/libexec/adblock-fast-monitor/logging.uc` | 0755 | `reconcile` / `disable` / `status` of the dnsmasq drop-ins (§4, §5) |
| `/usr/libexec/adblock-fast-monitor/job.uc` | 0755 | detached apply job (§7) |
| `/usr/share/ucode/abfm/domain.uc` | 0644 | grammar, protected domains, public-suffix guard, `plan()`, job verification helpers (§6.4–6.6, §7.2) |
| `/usr/share/ucode/abfm/system.uc` | 0644 | discovery of UCI, dnsmasq instances/confdirs, logd ring size and adblock-fast state; stale `/dev/log` detection (§4) |
| `/usr/share/rpcd/ucode/luci.adblock-fast-monitor` | 0644, **not** world-writable | rpcd ucode plugin (§6) |
| `/usr/share/rpcd/acl.d/luci-app-adblock-fast-monitor.json` | 0644 | §9 |
| `/lib/upgrade/keep.d/luci-app-adblock-fast-monitor` | 0644 | lists `/etc/apk/keys/adblock-fast-monitor.pem` (the feed key added in LuCI, owned by no package) so sysupgrade keeps it |
| `/usr/share/luci/menu.d/luci-app-adblock-fast-monitor.json` | 0644 | menu (depends on ACL `luci-app-adblock-fast-monitor`) |
| `/www/luci-static/resources/view/adblock-fast-monitor/overview.js` | 0644 | dashboard: query table, stats, staging, apply (§8) |
| `/www/luci-static/resources/view/adblock-fast-monitor/settings.js` | 0644 | `form.Map('adblock-fast-monitor')` (§3) |
| `/www/luci-static/resources/adblock-fast-monitor/querylog.js` | 0644 | pure log cursor, parser, correlator and classifier (§8.1–8.3) |
| `/www/luci-static/resources/adblock-fast-monitor/model.js` | 0644 | pure UI logic: staging reducer (§8.4), state derivation (§8.5) |

Runtime paths. Everything is tmpfs, so nothing survives a reboot by design.

| Path | Writer | Content |
|---|---|---|
| `/var/run/adblock-fast-monitor/` | plugin, 0700 root | directory |
| `/var/run/adblock-fast-monitor/job.json` | plugin + job, 0600, atomic rename | last job (§7) |
| `/var/run/adblock-fast-monitor/uci/` | plugin, 0700 | private UCI savedir for `apply` |
| `/var/run/adblock-fast-monitor/stale-restart` | `logging.uc` | the `/dev/log` socket the last stale restart was made for (§4 loop guard) |
| `/var/lock/adblock-fast-monitor.lock` | plugin + job | `flock` target (§7.3) |
| `/var/lock/adblock-fast-monitor.logging.lock` | `logging.uc` | `flock` that serializes reconciles (§5) |
| `<confdir>/adblock-fast-monitor.conf` | `logging.uc`, 0644 | the lines `log-queries=extra` and `log-async=25` |

The `abfm.*` modules are loaded with `require('abfm.<name>')` from ucode's
default search path `/usr/share/ucode/` and `return` their exports (an
`export` module can't be `require`d, which the rpcd plugin and the scripts
need, and `ucode -c` can't check it standalone). Each module must load under a
ucode interpreter built at pin `85922056` on the CI host, with no OpenWrt
runtime present (§13).

**Package dependencies:** `+luci-base` (which pulls in `rpcd`,
`rpcd-mod-ucode`, `ucode`, `ucode-mod-fs`, `ucode-mod-uci` and
`ucode-mod-ubus`), `+adblock-fast`, `+ucode-mod-io` (the job closes the fds it
inherits from rpcd) and `+ucode-mod-resolv` (the job's DNS verification).
`PKGARCH:=all`. Postinst and postrm do what `luci.mk` does:
`rm -f /tmp/luci-indexcache.*; rm -rf /tmp/luci-modulecache/; /etc/init.d/rpcd reload`
(SIGHUP makes rpcd re-exec, which loads the new plugin and ACL). The SDK's
`default_postinst` enables the init script on install and starts it on
install and upgrade; `start` reconciles the drop-ins (an unchanged set does
not restart dnsmasq) and re-registers the procd triggers. The SDK's
`default_prerm` runs `/etc/init.d/adblock-fast-monitor stop` on removal,
which removes the drop-ins (one dnsmasq restart when it runs and had one).
On removal (not upgrade) the postrm also deletes the runtime state:
`/var/run/adblock-fast-monitor/` and `/var/lock/adblock-fast-monitor.*lock`.
File modes are set by the Makefile, not taken from git. Install through LuCI → System → Software must work **without**
`--allow-untrusted`, using a key added on the "Repository Public Keys" page.

---

## 3. Configuration `/etc/config/adblock-fast-monitor`

One section: `config monitor 'config'` with one option. A value that doesn't
parse as a UCI boolean falls back to the default. Other options in the
section are ignored.

| Option | Type | Default | Consumer | Meaning |
|---|---|---|---|---|
| `query_logging` | bool | `0` | init → `logging.uc` | `1`: write a drop-in for every dnsmasq instance with `disabled!=1`, so dnsmasq logs queries to logd; `0`: remove ours (logging enabled elsewhere, e.g. dhcp `logqueries`, is left alone) |

The page's other choices are not router settings: it polls every 2 s
(§8.1), and whether router queries (`127.0.0.1`, `::1`) are shown is a
checkbox on the page, off by default (§8.2).

Settings saves go through LuCI `uci.apply`; the procd reload trigger runs the
init script, which only reconciles the drop-ins (dnsmasq restarts only when
the set changes).

---

## 4. Lifecycle (init script)

```text
START=18, USE_PROCD=1
start_service:    logging.uc reconcile   (reads query_logging itself: 1 -> write
                  the drop-ins, 0 -> remove ours; no procd_open_instance:
                  nothing runs, procd keeps the service for its triggers)
stop_service:     logging.uc disable, except during `restart` (start reconciles,
                  so dnsmasq is not restarted twice)
service_triggers: procd_add_reload_trigger adblock-fast-monitor
                  query_logging=1 -> procd_add_raw_trigger instance.update 3000
                                     /usr/libexec/adblock-fast-monitor/logging.uc reconcile
```

`reload` (what the config trigger runs) re-runs `start_service` and
re-registers the triggers. With an unchanged drop-in set nothing restarts.
procd runs the `instance.update` command directly (`execvp`, no shell), so
a firing costs one short-lived `ucode` process.

**logd restarts.** procd jails dnsmasq (`procd_add_jail dnsmasq ubus log`),
bind-mounting `/dev/log` into the jail when dnsmasq starts. When logd
restarts (`/etc/init.d/log restart`, or LuCI System → Logging save, which
commits `system` and makes the `log` service reload), it creates a new
`/dev/log` socket; the jail still holds the old, dead inode. dnsmasq's
reconnect attempts resolve `/dev/log` inside the jail, so they never reach
logd again: **dnsmasq logs nothing at all** (queries included, with or
without `log-async`, and also with dhcp `logqueries`) until it restarts.
Verified on the 25.12.6 guest: 0 query lines 30 s after a logd restart for
both `log-queries=extra` + `log-async=25` and plain `log-queries=extra`;
all lines back after a dnsmasq restart. procd raises the trigger event
`instance.update` whenever any service instance starts or stops; while
`query_logging=1` the init script registers a raw trigger on it (debounced
3 s) that runs `logging.uc reconcile`. With drop-ins in place, that compares
the `/dev/log` inode seen through `/proc/<pid>/root` of the procd `dnsmasq`
service's processes with the current one (`abfm.system` `dnsmasq_log_stale`)
and restarts dnsmasq once if they differ (P10 exception, §11):

- **Scope.** Only the pids of the running `dnsmasq` service instances
  (`ubus call service list '{"name":"dnsmasq"}'`) and their direct children
  (the jailed dnsmasq that ujail forks) are compared. Any other process named
  dnsmasq, for example one in its own chroot or container, is ignored: a
  restart of the system dnsmasq would not change it, so it would look stale
  forever.
- **Loop guard.** `/var/run/adblock-fast-monitor/stale-restart` records the
  `/dev/log` socket (device and inode) a stale restart was made for. If the
  service is still stale against that same socket, no further restart is
  made; a new logd socket allows one new restart.

Otherwise the trigger changes nothing; it is not registered while
`query_logging=0`. A reconcile is a short-lived `ucode logging.uc` (D1). At
boot (`START=18` < dnsmasq `19`) dnsmasq is not running yet, so writing the
drop-ins never restarts it (P10). The same trigger also covers a hand-over
with luci-app-adblock-fast's logging toggle (§14.14): when dhcp `logqueries`
is set and dnsmasq restarts, the next reconcile removes our drop-in (one
more restart); when it is cleared, the drop-in comes back.

---

## 5. Query-logging drop-ins (`logging.uc`)

- **Targets.** Every `dhcp` section of type `dnsmasq` that has
  `disabled!=1`. Anonymous sections use their UCI-generated names (for
  example `cfg01411c`).
- **Modes.** `reconcile` reads `query_logging` (§3) and acts as `enable`
  (1) or `disable` (0); `disable` is what `stop` runs; `status` only reads.
  `reconcile` and `disable` hold `flock` on
  `/var/lock/adblock-fast-monitor.logging.lock` (blocking, `O_CLOEXEC`), so
  concurrent runs (a reload and a trigger) never both see a changed set.
  Exit status 1 when a drop-in could not be written or removed
  (`write-failed`, `remove-failed`, `confdir-invalid` on stderr), else 0.
- **Confdir.** `confdir = uci dhcp.<s>.confdir`, defaulting to
  `/tmp/dnsmasq.<s>.d` (`dnsmasq.init` L1172). Everything from the first `,`
  is cut. The result must be absolute; otherwise the instance is reported as
  `confdir-invalid` and skipped (its `status` entry has `"confdir":null` and
  `"reason":"confdir-invalid"`). The file name ends in `.conf` so that common
  conf-dir suffix filters keep it.
- **`enable`.** For each target that does **not** already have
  `dhcp.<s>.logqueries=1`, write `<confdir>/adblock-fast-monitor.conf`
  atomically (tmp + rename, 0644), creating the confdir 0755 if needed; a
  damaged drop-in is rewritten. Remove drop-ins for instances that are no
  longer targets.
- **Content.** `log-queries=extra` plus `log-async=25`. Without `log-async`
  dnsmasq writes each log line to syslog synchronously on the query path;
  with it, dnsmasq queues up to 25 lines and, if the queue overflows, logs
  `overflow: N log entries lost`, which the page counts as missed (§8.3
  `LOST`).
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

---

## 6. Actions backend — rpcd ucode plugin `luci.adblock-fast-monitor`

rpcd loads plugins once at startup from `/usr/share/rpcd/ucode/`. The plugin
runs **inside rpcd's single-threaded uloop**, so every method must return
within **200 ms** (P8). All adblock-fast and DNS work runs in the job (§7).
Plugin regexes avoid bounded repetition (`{m,n}`): musl expands it into an
automaton that costs milliseconds per match.

### 6.1 `info` (read)

Request `{}`. All values are cheap UCI reads, `stat` calls and one ubus
`service list` call. Response:

```json
{ "api":2,"ok":true,
  "monitor":{"query_logging":true},
  "local_domains":["lan"],
  "protected_suffixes":["localhost","arpa","local","internal","invalid","onion","bind","heartbeat.mossdef.org","lan","openwrt"],
  "logd":{"size_kib":128},
  "adblock_fast":{"installed":true,"enabled":true,"status":"statusSuccess",
                  "dns":"dnsmasq.servers","output_file":"/var/run/adblock-fast/dnsmasq.servers",
                  "output_exists":true,"external_config":false,"pending_uci_changes":false},
  "dnsmasq":{"running":true,"instances":[{"section":"cfg01411c","confdir":"/tmp/dnsmasq.cfg01411c.d",
             "dropin":true,"uci_logqueries":false,"running":true,"logfacility_file":false}]},
  "warnings":["query-logging-active"] }
```

Field sources:

- `monitor`: §3, parsed.
- `local_domains`: the dhcp `domain` values and the `local` values with their
  slashes stripped, lower-cased and de-duplicated, over all `dnsmasq`
  sections. The page treats names equal to or under them as local (§8.3),
  so it needs no `dhcp` read grant.
- `protected_suffixes`: the names `apply` refuses to `block` together with
  everything under them (§6.5: built-ins, dhcp `domain`/`local`, hostname,
  heartbeat), normalized and de-duplicated, built-ins first. The page offers
  no `Block` for such names (§8.4). The exact list hosts of §6.5 are not in
  it; a `Block` of one is refused by `apply`.
- `logd.size_kib`: the ring size logd runs with (`log_buffer_size`, else
  `log_size`, else 64, as `log.init` computes `-S`); the page shows it next
  to the window it could read (§8.1).
- `adblock_fast.installed`: `/etc/init.d/adblock-fast` and
  `/etc/config/adblock-fast` both exist.
- `adblock_fast.status`: from `service list` data, or `null`.
- `output_file`: from the `dns` mode (§10).
- `external_config`: `dnsmasq_config_file_url` is non-empty.
- `pending_uci_changes`: `/tmp/.uci/adblock-fast` holds a delta other than
  `adblock-fast.<section>.size='N'` (§6.3 step 4). adblock-fast itself saves
  (without committing) every `file_url` size after each download when
  `update_config_sizes=1` (the default); that bookkeeping is ignored.
- `dnsmasq.instances[]` lists every `dnsmasq` section with `disabled≠1`
  (each one is a drop-in target, §5); `confdir` is `null` when invalid
  (`"reason":"confdir-invalid"`). `running` is that procd instance's state;
  `dnsmasq.running` is true when any instance runs.

| `warnings` code | Condition |
|---|---|
| `query-logging-active` | at least one drop-in exists, or `uci_logqueries` is set (logd's ring fills with DNS lines; informational) |
| `logd-to-flash` | `system.@system[0].log_file` is set to a path outside tmpfs (not under `/tmp`, `/var` or `/dev/shm`), so logged queries are written to flash |
| `logd-remote` | `system.@system[0].log_ip` is set |

### 6.2 Arguments and errors

rpcd validates arguments against each method's declared signature before
the plugin runs: an undeclared field or a field of the wrong JSON type is
answered with ubus status `UBUS_STATUS_INVALID_ARGUMENT` (2), not with a
JSON error. uhttpd adds `ubus_rpc_session` to every call from LuCI; rpcd
accepts it next to the declared fields. Declared fields: `info {}`,
`apply {ops: array, confirm_rebuild: bool, rebuild: bool, dry_run: bool}`,
`job {job_id: string}`. The plugin has no other method.

Errors use one shape:
`{"api":2,"ok":false,"error":{"code":"<code>","message":"<text>"}}`, with
ubus status 0. Some errors add fields next to `error` (`job_id`, `mode`,
`plan`, `persisted`) or inside it (`index`, `domain`), as §6.3 lists.

### 6.3 `apply` (write)

Request:

```json
{ "ops":[{"op":"allow","domain":"ads.example.com"},{"op":"block","domain":"tracker.example.net"}],   // op: allow|block
  "confirm_rebuild":false,   // must be true when mode=rebuild
  "rebuild":false,           // true + ops:[] = run one rebuild for already-persisted UCI
  "dry_run":false }
```

Pipeline. The call is all-or-nothing, and it rejects at the first failing
step.

1. Shape check (`invalid-request`, also for any `op` other than `allow` and
   `block`): 0–64 ops (`batch-too-large`).
   `ops:[]` without `rebuild:true` gives `batch-empty`.
2. Each op is normalized and validated (§6.4–6.5). The error carries `index`
   and `domain`.
3. Duplicate identical ops collapse. Two different ops for one domain give
   `conflict`.
4. Preconditions:
   - `adblock-fast-missing`;
   - `external-config` (`dnsmasq_config_file_url` is set);
   - `unsupported-dns-mode` (`dns` is not one of the five `dnsmasq.*` modes
     of §10, e.g. `smartdns.*` or `unbound.*`);
   - `pending-uci-changes`: the default uci savedir `/tmp/.uci/adblock-fast`
     holds uncommitted changes other than adblock-fast's own `file_url` size
     bookkeeping (§6.1). These come from the `uci` CLI or scripts, and `dl`
     would read them. It does **not** see LuCI's staged-but-unapplied
     changes: rpcd keeps those per session in `/var/run/rpcd/uci-<sid>`
     (rpcd `uci.c` L289-315), which no other process reads (§14).
5. `plan()` (§6.6) produces each op's `change` and the batch's `mode`.
   A `block` whose name equals, or falls under, an `allowed_domain` entry that
   stays after the batch gives `allow-overrides`, because the rebuild removes
   allowed names after it adds blocks (adblock-fast.uc L2005-2030).
6. If `mode="rebuild"` and `confirm_rebuild≠true`, the response is
   `{"ok":false,"error":{"code":"confirm-required",…},"mode":"rebuild","plan":[…]}`.
7. `dry_run:true` stops here:
   `{"api":2,"ok":true,"dry_run":true,"noop":false,"mode":…,"plan":[…]}`.
8. Take the lock with `xn`. If that fails (`job_id` is the last job's id or
   `null`), or the queued window of §7.3 applies (`job_id` of that job),
   return `busy`.
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
    `persisted` (whether step 9 committed a change) and `job_id`.

If every op is a noop and `rebuild` is false, the response (also for a dry
run) is `{"api":2,"ok":true,"noop":true,"job_id":null,"mode":…,"plan":[…]}`
and no job starts.

Success response:

```json
{ "api":2,"ok":true,"job_id":"j1762747400-3f2a","state":"queued","mode":"rebuild",
  "plan":[{"op":"allow","domain":"ads.example.com","change":["allow:add","block:remove"]},
          {"op":"block","domain":"x.example.com","change":["allow:remove","block:add"]}] }
```

`plan` has one entry per distinct op, in request order, with the normalized
domain. `change` lists the UCI mutations: `allow:add`, `allow:remove`,
`block:add` and `block:remove`. An empty list means noop.

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

`protected-domain` (`block` only):

- the name equals or falls under: `localhost`, `arpa` (so `home.arpa`),
  `local`, `internal`, `invalid`, `onion`, `bind` (the names the page treats
  as local, §8.3, plus `internal`), the dhcp `domain` and `local` values, the
  system hostname, or adblock-fast's `heartbeat_domain` (a blocked heartbeat
  fails adblock-fast's restart check). `info.protected_suffixes` is this
  list;
- or it is the host of any enabled `file_url.url` or of `config_update_url`
  (blocking those breaks list downloads).

`public-suffix` (both ops). The name is rejected when any of these holds:

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

| op | UCI change | `expect` |
|---|---|---|
| `allow` | `D∉A` → `allow:add`; `D∈B` → `block:remove` | `allowed` |
| `block` | `D∈A` → `allow:remove`; `D∉B` → `block:add` | `blocked` |

So `Allow` undoes a manual block and overrides a downloaded list, and `Block`
undoes a manual allow; no "unblock"/"unallow" ops are needed.

Mode (one per batch):

- **`persist-only`**: adblock-fast `enabled≠1`. UCI is written and there is
  no runtime step.
- **`rebuild`**: adblock-fast `enabled=1`. Every change is applied with one
  rebuild; adblock-fast 1.2.4-r4's own `allow` fast path is never used: it
  does not remove the blocking line, deletes unrelated lines and clears the
  service status (§10, §14.1). The UI must obtain explicit confirmation:
  "downloads all lists over WAN, restarts DNS, may take minutes". The user
  stages many changes and pays for one rebuild per Apply.

---

## 7. Job (`job.uc`)

### 7.1 `job` (read)

Request: `{"job_id":"j1762747400-3f2a"}`. The ID is optional; omitting it
means the latest job. A non-matching ID gives `not-found`. Response:

```json
{ "api":2,"ok":true,"job":{
  "id":"j1762747400-3f2a",            // ^j[0-9]{10}-[0-9a-f]{4}$
  "state":"verifying",                 // queued|applying|verifying|applied|partial|failed
  "mode":"rebuild",                    // rebuild|persist-only
  "phase":"verify",                    // null|rebuild|verify
  "created_at":1762747400,"started_at":1762747400,"finished_at":null,
  "persisted":true,                    // UCI committed by apply
  "adblock_fast_status":"statusSuccess",
  "error":null,                        // or {"code":"…","message":"…"}
  "items":[{"op":"allow","domain":"ads.example.com","change":["allow:add"],
            "expect":"allowed","result":"ok","observed":"allowed",
            "answer":{"rcode":"NOERROR","a":["93.184.216.34"],"aaaa":[]},"reason":null}] } }
```

`job` is `null` when no job has run since boot. The fields above are all
the fields of a job.

`items[].expect`: `allow` → `"allowed"`, `block` → `"blocked"`.

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
- `still-listed`: after `allow`, the output file still blocks the name
  itself;
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
     rcode is NXDOMAIN or NOERROR-empty **and** the output file lists the
     name (`abfm.domain.listed`: the longest matching `server=/S/` or
     `local=/S/` is a block line, or an exact addnhosts entry; one
     `grep -F` over the file in the job);
   - `allowed`: a non-sinkhole A, AAAA or CNAME, or NXDOMAIN with
     `listed=false`;
   - `unknown`: anything else.

   dnsmasq was restarted by the runtime step, so its cache is empty.
   These lookups come from `127.0.0.1`, so the page hides them by default
   (router rows, §8.3).
5. Terminal state:
   - `applied`: every item is `ok` or `skipped`;
   - `partial`: anything else short of a failure;
   - `failed`: `error` is set.

Then release the lock.

Job error codes: `lock-failed`, `rebuild-failed`, `interrupted`,
`start-timeout`.

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

```text
(none) --apply--> queued --job acquires lock--> applying --runtime ok--> verifying --> applied | partial
                    |                              \--error--> failed{rebuild-failed|lock-failed}
                    \--not started 30 s--> failed{start-timeout}      applying|verifying --holder died--> failed{interrupted}
```

`job.json` lives on tmpfs, so after a reboot `job` returns `null`. UCI
changes persist.

---

## 8. LuCI UI

### 8.1 Reading the log (`log read`)

The page calls core logd through uhttpd, never a plugin of its own:

```js
rpc.declare({ object: 'log', method: 'read', params: [ 'lines', 'stream', 'oneshot' ], expect: { log: [] } })
// called as (N, false, true)  ->  [{msg, id, priority, source, time}], oldest first, time in ms
```

Bounds and cadence:

- **Always pass `lines`**, and `16 ≤ N ≤ 900`. Never `0` (returns nothing)
  and never omit it (returns the whole ring). 900 keeps the worst case, ~1 KiB
  lines, under the 1 MiB ubus message cap, so a fetch can never disconnect
  logd from ubus (§12; T10).
- **First fetch** after load: `N = 900`.
- **Polling:** every 2 s **only while**
  `document.visibilityState === 'visible'`. LuCI's `poll` keeps running in a
  hidden tab, so the view adds its poll function when the page becomes
  visible and removes it on `visibilitychange` to hidden (P2: a hidden or
  closed page makes 0 requests). At most one `log read` in flight.
- **Adaptive N:** `N = clamp(16, 900, ceil(1.5 × entries in the last batch) + 16)`.
- **Cursor** = the highest `id` ingested. Entries with `id ≤ cursor` are
  skipped.
- **Gap:** if the oldest returned `id > cursor + 1` and `N < 900`, refetch
  once with `N = min(900, lastId − cursor + 16)`. A gap that remains is
  reported as "k log entries missed" (`missed`).
- **Reset:** if the newest `id < cursor`, logd restarted: drop the cursor and
  the pending queries, keep the rows.
- The window is whatever logd's ring still holds (`info.logd.size_kib`): with
  the default 128 KiB about 230–570 queries if nothing else logs. The page
  shows the span and the missed count and points to System → Logging → buffer
  size; it never edits `/etc/config/system`.
- Never `log write`, never `GET /ubus/subscribe/log` (SSE pushes every line of
  every daemon over a long-lived connection; the ACL does not grant it, §9).

### 8.2 `querylog.js` module interface

`/www/luci-static/resources/adblock-fast-monitor/querylog.js` is a LuCI
module (`'use strict'; 'require baseclass';`) with pure logic only — no DOM,
no `rpc` — loadable by the Node tests the same way as `model.js`. Shape
(the owner of `querylog.js` documents refinements here):

- `create(opts)` → `state`; `opts`: `{max_rows: 500, pending_ttl_s: 10,
  local_domains: [...], hide_router: true}` (`local_domains` from
  `info.local_domains`; router queries are hidden unless the page's "show
  router queries" checkbox is ticked).
- `nextRequest(state)` → `{lines: N}` per §8.1 (900 on the first call). Pure.
- `ingest(state, reply)` with `reply = {log: [...]}` from `log read` →
  `{added, missed, reset, refetch: {lines: N} | null}`. When `refetch` is not
  `null` the caller performs that one refetch and ingests its reply too.
- `rows(state, {show_router})` → newest first, at most `max_rows`:
  `{key, time (epoch s), domain, qtype, answers: [≤ 4 strings], decision,
  source, client, router: bool}`. `decision` is `'blocked'`, `'allowed'`,
  `'other'`, `'no-answer'` (no terminal line within `pending_ttl_s` of log
  time) or `'pending'` (query seen, no answer yet, TTL not reached).
  `source` is the §8.3 attribution, or `null` while pending/no-answer. `key`
  is opaque and unique, formatted `epoch:pid:serial:client/port` (`epoch`
  counts the dnsmasq restarts seen). In `answers`, a `<CNAME>` answer is
  replaced by the next name in the chain; it stays `<CNAME>` only when the
  chain has no further line. `show_router` defaults to `!hide_router`. All
  strings are raw (never escaped or altered); the UI renders them as text
  only.
- `stats(state, {show_router})` → over the rows `rows()` would return with
  the same option:
  `{kept, blocked, allowed, other, no_answer, pending, blocked_pct, span_s,
  missed_total, dnsmasq_lost, rejected, since_open: {queries, blocked,
  allowed}}`.
  - `kept`: rows counted; `blocked`/`allowed`/`other`/`no_answer`/`pending`:
    rows per decision.
  - `blocked_pct = round(1000 · blocked / (blocked + allowed)) / 10`, or
    `null` when `blocked + allowed = 0` (P1 stat, shown with `kept` and
    `span_s`).
  - `span_s`: seconds between the oldest and newest counted row.
  - `missed_total`: log ids skipped by gaps (§8.1); `dnsmasq_lost`: sum of
    dnsmasq's `overflow: N log entries lost`; `rejected`: tagged lines that
    looked like query-log lines but matched neither `BODY` nor `LOST`.
  - `since_open`: queries and decisions since the page was opened, not
    limited to the kept rows (router clients excluded when `hide_router`).

### 8.3 Line grammar and classification

`msg` is the syslog message with the `dnsmasq[pid]: ` tag (logd strips only
`<prio>` and the timestamp). Only messages starting with that tag are
considered (`dnsmasq-dhcp[` and others are not). Grammar (POSIX ERE):

```text
TAG  = ^dnsmasq\[([0-9]+)\]: (.*)$
BODY = ^(TCP |UDP )?([0-9]+) ([^ /]+)/([0-9]+) ([^ ]+) ([a-z0-9_.:-]+) (from|is|to) ([^ ]+)( \([^()]*\))?$
LOST = ^overflow: ([0-9]+) log entries lost$
```

`BODY` groups: `proto`, `serial`, `client`, `port`, `source`, `name`, `verb`,
`answer`, `extra`. dnsmasq lower-cases names and replaces names with
non-printable characters by `<name unprintable>` (`cache.c` L2014-2030), so
`BODY` rejects that placeholder, uppercase, spaces and injected tokens (a
label like `victim.com is 0.0.0.0.x` leaves trailing tokens and the anchored
`$` fails). The name class includes `:` because a reverse lookup logs the
address. A tagged message that starts like a query-log line
(`^(TCP |UDP )?[0-9]+ `) but matches neither `BODY` nor `LOST` is rejected
(counted); informational lines (`started, version …`, `read /etc/hosts …`)
are ignored, except that `started, version` **resets** correlation (the
serial restarts with every dnsmasq restart, i.e. every rebuild). `LOST` adds
its count to `missed`.

Correlation key: `pid:serial:client/port` (procd jails dnsmasq in a PID
namespace, so every instance logs as `dnsmasq[1]`). A `query[T] … from`
line opens an entry; the **first** terminal line decides it; later `reply`/
`cached` lines of the same key (a CNAME chain) only add their answers to the
row, up to 4. Terminal lines whose key is unknown (their query line already
left the ring) are ignored. An entry still open 10 s of **log time** after
its query becomes `no-answer`. At most 500 rows are kept (oldest dropped).

Line shapes (`"%s%u %s/%u %s %s%s%s %s%s"`, `cache.c` L2511), each prefixed
with `dnsmasq[1]: `:

```text
41 192.168.1.10/53211 query[A] ads.example.com from 192.168.1.10
41 192.168.1.10/53211 config ads.example.com is NXDOMAIN            # dnsmasq.servers / dnsmasq.conf block
42 192.168.1.10/53212 /var/run/adblock-fast/dnsmasq.addnhosts ads.example.com is ::   # addnhosts block
44 192.168.1.10/53214 forwarded www.example.org to 1.1.1.1
44 192.168.1.10/53214 reply www.example.org is <CNAME>
44 192.168.1.10/53214 reply cdn.example.org is 93.184.216.34
45 192.168.1.10/53215 cached www.example.org is NODATA-IPv6
46 192.168.1.10/53216 /tmp/hosts/dhcp.cfg01411c router.lan is 192.168.1.1
47 fd00::10/40000 reply x.example.com is SERVFAIL (EDE: network error)
48 192.168.1.10/53218 reply query is duplicate                        # ignored
overflow: 12 log entries lost
```

"Local" means the **query** name is single-label, is an address, equals or
is under `arpa`, `localhost`, `local`, `invalid`, `onion`, `bind` (OpenWrt's
`rfc6761.conf` answers these with `server=/…/`), or equals or is under one of
`info.local_domains`. `test` is deliberately not special (the fixtures use it
for listed ad domains).

| `source` | `verb` | Condition | Decision | `source` attribution |
|---|---|---|---|---|
| `query[T]` | `from` | | open entry (`qtype=T`); `router=true` when `client` ∈ {127.0.0.1, ::1} (hidden by default) | — |
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

A `blocked` decision with source `config` means "dnsmasq answered from local
configuration": adblock-fast's `server=/x/` and `local=/x/` lines, and any
user `address=/x/0.0.0.0`. Decisions mean "blocked by adblock-fast" only when
`info.adblock_fast.dns` is `dnsmasq.servers`, `dnsmasq.addnhosts` or
`dnsmasq.conf`; in the `ipset`/`nftset` modes blocking happens in the
firewall and the page says so.

**Untrusted strings.** `domain`, `answers` and `client` come from the network
(a PTR answer is a name chosen by a remote rDNS owner and may contain `<`,
`>`, `"`). They are rendered **only** as text: array children of `E()`, or
`textContent`; never a string child of `E()` (that is innerHTML), never an
HTML string (T27).

### 8.4 Staging (client-side only)

- `localStorage["adblock-fast-monitor.pending.v2"] = {"v":2,"items":[{"op":"allow","domain":"…","ts":1762747400}]}`,
  at most 64 items, `op` ∈ {`allow`, `block`}. Items may carry `reason` (the
  last failure), and the object may carry `inflight:{job_id,items}` so a
  reload resumes the job.
- Row buttons: `Allow` on `blocked` rows, `Block` on `allowed` rows, except
  that no `Block` is offered for a name equal to or under one of
  `info.protected_suffixes` (the server would refuse it, §6.5). Adding an
  op for D replaces any pending op for D; adding the same op again removes it.
- Domains are normalized as in §6.4 before they are stored.
- **Apply.**
  1. `apply{dry_run:true}`. If the mode is `rebuild` (or the reply is
     `confirm-required`), show a `ui.showModal` confirmation that names the
     cost.
  2. `apply` with `confirm_rebuild` set from that confirmation.
  3. When it returns `queued`, move the items to `inflight{job_id}`.
  4. Poll `job` every 2 s until it is terminal (only while visible).
  5. Items with `ok`, `skipped` or noop leave the list. `mismatch`,
     `unverified` and failed items return to pending with their reason.
  6. `busy` → show the current job.
- **Discard** clears the pending list.
- Write controls (row buttons, Apply) are not rendered when
  `!L.hasViewPermission()` (luci.js L3259).

### 8.5 Page states and data calls

States, first match wins: `access-denied` (`info` rejects with `-32002`);
`adblock-fast-missing` (`info.adblock_fast.installed=false`; no actions);
`logging-off` (`info.monitor.query_logging=false` and no instance has
`uci_logqueries`; link to Settings, actions still available);
`logging-unavailable(reason)` (`!info.dnsmasq.running` → `dnsmasq-not-running`;
an instance with `logfacility_file` → `dnsmasq-logs-to-file`; no instance
has `dropin` or `uci_logqueries` → `confdir-invalid` or
`logging-not-active`); `healthy`; `error` (`log read` rejected with no
earlier data); `loading`. `info.warnings` render as dismissible notes.

| Call | Cadence |
|---|---|
| `log read` | §8.1, while visible |
| `info` | at load and every 30 s while visible |
| `job` | every 2 s while a job is non-terminal and the page is visible |

All dynamic text goes through `E()` array children or text nodes. Views
`'require'` `rpc`, `uci`, `ui`, `form`, `poll` and `view` explicitly.

---

## 9. ACL `/usr/share/rpcd/acl.d/luci-app-adblock-fast-monitor.json`

```json
{
  "luci-app-adblock-fast-monitor": {
    "description": "Grant access to Adblock Fast Monitor (admins only: the read grant includes the whole system log)",
    "read": {
      "ubus": {
        "log": [ "read" ],
        "luci.adblock-fast-monitor": [ "info", "job" ]
      },
      "uci": [ "adblock-fast-monitor" ]
    },
    "write": {
      "ubus": {
        "luci.adblock-fast-monitor": [ "apply" ]
      },
      "uci": [ "adblock-fast-monitor" ]
    }
  }
}
```

- Never `log write` and never the `:subscribe` method (SSE). Granting the read
  set exposes the whole system log (D6): **grant this app to admins only.**
  `root` (LuCI's admin) has every ACL anyway.
- rpcd checks `uci get` against the `read` grant specifically. The page
  reads adblock-fast's state only through `info`, so there is no `uci` grant
  on `adblock-fast`: writes happen only through `apply`, and `uci get`
  of it is refused (ubus status 6) like any other config outside the grant.
- Privacy: no client address is stored anywhere on the router by this
  package. The page's client column is **hidden by default**, and router
  queries (`127.0.0.1`, `::1`) are hidden by default (a page checkbox).

---

## 10. adblock-fast facts this contract relies on (1.2.4-r4)

| Item | Value |
|---|---|
| UCI | `adblock-fast.config`: `enabled`, `dns`, `allowed_domain` (list), `blocked_domain` (list), `dnsmasq_config_file_url`, `heartbeat_domain`, `config_update_url`, `file_url` sections (`url`, `enabled`, `action`) |
| Output file by `dns` | `dnsmasq.servers` → `/var/run/adblock-fast/dnsmasq.servers` (`server=/D/`, allow `server=/D/#`); `dnsmasq.addnhosts` → `/var/run/adblock-fast/dnsmasq.addnhosts` (`127.0.0.1 D`, `:: D`); `dnsmasq.conf`/`ipset`/`nftset` → `/var/run/adblock-fast/adblock-fast.dnsmasq` (`local=/D/`, `ipset=/D/adb`, `nftset=/D/4#inet#fw4#adb4…`) |
| `allow` fast path | **defective, not used** (§14.1). Requires the output file; refuses with an external config; for each D runs `sed -i '\:/\(/D\|.D\):d'`, appends `server=/D/#` in servers mode, adds `allowed_domain`, commits, refreshes the `/dev/shm` config cache, restarts the resolver once and then publishes an empty `status` to procd. Its exit code is not meaningful. |
| `update_config_sizes` | default `1`: after a download adblock-fast `save`s (never commits) each `file_url`'s `size`, leaving a delta in `/tmp/.uci/adblock-fast` (§6.1). |
| Rebuild | any change to `allowed_domain` or `blocked_domain` makes `start` choose `download`; `dl` forces it. Allowed names are removed with `/(^\|\.)D$/d` **after** blocked names are appended. |
| Status | `ubus call service list '{"name":"adblock-fast"}'` → `.adblock-fast.data.status` (`statusSuccess`, `statusFail`, …) and `.data.errors[].code`; a download failure of one list still ends `statusSuccess` with `errorDownloadingList` when the output file could be built |
| `heartbeat_domain` | `-` does **not** disable the heartbeat (it falls back to the default `heartbeat.mossdef.org`); the heartbeat must resolve within `heartbeat_sleep_timeout` or the start fails |
| Trigger | the init registers `config.change` → `reload`. The ucode `uci` commit does not emit it, while LuCI `uci.apply` does. |
| `reload`/`restart` don't rebuild | both go through `start()`: a change to `allowed_domain`/`blocked_domain` first selects `download` (`adblock-fast.uc` L1019-1033), but that is overwritten with `skip` when the last status was `statusSuccess` and the output file exists (L2485-2494), and the new config is then stored as current (L2623), so the change is absorbed without a rebuild. Only `dl` (`start('download')`) rebuilds. Recorded on the guest (T20). This is why Apply runs `dl` in the job and why LuCI's Save & Apply of adblock-fast's lists is not a substitute. |

---

## 11. Performance budgets

No resident process; the browser reads `log read` and does all
parsing. Measured by T26 (`npm run test:performance:measure -- PKG.apk`) and
judged by `scripts/performance-gate.mjs` against `scripts/perf/budgets.json`.
Method, justification and measured data: [`docs/performance.md`](performance.md).
CPU is percent of one CPU of the 2-vCPU measurement guest; the gate records
the accelerator (TCG or KVM) and the run-to-run spread (noise) of every
repeated number over ≥ 3 repeats. The OpenWrt x86/64 kernel has no
`smaps`/`smaps_rollup`, so memory uses RssAnon. Load is real queries from a
LAN address (not `127.0.0.1`), answered by local fixtures: 50 % forwarded,
30 % cached, 20 % blocked. The page is the real LuCI page in headless
Chromium, logged in as `root`.

| ID | Metric | Budget |
|---|---|---|
| P1 | package processes in every state: after install and after a boot, with `query_logging=0` and `=1`, in every load window (snapshots and 100–250 ms `/proc` watches); transient init-script invocations (≤ 10 s) at boot and while idle; rpcd RssAnon growth vs stock | 0 resident processes, except `job.uc` during an Apply (**hard**); transient invocations ≤ 2 per boot, 0 while idle; rpcd RssAnon ≤ 1 MiB |
| P2 | requests made by a hidden page (background tab or Page Visibility emulation) and by a closed page | 0 in 60 s each (**hard**); the visible control must poll, and polling must resume when shown |
| P3 | one visible page polling every 2 s under 50 / 200 qps: CPU of uhttpd + ubusd + logd + rpcd vs the same load with no page; `log read` p95 (ubus, guest) | ≤ 2 / 6 pp; p95 ≤ 50 ms at the adaptive N (incremental), ≤ 150 ms at N = 900 |
| P4 | browser parse + classify + render per poll at 900 entries (`abfm-poll` performance measure; fallback: the querylog module timed in the page) | p95 ≤ 20 ms; ≤ 500 rows kept |
| P5 | DNS p95 latency delta, query logging on vs off, same load | median(on p95) − median(off p95) ≤ max(3 ms, measured noise floor), ≥ 3 runs per state, loss ≤ 0.5 % |
| P6 | logd, dnsmasq, rpcd, uhttpd, ubusd CPU/RSS deltas, query logging on vs off | each ≤ 4 pp CPU at 50 qps (dnsmasq ≤ 10 pp), ≤ 12 pp at 200 qps; RssAnon ≤ 256 KiB |
| P7 | `info` round trip through ubus | p95 ≤ 50 ms |
| P8 | `apply` return time (rpcd blocking) | ≤ 200 ms, and rpcd never blocked > 200 ms (20 ms `session list` probe) (**hard**) |
| P10 | dnsmasq restarts caused by the package (boot, enabling query logging, a settings save, a package upgrade) | 0 / 1 / 0 / 0 (**hard**) |

P10 exception (§4, logd restarts): with `query_logging=1` only, a logd
restart costs exactly one dnsmasq restart, made by the init script's
`instance.update` trigger because the jailed dnsmasq lost its `/dev/log`.
dnsmasq would otherwise log nothing until its next restart. With
`query_logging=0` a logd restart never restarts dnsmasq. A dnsmasq outside
the procd service never causes a restart, and a restart is made at most
once per logd socket (§4). Tested by `test/guest/logging-logd-restart.sh`.

---

## 12. Upstream facts

The upstream behaviour this contract relies on, with source pins and file
and line references (verified 2026-11-10), is recorded in
[`docs/design.md` → Upstream facts](design.md#upstream-facts). It is
evidence for the rules above, not part of the interface.

---

## 13. Test obligations

Every behavioural test must **execute** the behaviour it covers: a test of
package behaviour that only matches source or documentation text with a
regex is not accepted. Repository checks are a separate kind and are
allowed: they check the repository itself (for example the docs
self-check, `test/unit/docs-references.test.mjs`, that named paths and
scripts exist), and they never count as evidence for a T-ID below.

Environments:

- **U**: a ucode interpreter built on the CI host at pin `85922056`, loading
  the real `abfm.*` modules (`npm run test:ucode`).
- **S**: OpenWrt 25.12.6's BusyBox ash and `uci` in the host userland
  container (`npm run test:shell`).
- **N**: Node, loading the real LuCI modules (`npm run test:unit`).
- **G**: an OpenWrt 25.12.6 QEMU guest with the installed APK, real dnsmasq
  and real adblock-fast, served deterministic local list fixtures.
- **B**: Playwright against LuCI on G.

| ID | Contract item | Test (must assert) | Env | Where |
|---|---|---|---|---|
| T01 | §8.3 grammar | every example line parses to the expected fields; `LOST` adds to `missed`; non-`dnsmasq[` tags ignored | N | `test/unit/querylog*.test.mjs` |
| T02 | §8.3 rejection, raw strings | spoofed labels, `<name unprintable>`, extra tokens, uppercase, `not implemented` rejected; answers and names kept byte-for-byte (an HTML-looking PTR answer stays raw) | N | `test/unit/querylog*.test.mjs` |
| T03 | §8.3 table and correlation | each table row → decision/source; local names; `duplicate` ignored; first terminal wins, CNAME chain adds answers (≤ 4); orphans ignored; 10 s log-time TTL → `no-answer`; reset on `started, version`; router rows flagged and hidden | N | `test/unit/querylog*.test.mjs` |
| T04 | §8.1 cursor | `nextRequest` stays in 16..900, 900 first, never 0; adaptive N; gap → one refetch, remaining gap → `missed`; `lastId < cursor` → reset; ≤ 500 rows; `stats()` | N | `test/unit/querylog*.test.mjs` |
| T05 | §8.3 port | one-time differential: api-1 ucode `logparse`+`stats` vs `querylog.js` over the dnsmasq fixtures, same decision per key | N | `test/fixtures/logread/differential/` |
| T06 | D1, P1 | 0 package processes and no procd instance in every state: default, `query_logging` 0/1, settings save, restart, stop, after boot with `query_logging=1`; an `instance.update` firing costs one process | G | `test/guest/logging-lifecycle.sh`, `test/guest/logging-logd-restart.sh`, `test/guest/dataplane-boot.host.sh`, `test/guest/perf-p1-disabled.sh` |
| T07 | §4 stale scope, loop guard | only procd dnsmasq instance pids and their jailed children are compared; one stale restart per logd socket; a foreign dnsmasq with a different `/dev/log` (own root) never restarts dnsmasq and causes no loop | U+G | `test/ucode/logging/system.test.uc`, `test/guest/logging-logd-restart.sh` |
| T08 | §4, §5, P10 | drop-in set for reconcile/disable/disabled instances/dhcp `logqueries` (also handed over through the trigger); a damaged drop-in is rewritten; dnsmasq restarts exactly once per set change, never on a settings-only save, `restart`, `reload` or at boot; `write-failed` exit; `/etc/config/dhcp` byte-identical | U+G | `test/ucode/logging/system.test.uc`, `test/ucode/logging/script.test.uc`, `test/guest/logging-lifecycle.sh`, `test/guest/dataplane-boot.host.sh` |
| T09 | §8.1 live | with the drop-in, real queries from a LAN source appear in `log read` (query, blocked `config`/addnhosts, `reply`, `cached` lines) with consecutive ids; none with `query_logging=0` | G | `test/guest/dataplane-live.host.sh` |
| T10 | §8.1 bound | `log_size=1024`, ~1000-byte lines: `log read` with `lines:900` succeeds through `/ubus` and the CLI, reply < 1 MiB, logd stays on ubus | G | `test/guest/logd-oversize.host.sh` |
| T11 | §6.1 | `info` fields (`api` 2, `monitor`, `local_domains`, `protected_suffixes`, `logd`), warnings for `log_file`, `log_ip`, dhcp `logfacility`/`logqueries`; through LuCI sessions | U+G | `test/ucode/actions/plugin.test.uc`, `test/guest/actions-api.sh`, `test/guest/actions-session.host.sh` |
| T12 | §6.4–6.5 | grammar, normalization, protected set (incl. heartbeat and list hosts), PSL guard lists (positive and negative), only `allow`/`block` | U | `test/ucode/actions/domain.test.uc` |
| T13 | §6.6 | plan table, conflicts, `allow-overrides`, noop, mode selection, ops other than `allow`/`block` rejected | U | `test/ucode/actions/plan.test.uc` |
| T14 | §6.3 pipeline | each error code from a real `ubus call`, in step order (the first failing step wins); `dry_run` has no side effects; `pending-uci-changes`; a LuCI session's staged change is not committed; reply shapes; P8 | U+G | `test/ucode/actions/plugin.test.uc`, `test/guest/actions-api.sh` |
| T15 | §7 allow | allow of a listed name: UCI persisted, one dnsmasq restart, one adblock-fast run, DNS answer flips, job `applied` | G | `test/guest/actions-jobs.sh` |
| T16 | §14.1 collateral | allow `ads.example.com` with `bads.example.com` listed: `ads` resolves, `bads` stays blocked; upstream `allow` defects recorded | G | `test/guest/actions-jobs.sh` |
| T17 | §7 rebuild, §7.2 verification | block, allow of a manual block, block of a manual allow: one `dl` each, `queued→applying→verifying→applied`; reboot → UCI persists, `job` is `null`; jobs in `dnsmasq.addnhosts` (exact names), `dnsmasq.ipset`/`dnsmasq.nftset` (`unverified`, `dns-mode-unsupported`); `parent-blocked`, `still-listed`, `not-blocked`, `dns-error` verdicts | U+G | `test/ucode/actions/plan.test.uc`, `test/guest/actions-jobs.sh`, `test/guest/actions-reboot.host.sh` |
| T18 | §7.2 failure | list server down → `failed/rebuild-failed`, `persisted:true`; "Run rebuild" recovers | G | `test/guest/actions-jobs.sh` |
| T19 | §7.2–7.3 | second apply → `busy`; a fresh queued job → `busy` with its id; the job waits while another adblock-fast CLI run is alive; `kill -9` of the job → `interrupted`; `start-timeout`; `lock-failed` | U+G | `test/ucode/actions/plugin.test.uc`, `test/guest/actions-jobs.sh` |
| T20 | §10 | a committed `allowed_domain` change picked up by `reload_config`, `reload` or `restart` leaves the name blocked; only `dl` rebuilds | G | `test/guest/actions-upstream-reload.sh` |
| T21 | §9 | for a read+write app login and the read-only login: `log read`, `info`, `job`, `uci get adblock-fast-monitor` allowed; `uci get adblock-fast` refused; `log write` and `/ubus/subscribe/log` refused (root's subscription streams as a control); `apply` allowed for admins, denied read-only; `uci set` denied as granted; a login without this app's ACL gets no menu entry and `-32002` on `info`, `job` and `log read` | G | `test/guest/package-acl.host.sh`, `test/guest/actions-session.host.sh` |
| T22 | §2 install | LuCI Software upload with the key added through LuCI (no `--allow-untrusted`) → methods work without a manual rpcd restart; removal removes drop-ins (one dnsmasq restart), files, the `rc.d` link and the runtime state | B+G | `test/browser/install-luci.spec.mjs` (`scripts/release/verify-luci-install.sh`), `test/guest/package-remove.host.sh` |
| T23 | §8.5 | each page state rendered from a real guest condition | B | `test/browser/` |
| T24 | §8.4 | staging persists across reload; Allow/Block row buttons; one `apply` per batch; confirm modal for rebuild; job progress; failed items return to pending | B | `test/browser/` |
| T25 | §8.4, §9 | a read-only user sees no write controls; Settings loads and saves for an admin | B | `test/browser/` |
| T26 | §11 | P-budgets measured on the guest with raw results recorded; gate verdict per metric | G | `scripts/integration/measure-performance.mjs` |
| T27 | §8.3 untrusted strings | a logged PTR answer like `<img/src=x/onerror=window.__x=1>` is shown as literal text, no `<img>` in the DOM, `window.__x` undefined | B | `test/browser/` |
| T28 | §8.1, P2 | a hidden page makes 0 requests over 60 s; polling resumes when visible | B | `test/browser/` |
| T29 | §8.1 gaps | under load the shown missed count equals the id gap; a `log` restart resets the cursor | B+G | `test/browser/` |
| T30 | §2 upgrade | `apk upgrade` from an older api-2 package over a signed feed: changed conffile kept, drop-ins kept, 0 dnsmasq restarts, the last job still reported, caches cleared, rpcd reloaded, the `instance.update` trigger runs `logging.uc reconcile` | G | `scripts/release/verify-upgrade.sh` → `test/guest/package-upgrade.host.sh` |
| T31 | §2 inventory | dependencies, modes, owners, conffile defaults, sysupgrade keep list | G | `test/guest/package-files.host.sh` |
| T32 | §4 logd restart | `/etc/init.d/log restart` and a System → Logging save: with `query_logging=1` dnsmasq is restarted once and queries reach `log read` again, an unrelated service restart restarts nothing; with `query_logging=0` no trigger and no restart; `dnsmasq_log_stale` against a fake `/proc` | U+G | `test/ucode/logging/system.test.uc`, `test/guest/logging-logd-restart.sh` |

---

## 14. Risks and deviations found while verifying upstream facts

1. **adblock-fast `allow` is defective (verified on the 25.12.6 guest).** Its
   sed address `\:/\(/D\|.D\):d` starts with a literal `/`, so it never
   deletes `server=/D/` (or `local=/D/`, and nothing in addnhosts files): D
   stays blocked. It does delete names that are D with one extra leading
   character (allowing `ads.example.com` unblocks `bads.example.com`), and it
   publishes an empty `status`. Every change is applied with one rebuild
   (§6.6, §7.2); the job never calls `allow` (T16).
2. **adblock-fast `reload`/`restart` absorb list changes without rebuilding**
   (§10, T20). Don't replace Apply with LuCI's Save & Apply of adblock-fast's
   lists; the job runs `dl`.
3. **XSS through logged answers.** dnsmasq passes printable HTML in PTR
   target names into the log, and LuCI turns a string child of `E()` into
   innerHTML. Every dynamic cell is rendered as text (§8.3, T02, T27).
4. **ACL scope.** `log read` exposes the whole system log to anyone with this
   app's read grant (D6). Accepted: the app is for admins, like
   luci-app-adblock-fast and the System Log page. If non-admin viewers must
   ever be supported, add a plugin method that returns only `dnsmasq[` lines
   with client addresses stripped instead of granting `log read`.
5. **Short window and gaps.** About 230–570 queries in the default 128 KiB
   ring (half that in 64 KiB), shared with every other daemon; at 50 qps
   that is 5–11 s, so the page polls every 2 s while visible; at 200 qps
   gaps can't be avoided. The page shows the span, the missed count and the
   ring size, and never changes `/etc/config/system` (§8.1, T29).
6. **Oversized replies.** A `log read` reply over 1 MiB would disconnect logd
   from ubus; `lines ≤ 900` keeps the worst case below the cap (T10).
7. **Hidden tabs.** LuCI's `poll` doesn't pause hidden tabs; the view adds and
   removes its poll on `visibilitychange` (P2, T28).
8. **Correlation after a port.** The grammar and table moved from ucode to
   JS; a one-time differential test against the api-1 ucode (T05) guards the
   port. The serial restarts with every dnsmasq restart, so correlation
   resets on `started, version` and pending entries expire by log time.
9. **`pending-uci-changes` sees only `/tmp/.uci`.** It catches uncommitted
   CLI/script changes and adblock-fast's own deltas that `dl` would read. It
   cannot see changes a LuCI user staged but did not apply: rpcd keeps those
   per session in `/var/run/rpcd/uci-<sid>`. They are not committed by
   `apply` (it commits through its own savedir) and LuCI applies them later
   on top of the committed file. UI text must not claim that "unsaved LuCI
   changes" are detected (§6.3).
10. **`dnsmasq.ipset` and `dnsmasq.nftset` don't block at the DNS layer,** so
    the log can't show their blocks. smartdns and unbound are out of scope.
11. **Verification by DNS alone can't tell an upstream NXDOMAIN from a local
    one.** `observed` combines the answer with output-file membership (§7.2).
12. **A `reload_config` or LuCI `uci.apply` for adblock-fast between `apply`
    and the end of the job** would start a concurrent adblock-fast reload;
    the job detects it only through status checks.
13. **Starting at `START=18`** relies on logd and ubus being up (procd starts
    them earlier); verified at boot (T08).
14. **luci-app-adblock-fast's own logging toggle** writes `dhcp` `logqueries`
    and restarts dnsmasq; its status only reads `logqueries`, so it shows
    "Disabled" while our drop-in logs. `info.dnsmasq.instances[].uci_logqueries`
    lets the page show which mechanism is active; our drop-in is skipped for
    an instance that already has `logqueries=1`.
15. **A logd restart silences the jailed dnsmasq** (§4): the jail keeps the
    old `/dev/log` inode. Mitigated by the `instance.update` trigger, which
    costs one dnsmasq restart per logd restart while `query_logging=1` (P10
    exception, §11; T32). Restarts of other services run one short-lived
    `logging.uc reconcile` that changes nothing. Only the procd dnsmasq
    service is compared and restarted at most once per logd socket, so a
    dnsmasq outside it (chroot, container) can't cause a restart loop (T07).
