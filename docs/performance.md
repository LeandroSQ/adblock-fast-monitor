# Performance and resource budgets (P0)

Resource use is a P0 requirement: the package must not waste a small
router's memory, CPU or wakeups. The package has **no resident process**:
the browser reads logd's ring with `log read` and parses it itself, so what
is measured is (a) that nothing of ours runs on the router, (b) what query
logging costs dnsmasq and logd, and that the package adds nothing to it,
(c) what one open page costs uhttpd, ubusd, logd and rpcd, and (d) what
parsing costs in the browser. This document defines how the budgets of
[`CONTRACT.md` §11](CONTRACT.md#11-performance-budgets) are measured (test
T26), why each number is what it is, and what has been measured.

## Running it

```sh
# Measurement of record on an Apple-silicon Mac (hardware acceleration):
brew install qemu                          # once
scripts/perf/armsr/prepare-baseline.sh     # once, ~1 min
ABFM_PERF_GUEST=armsr-hvf npm run test:performance:measure -- path/to/package.apk   # ~35 min

# Smoke test of the harness (x86/64 guest; KVM on Linux, TCG elsewhere):
npm run test:performance:measure -- path/to/package.apk                            # ~35 min under TCG

node scripts/performance-gate.mjs .local-validation/perf/<run>   # re-evaluate a run
```

The APK must be inside the worktree or `.local-validation/`.
`scripts/integration/measure-performance.mjs` boots a fresh guest without
installing the package, runs `scripts/perf/run.sh` against it, so the stock
system is measured before the package is installed, and then runs the gate.
The exit code is the verdict. `npm run test:performance` without a run
directory prints `SKIP` and exits 0 (the CI host job has no guest); with
`PERFORMANCE_REQUIRE_MEASURED=1` it evaluates the newest run and fails if
there is none. The gate's own logic is unit-tested on synthetic run
directories (`test/unit/perf-gate.test.mjs`, part of `npm run test:unit`).

The harness expects from the package: the UCI switch `query_logging`, the
drop-in `adblock-fast-monitor.conf` in each dnsmasq confdir, `info` and
`apply` on `luci.adblock-fast-monitor`, the overview page polling `log read`
every 2 s while visible, and the `abfm-poll` measure (P4, below).

Tuning (environment): `ABFM_PERF_GUEST` (`x86`, the default, or
`armsr-hvf`), `ABFM_PERF_REPEATS` (default and minimum 3),
`ABFM_PERF_LOAD_SECONDS` (30), `ABFM_PERF_HIDDEN_SECONDS` (60, never less),
`ABFM_PERF_QPS` (`"50 200"`), `ABFM_PERF_SETTLE_AGE` (20 s: the dnsmasq age
at which every alternation state starts), `ABFM_PERF_PAGE` (the LuCI page
the browser opens; default
`/cgi-bin/luci/admin/services/adblock-fast-monitor/overview`),
`ABFM_PERF_SKIP_BOOT=1` (skips the two power cycles: P10 and P1 report
`NOT_MEASURED`), `ABFM_PERF_SKIP_BROWSER=1` (skips Playwright: P2–P4 report
`NOT_MEASURED`). `GUEST_ACCEL`, `GUEST_CPUS` (2) and `GUEST_MEMORY`
(256 MiB) come from the guest library.

Output: `.local-validation/perf/<run>/raw/*.json` (every snapshot, window,
load run, browser session and RPC timing, unreduced), `run.json` (index,
harness errors), `summary.json` (all derived numbers with the raw file names
behind each metric, and the invalid windows) and `verdict.json`
(`PASS`/`FAIL` per metric plus the noise block). A metric that cannot be
measured is `NOT_MEASURED`, which fails the gate.

## Guests

| `ABFM_PERF_GUEST` | Guest | Accelerator | Role |
| --- | --- | --- | --- |
| `armsr-hvf` | OpenWrt 25.12.6 `armsr-armv8` (`generic-ext4-combined-efi`, sha256 pinned from the release's `sha256sums`) + adblock-fast 1.2.4-r4 from the official `aarch64_generic` feed; `qemu-system-aarch64 -M virt -accel hvf -cpu host`, UEFI (QEMU's `edk2-aarch64-code.fd`), natively on macOS, no Docker | Apple Hypervisor.framework (`hvf`); `GUEST_ACCEL=tcg` forces emulation | run of record on an Apple-silicon Mac (accelerated budgets) |
| `x86` (default) | OpenWrt 25.12.6 `x86/64` + adblock-fast 1.2.4-r4 (the guest-suite baseline, `scripts/guest/prepare-baseline.sh`) | KVM when `/dev/kvm` is usable (Linux, CI hosts), otherwise TCG (in Docker on macOS) | TCG: smoke run (P5/P6 reported, not gated); KVM: gated on the top-level budgets |

The package is `PKGARCH:=all`, so the same APK installs on both. Both
guests have 2 vCPUs, 256 MiB, QEMU user networking and logd's default
128 KiB ring, and run the same probe, fixtures and gate. The armsr guest
library (`scripts/perf/armsr/lib.sh`) keeps the API of
`scripts/guest/lib.sh` and replaces only the image, the host checks and
the QEMU command line; `scripts/perf/armsr/run-guest.sh CMD PKG.apk` is its
counterpart of `verify-guest.sh --no-install --no-tests --host-cmd`. It
uses Playwright browsers from `.local-validation/playwright-darwin-arm64`.
With Node 26, Playwright 1.55's `install` can hang while unpacking; the
archives (`chromium`, `chromium-headless-shell` and `ffmpeg` for the
pinned revision, from Playwright's CDN) can be unpacked there by hand,
each with an empty `INSTALLATION_COMPLETE` file.

TCG emulates every guest instruction and context switch, so it inflates
CPU numbers and their noise, and the inflation is worst for what P6
measures (many small syslog writes and wakeups); see the results below.

## Files

| Path | Role |
| --- | --- |
| `scripts/integration/measure-performance.mjs` | entrypoint: guest run + gate |
| `scripts/perf/run.sh` | host-side driver, phases below |
| `scripts/perf/armsr/lib.sh`, `prepare-baseline.sh`, `run-guest.sh` | the hardware-accelerated armsr-armv8 guest (above) |
| `scripts/perf/browser.mjs` | Playwright driver: the real LuCI page, logged in as `root`; request counter, hidden/closed phases, `abfm-poll` marks, querylog module timing |
| `scripts/perf/guest/probe.uc` | guest probe (ucode, stock `fs`/`ubus` only): `/proc` snapshots of every task, measurement windows, 100–250 ms process watch, timed ubus calls, rpcd responsiveness probe, `log read` latency |
| `scripts/perf/guest/lib.sh` | guest helpers (BusyBox ash): fixtures, install, query logging and settings saves through `reload_config`, the hand-written drop-in, equal-age dnsmasq restarts, restart counting |
| `scripts/perf/dnsload.mjs` | open-loop UDP DNS load generator with per-query latency |
| `scripts/perf/budgets.json` | the numbers of §11 |
| `scripts/performance-gate.mjs` | reduces raw data to P1–P8, P10 and judges them |
| `scripts/perf/ab-dnsmasq.sh` | P6 attribution: dnsmasq and logd CPU with no drop-in, the package's drop-in written by hand, and the package, on one guest |
| `test/guest/perf-p1-disabled.sh` | P1 in the regular guest suite (`verify:guest`): no package process with `query_logging` 0 and 1 |
| `test/unit/perf-gate.test.mjs` | the gate on synthetic run directories (P1, P2, P6, P10, window validity, `NOT_MEASURED`) |

## Method

### Fixtures

- No WAN: `perf_prepare` starts a second dnsmasq on `127.0.0.1:5300` that
  answers `*.perf.test` with `192.0.2.1` and adds a drop-in `abfm-perf.conf`
  to the system dnsmasq (`server=/perf.test/127.0.0.1#5300`,
  `rebind-domain-ok=/perf.test/`, `local=/perf-block.test/`); `sysntpd` is
  stopped so no background query or log line disturbs a window.
- Queries come from the host through the QEMU port forward, so dnsmasq sees
  the LAN address `10.0.2.2`. The mix is deterministic: 50 % unique names
  (`query` + `forwarded` + `reply`), 30 % 20 cached names (`query` +
  `cached`), 20 % unique blocked names (`query` + `config … is NXDOMAIN`):
  about 2.5 log lines per query. Every reply is checked.
- The browser is headless Chromium (Playwright 1.55, the repository's
  devDependency). It runs on the host, so its own CPU is not the router's;
  requests reach uhttpd through QEMU user networking like a LAN client. It
  logs in as `root` with the per-run password, as an admin would.

### Phases (`scripts/perf/run.sh`)

1. **Browser preparation** (`npm ci` if needed, `playwright install
   --with-deps chromium`), before anything is measured.
2. **Stock**: three `/proc` snapshots 5 s apart, before installation.
3. **Install** (`apk add --allow-untrusted`). With `query_logging=0`: a
   15 s `/proc` watch every 250 ms and three snapshots; the same with
   `query_logging=1`, whose drop-in is then copied for the manual state.
   Switches go through `uci commit` + `reload_config` (what LuCI's Save &
   Apply does), then the harness waits until the dnsmasq and package pid
   sets are stable for 5 s.
4. **Alternation**, `REPEATS` (≥ 3) times, four states, each at both rates
   (50, 200 qps): query logging **off**; **manual** (query logging off and
   the package's drop-in written by hand into each confdir: dnsmasq's own
   query logging with no package involvement); **on** with no page; **on
   with one visible page** (a fresh browser per repeat, logged in,
   polling). The order rotates every repeat (off, manual, on, page; then
   manual, on, page, off; …). Every state starts with a dnsmasq restart and
   waits until dnsmasq is `SETTLE_AGE` (20) s old and the pid sets are
   stable, so neither restart age nor host drift favours a state. Each load
   run is a 3 s warm-up, then the guest opens a window (snapshot, sleep,
   snapshot) while the host sends `LOAD_SECONDS + 4` s of queries. After
   the on state, `log read` latency is measured under each load (below).
5. **P2**: a fresh browser opens the page (visible control 12 s), hides it
   for 60 s, shows it again (polling must resume), closes it and waits 60 s.
6. **Settings save** of an option that does not touch query logging
   (`perf_save_probe=1`, then deleted the same way), 20 timed `info` calls,
   then 10 `apply` dry runs and one real `apply` while a separate process
   calls rpcd's `session list` every 20 ms for 12 s and records the worst
   latency (how long rpcd's single-threaded loop was blocked). The job is
   awaited before anything else is sampled.
7. **Boot**: power-cycle with `query_logging=1`, then with `0` (poweroff,
   then a fresh QEMU on the same overlay). Each boot: a 45 s watch at
   100 ms started from `/etc/rc.local` during boot (the boot window; with
   hvf the first SSH login comes after the trigger has fired), dnsmasq
   starts since boot, three snapshots, then a 60 s watch at 100 ms once
   boot has settled (idle).

### Metric definitions

- **Package processes** = every process whose command line names
  `adblock-fast-monitor`, plus their descendants. P1 collects them from
  every snapshot and watch of every state (installed off/on, all load
  windows including the page runs, both boots) and from the settled state
  after every switch and restart. Installed snapshots are also compared
  with stock: any new userland command line counts. `job.uc` may run only
  during an Apply, and no sample is taken before the job has finished.
  They split into two classes:
  - **transient init invocations**: `rc.common` running
    `/etc/init.d/adblock-fast-monitor` or its `/etc/rc.d` link, and
    `logging.uc` (which the init script and its trigger run), that
    lives ≤ 10 s, with all its descendants (rc.common's `running` check
    runs `ubus` and `jsonfilter`). The watch records every pid with its
    parent and first/last sighting; an invocation is a top-level one (its
    parent is not another package process, so `reload` → `running` counts
    once) and its wall time is last − first sighting + one scan interval.
    They are counted per boot window and in the idle watches (installed
    off/on, 60 s after each boot has settled); a sighting in any snapshot
    or settled state is idle. procd's rcS starting the service at boot
    (`/etc/rc.d/S18adblock-fast-monitor boot`, §4) is counted apart, as the
    boot start (≤ 1 per boot); the ≤ 2 budget covers the rest (procd's
    `running` check and the trigger's firing).
  - **resident**: everything else, and any init invocation or descendant
    living > 10 s.
- **rpcd RssAnon** = median rpcd `RssAnon` installed (logging off and on)
  minus stock; the rpcd plugin is loaded into rpcd's heap once.
- **CPU %** = Δ(`utime`+`stime`) of the selected processes between the two
  snapshots of a window ÷ `USER_HZ` (100) ÷ wall seconds, in percent of one
  CPU. Ticks are 10 ms, so a 30 s window resolves 0.03 %.
- **System total and window validity.** The probe snapshots every task,
  kernel threads included. A window's system total is Δ over all tasks of
  `utime`+`stime`+`cutime`+`cstime` (a task that exits inside the window is
  counted through its parent's `cutime`/`cstime` once reaped; its share
  before the first snapshot is subtracted with the first sum). This is the
  same runtime-based accounting as the per-process numbers; `/proc/stat`'s
  sampled busy ticks are reported only (under hvf they read 5–10× lower
  than the tasks' own times). A window is **invalid**, and left out of
  every median, when the processes the gate measures add up to more than
  the system total, or the total to more than the guest's CPUs, each with
  one tick of rounding per process. `summary.json` lists invalid windows; a
  metric with fewer than 3 valid windows per state is `NOT_MEASURED`.
- **P3 CPU delta** = median over repeats of uhttpd + ubusd + logd + rpcd
  CPU in the page windows minus the same in the no-page windows, same rate.
  The gate requires the page to have polled at least every 4 s during the
  hold (half the 2 s schedule; requests closer than 700 ms are one poll),
  else P3 is `NOT_MEASURED`.
- **`log read` latency** (P3): the guest probe calls `log read {lines:N,
  stream:false, oneshot:true}` over ubus exactly as the page does. It first
  reads the newest id twice 2 s apart (one poll of the logged traffic) and
  derives the page's adaptive N = clamp(⌈1.2 × batch⌉ + 16, 16, 900): N ≈ 316
  at 50 qps, 900 at 200 qps. It then alternates 20 calls at that N and 20
  at N = 900, 250 ms apart. p95 per repeat; the gate takes the median. The
  incremental budget applies when N < 900, otherwise the N = 900 budget.
  The browser's own HTTP round trip of every `log read` (through uhttpd and
  rpcd's session check) is recorded too (`page_polling`, informational).
- **P2 requests** = every request of the browser context (any URL) that
  starts after the page was hidden / closed. The hide uses a real
  background tab when headless Chromium reports the page `hidden` after
  another tab is brought to front; otherwise Page Visibility emulation
  (`document.visibilityState`/`document.hidden` overridden, a
  `visibilitychange` event dispatched), which is what the page's handler
  reacts to. The method used is recorded. The visible control must show
  requests (the counter works) and polling must resume within 15 s of the
  page becoming visible. uhttpd/rpcd/ubusd/logd CPU ticks over both windows
  are recorded from the router side (informational).
- **P4 browser time** comes from the page itself. For every `log read`
  reply that the page keeps (with a gap refetch, the refetch's reply), it
  records one `performance.measure('abfm-poll', {start, end, detail:
  {entries, rows, changed, shown}})`. `start` is `performance.now()` when the
  reply has arrived (network time excluded); `end` is taken in a task
  queued from the next `requestAnimationFrame` callback after all DOM
  updates of that poll, so the measure spans parse + classify + stats +
  incremental table update + style, layout and paint of the next frame.
  `entries` is the reply length, `rows` the rows kept, `changed` the table
  rows created or removed (0 on an idle poll), `shown` the rows in the DOM
  (one page, at most 50). A measure is dropped when
  the page was hidden before the frame ran. At most 1000 measures are
  kept; no marks are left behind. The gate takes the p95 over **all**
  measures of the run (and requires at least one with ≥ 810 entries, so
  the full first load is included), with the browser under a 4× CPU
  throttle (CDP `Emulation.setCPUThrottlingRate` rate 4). The page pauses
  polling after 15 minutes without input, so the driver moves the mouse
  every 5 minutes during a hold. Without marks the gate falls back to the
  querylog module (`adblock-fast-monitor/querylog.js`) timed in the page
  on a real 900-entry `log read` reply fetched with the page's session:
  `create` + `ingest` + `rows` + `stats`, 20 times; the verdict then says
  "module only (no render)".
- **dnsmasq restarts** = dnsmasq `started, version` lines logged after a
  marker that precedes the action (the logd ring wraps under load).
  Boot counts all such lines since boot; the budget is on-boot minus
  off-boot.
- **Latency** (P5) = per-query round trip at the load generator, including
  QEMU user networking. p95 per run; delta = median(on p95) − median(off
  p95); noise floor = the larger p95 spread (max − min) of either state.
  On minus manual is reported too.
- **P6** has two conditions per process and rate: query logging's cost
  (median on − median off) within the budget, and the package's own share
  (median on − median manual) ≤ the run-to-run noise of those two states
  (the larger spread, at least 0.5 pp). The second is the attribution
  test: what the package adds beyond dnsmasq's own query logging must not
  be distinguishable from noise.
- **Noise**: `verdict.json` reports, per rate, the run-to-run spread over
  the repeats of P3 CPU (page and no page), `log read` p95 (incremental and
  N = 900), P5 p95 (off and on) and P6 CPU per process (off, manual, on).
  Compare a delta with them before reading anything into it.

## Budgets

All CPU figures are percent of one CPU of the measurement guest. Absolute
times and CPU shares depend on the accelerator, so `scripts/perf/budgets.json`
holds top-level numbers and an `accelerators` block the gate applies by the
run's recorded accelerator:

- **hvf** (armsr-armv8, Apple silicon) is the **run of record**. It
  overrides P3 CPU (1 / 2 pp), the P5 floor (2 ms) and P6 (4 / 6 pp for
  every process, dnsmasq included) with the tighter numbers its
  measurements support (Measured results).
- **tcg** is a **smoke run**: P5 and P6 are judged against the top-level
  (TCG-calibrated) numbers and reported, marked `[report only]`, but do not
  decide the verdict, because TCG inflates query logging's cost several
  times over. Every other metric gates.
- Any other accelerator (KVM) uses the top-level numbers for every metric.

`verdict.json` and `summary.json` record `of_record`, `report_only` and the
budgets applied. The absolute-time budgets (`log read`, P7, P8) are the same
everywhere: an M4 core is several times faster than a typical router's, so
they are not tightened from hvf numbers. Budgets change only with measured
data recorded below. In the table, the hvf number comes first and the
top-level number follows in brackets where they differ.

| ID | Budget (gate) | Why this number |
| --- | --- | --- |
| P1 | 0 resident package processes in every sample of every state (**hard**); transient init invocations ≤ 2 per boot window plus ≤ 1 boot start, and 0 while idle; rpcd RssAnon growth ≤ 1024 KiB | Nothing of the package stays running; the only cost allowed is the rpcd plugin in rpcd's heap. At boot procd's rcS starts the service once (`S18… boot`: it reconciles the drop-ins and registers the triggers, §4) and procd then runs its `running` check. With query logging on, the procd `instance.update` trigger (§4: re-attaches dnsmasq to a restarted logd) fires 3 s after the last instance start or stop; the 3 s debounce collapses the boot burst into one firing, which runs `logging.uc reconcile`. So a boot is one boot start plus at most two invocations (`running`, one firing); when nothing starts or stops, nothing may run. Measured under TCG (run `20261111T231647Z-53299`, watch from `S11`): logging on, boot start 0.2 s, `running` 0.1 s, the firing 10 s later; logging off, boot start and `running`; 0 in both 60 s idle watches after boot and in the installed watches. Under hvf the firing is shorter than the watch's 100 ms scan and is not seen (Known gaps). |
| P2 | 0 requests in 60 s hidden, 0 in 60 s closed (**hard**) | LuCI's `Poll` never pauses for hidden tabs; the page must remove its poll on `visibilitychange`. |
| P3 | uhttpd+ubusd+logd+rpcd CPU with one visible page polling every 2 s minus the same load with no page ≤ 1 / 2 pp at 50 / 200 qps [2 / 6 pp]; `log read` p95 ≤ 50 ms at the adaptive N (< 900), ≤ 150 ms at N = 900 | A resident `logread -f` reader (the obvious alternative design, measured in an earlier prototype) alone cost 3.4 / 8.1 % at 50 / 200 qps under TCG (run `20261110T195320Z-79115`); a page must cost less than that while open, and nothing when closed. A poll is one `log read`, all in C plus rpcd's session check. Under hvf the page measured +0.07…+0.10 / +0.10…+0.20 pp in three runs, so 1 / 2 pp leaves ≥ 5× margin. |
| P4 | `abfm-poll` p95 ≤ 20 ms at ≥ 810 entries; ≤ 500 rows kept | One poll every 2 s: 20 ms is 1 % of one browser core, and a 900-entry first load stays within about one 60 Hz frame (16.7 ms) plus layout. |
| P5 | median(on p95) − median(off p95) ≤ max(2 ms [3 ms], noise floor), ≥ 3 runs per state and rate, loss ≤ 0.5 % | "Within noise", with the noise floor measured in the same run. The 3 ms floor is the TCG cost of query logging itself (dnsmasq's syslog write per line): +1.95 and +2.23 ms p95 at 50 qps in two TCG runs, plus the on-state spread (≈ 1.2 ms), rounded down. Under hvf the delta is −0.40…+0.14 ms with spreads ≤ 0.62 ms (three runs), so the original 2 ms floor holds there. |
| P6 | per process (logd, dnsmasq, rpcd, uhttpd, ubusd): on − off ≤ 4 / 6 pp at 50 / 200 qps [4 / 12 pp, dnsmasq 10 / 12 pp]; RssAnon delta ≤ 256 KiB; and on − manual ≤ the run-to-run noise of those two states (≥ 0.5 pp) | Query logging is the feature, and its cost is dnsmasq's own: one syslog datagram per log line, which logd receives. The on − manual condition checks exactly that: the package's drop-in written by hand, with the package's switch off, costs what the package costs. The dnsmasq 10 pp ceiling at 50 qps is the TCG figure (+7.9 pp medians with ≈ 2 pp spread, run `20261111T032551Z-32856`): TCG inflates the context switches each syslog write causes. Under hvf the same cost is dnsmasq +0.60…+0.67 / +2.06…+2.10 pp and logd +0.33…+0.37 / +1.07…+1.10 pp (three runs, spreads ≤ 0.6 pp at 50 qps and ≤ 2.4 pp at 200), so 4 / 6 pp leaves ≥ 2.8× margin. |
| P7 | `info` p95 ≤ 50 ms | Cheap UCI reads, `stat` and one `service list` call (§6.1). |
| P8 | `apply` ≤ 200 ms (dry run and real) and rpcd never blocked > 200 ms (**hard**) | §6: rpcd is single-threaded. |
| P10 | dnsmasq restarts: boot 0, enabling query logging 1 (every time), a settings save 0 (**hard**) | §5. Boot is the on-boot count minus the off-boot count. |

## Measured results

Host: Apple M4 Pro (12 cores, 64 GiB), macOS. Guests 2 vCPU / 256 MiB.
APK built from `main` `29eff19` (`.local-validation/artifacts/20261111T194850Z-1`,
sha256 `9822bb4f…`), the UI before the incremental-render change, so P4 is
the old `abfm-poll` semantics. Raw data stays in the shared cache (not
committed); re-run the gate on a directory to regenerate `summary.json`.
Another unit's Docker guest tests shared the host during part of the hvf
runs.

### Final hvf run on the merged UI (per-accelerator budgets, new P4)

Run `.local-validation/perf/20261112T002608Z-78435`, APK built from r/F
`9bdc7df` (main `9fdec47` merged: the incremental table, the new
`abfm-poll` semantics and the 4× CPU throttle; artifact
`.local-validation/artifacts/20261112T001746Z-1`): **FAIL (run of record):
P4**; every other metric passes the hvf budgets.

| ID | Result | Noise (50 / 200 qps) |
| --- | --- | --- |
| P1 | 0 resident, 0 idle, rpcd RssAnon +208 KiB | |
| P2 | 0 / 0 requests in 60.1 s | |
| P3 | −0.23 / −0.63 pp (≤ 1 / 2); `log read` p95 2.0 ms (N = 316), 4.2–5.1 ms (N = 900) | CPU 0.06 / 0, 0.14 / 0.03 pp |
| P4 | **p95 114.1 ms over 120 measures (≤ 20)**: 60 at ≥ 810 entries p95 115 ms; per poll at 200 qps (900 entries, 720 rows created or removed) median 95–102 ms, at 50 qps (≈ 300 entries, ≈ 100–200 rows changed) 45–48 ms, idle polls (0 changed) 3–15 ms | |
| P5 | +0.07 / +0.10 ms (≤ 2) | 0.26 / 0.26, 0.13 / 0.14 ms |
| P6 | on − off dnsmasq +0.63 / +1.83, logd +0.40 / +1.17 pp (≤ 4 / 6); on − manual +0.03 / −0.17 pp | dnsmasq 0.27 / 0.40 pp |
| P7 / P8 | `info` p95 0.73 ms; apply 0.88 / 2.44 ms, rpcd worst 7.5 ms | |
| P10 | boot 0, enable [1, 1, 1, 1, 1], save 0 | |

The P4 budget (20 ms) was set for the former measure (parse + classify +
render, no frame, no throttle; 16.9 ms in the run below). The new measure
spans to the next painted frame under a 4× throttle, and its cost scales
with the rows the table creates and removes per poll. The budget is not
changed here; it needs a decision (a budget for the new semantics, or a
cheaper table update at high churn).

### armsr-armv8 under hvf (measurement of record, old P4 semantics)

Run `.local-validation/perf/20261111T224327Z-51761`
(`ABFM_PERF_GUEST=armsr-hvf npm run test:performance:measure`): **PASS,
all of P1–P8 and P10**, 24 load windows, none invalid.

| ID | Result | Noise (spread over 3 repeats, 50 / 200 qps) |
| --- | --- | --- |
| P1 | 0 resident in every snapshot, window and watch; 0 idle invocations; boot window: no invocation seen (shorter than the 100 ms scan, Known gaps); rpcd RssAnon +208 KiB (540 → 748) | |
| P2 | 0 requests hidden 60 s, 0 closed 60 s; visible control 7 / 12 s | |
| P3 | +0.10 pp at 50 qps, +0.13 pp at 200; `log read` p95 2.3 ms (N = 391), 4.1–5.0 ms (N = 900); the page polled every 2.03 s | CPU 0 / 0.03 pp (page / no page) at 50, 0.24 / 0.10 at 200; `log read` 0.4 / 0.4 ms, 0.7 / 0.4 ms |
| P4 | `abfm-poll` p95 16.9 ms over 60 polls (the browser runs on the host; not affected by the guest's accelerator) | |
| P5 | Δp95 +0.03 ms at 50 qps, +0.09 ms at 200 (p95 ≈ 1.2–1.8 ms); 0 loss; on − manual within the spread | p95 0.49 / 0.07 ms (off / on) at 50, 0.47 / 0.04 at 200 |
| P6 | on − off: dnsmasq +0.63 / +2.06 pp, logd +0.33 / +1.10 pp, rpcd, uhttpd, ubusd 0; on − manual: dnsmasq +0.03 / +0.13 pp, logd −0.03 / −0.13 pp (≤ 0.5 pp); RssAnon +0 / +4 KiB | dnsmasq 0.40 / 0.63 pp, logd 0.03 / 0.14 pp |
| P7 | `info` p95 0.82 ms (ubus floor 0.1 ms) | |
| P8 | apply dry max 0.75 ms, real 1.91 ms; rpcd worst 2.3 ms | |
| P10 | boot 0, enable [1, 1, 1, 1, 1], save 0 | |

Two earlier hvf runs on the same APK
(`20261111T210749Z-41290`, `20261111T214443Z-45782`) agree on every CPU and
latency number above within the spreads (P6 dnsmasq on − off +0.60 / +2.10
and +0.67 / +2.10 pp; on − manual −0.2…+0.13 pp). Their P10/P1 boot phases
exposed two harness faults, since fixed: the manual drop-in was still in
place when query logging was switched on, and dnsmasq refused the
repeated options, so 3 of 5 enables counted 0 restarts; and a serial
console Enter was lost during a cold boot.

`/proc/stat` busy ticks are unusable under hvf: for the same state they
ranged from 0.2 % to 10.8 % of one CPU while the tasks' own times summed to
a steady 1.5–7.3 % (`summary.json` → P6 → `system_total`). The gate's
system total is therefore task-based (Method).

### x86/64 under TCG (smoke test)

Run `.local-validation/perf/20261111T231647Z-53299` (default guest, same
APK, same harness, nothing else running): every gated metric passes; P5
and P6 fail their TCG-calibrated numbers, which as a smoke run are
reported only (the gate as first run, before the per-accelerator budgets,
said FAIL: P5, P6). 24 windows, none invalid.

| ID | Result | Noise (spread over 3 repeats, 50 / 200 qps) |
| --- | --- | --- |
| P1 | 0 resident; boot window with logging on: the boot start (`S18… boot`, 0.2 s) + `running` + one trigger firing (`logging.uc reconcile`, 10 s later); off: boot start + `running`; 0 idle; rpcd RssAnon +200 KiB | |
| P2 | 0 / 0 requests in 60.5 s; visible control 7 / 12 s | |
| P3 | +1.55 pp at 50 qps, +1.72 at 200; `log read` p95 32.4 ms (N = 394), 54–74 ms (N = 900) | CPU 0.19 / 0.13 pp, 0.20 / 0.54; `log read` 2.0 / 2.3 ms, 1.7 / 2.8 ms |
| P4 | `abfm-poll` p95 9.9 ms | |
| P5 | **Δp95 +3.22 ms at 50 qps (> 3)**, +0.83 at 200; on − manual −0.60 / −0.24 ms | p95 0.54 / 0.19 ms, 0.17 / 0.33 |
| P6 | on − off: **dnsmasq +10.05 pp at 50 (> 10) and +13.39 at 200 (> 12)**, **logd +4.83 at 50 (> 4)**, +10.95 at 200; on − manual: dnsmasq −1.17 / −0.68, logd −0.20 / +0.49 pp (within noise) | dnsmasq 1.45 / 1.03 pp, logd 0.16 / 0.54 pp |
| P7 | `info` p95 6.5 ms | |
| P8 | apply dry max 8.3 ms, real 27.9 ms; rpcd worst 23.3 ms | |
| P10 | boot 0, enable [1, 1, 1, 1, 1], save 0 | |

With every state now starting from a dnsmasq of the same age, TCG puts
query logging's own cost above even the TCG-calibrated P5/P6 ceilings. The
package's share (on − manual) is zero within noise here too.

### Noise: TCG and hvf side by side

Spread (max − min over 3 repeats) in the two runs of record, 50 / 200 qps:

| Number | TCG (x86/64) | hvf (armsr-armv8) |
| --- | --- | --- |
| P3 CPU, page / no page (pp) | 0.19 / 0.13, 0.20 / 0.54 | 0 / 0.03, 0.24 / 0.10 |
| `log read` p95, adaptive N / N = 900 (ms) | 2.0 / 2.3, 1.7 / 2.8 | 0.4 / 0.4, 0.7 / 0.4 |
| P5 p95, off / on (ms) | 0.54 / 0.19, 0.17 / 0.33 | 0.49 / 0.07, 0.47 / 0.04 |
| P6 dnsmasq CPU (pp) | 1.45, 1.03 | 0.40, 0.63 |
| P6 logd CPU (pp) | 0.16, 0.54 | 0.03, 0.14 |
| query logging's dnsmasq cost, on − off (pp) | +10.05, +13.39 | +0.63, +2.06 |

The noise is of the same order; what differs is the size of the effect
TCG produces. Earlier TCG runs taken while other guests and builds shared
the host showed spreads up to 3 pp (P6 dnsmasq) and 7.4 ms (P5).

### P6: dnsmasq cost of query logging (attribution)

`scripts/perf/ab-dnsmasq.sh`: package installed; arms **off**
(`query_logging=0`), **manual** (`query_logging=0` + the package's drop-in
copied by hand: dnsmasq's own query logging) and **product**
(`query_logging=1`); arm order rotated every repeat, every arm starting
from a dnsmasq restart 20 s old, 20 s windows, switches through `uci
commit` + `reload_config` only. Medians, spread in brackets:

| Guest, run | Rate | dnsmasq % off / manual / product | logd % off / manual / product | product − manual | DNS p95 ms off / manual / product |
| --- | --- | --- | --- | --- | --- |
| hvf, `ab-20261111T222121Z-9805`, 5 repeats | 50 | 1.05 (0.40) / 1.50 (0.70) / 1.40 (0.45) | 0.00 / 0.35 / 0.30 | dnsmasq −0.10 pp, logd −0.05 pp | 1.75 / 1.55 / 1.43 |
| | 200 | 2.65 (0.90) / 4.30 (0.55) / 4.14 (1.20) | 0.00 / 0.95 / 0.95 | dnsmasq −0.16 pp, logd 0.00 pp | 1.34 / 1.24 / 1.36 |
| TCG, `ab-20261111T235051Z-19814`, 3 repeats | 50 | 7.12 (0.18) / 17.85 (0.54) / 17.45 (0.96) | 0.15 / 4.89 / 4.55 | dnsmasq −0.40 pp, logd −0.34 pp | 4.40 / 8.05 / 7.51 |

No dnsmasq restart happened inside any window (pids unchanged), and no
window was invalid.

Findings:

- **The attribution holds.** The package on costs what its drop-in written
  by hand costs, within noise, on both accelerators and at both rates, for
  dnsmasq, logd and DNS latency. The cost of query logging is dnsmasq's
  own (one syslog datagram per log line, about 2.5 lines per query) plus
  logd receiving it. A user who already logs queries pays nothing more for
  the package.
- **The size of that cost is a TCG artifact.** Under hvf it is +0.4–0.7 pp
  of one CPU at 50 qps and +1.5–2.1 pp at 200 qps for dnsmasq, +0.3–0.4 /
  +1.0–1.1 pp for logd, and no measurable latency. Under TCG it is +10 pp, +4.7 pp
  and +3.1–3.7 ms: every syslog write wakes logd, and with logging on
  dnsmasq's involuntary context switches rise from 0 to 0.4–0.6 per query
  (hvf: 0.14–0.2), each of which TCG emulates expensively.
- The earlier TCG A/B (arms in a fixed order, the cheap arms measured
  longest after a dnsmasq restart, `init reload` between arms) is
  superseded by this one.

### Budgets adopted from these results

The hvf numbers support tighter budgets than the TCG-calibrated ones, and
these were adopted for the hvf run of record (`budgets.json` →
`accelerators.hvf`); TCG keeps the old numbers as a smoke run:

| Budget | Top-level (TCG, KVM) | hvf measured (3 runs) | hvf (adopted) |
| --- | --- | --- | --- |
| P5 floor | 3 ms | Δp95 −0.40…+0.14 ms; spreads ≤ 0.62 ms | 2 ms |
| P6 dnsmasq, 50 qps | 10 pp | +0.60…+0.67 pp (spread ≤ 0.54) | 4 pp |
| P6 dnsmasq / logd, 200 qps | 12 pp | dnsmasq +2.06…+2.10, logd +1.07…+1.10 | 6 pp |
| P3 CPU | 2 / 6 pp | +0.07…+0.10 / +0.10…+0.20 pp | 1 / 2 pp |

The loosened P5 (3 ms) and P6 dnsmasq (10 pp) budgets are not needed under
acceleration. The absolute-time budgets (`log read`, P7, P8) are unchanged.

### Earlier TCG results (before this harness revision)

Before the task-based system total, the manual state and the equal-age
restarts, TCG runs on the release candidates passed with the loosened
P5/P6 budgets: `20261111T051631Z-42044` (`main` `024b06c`: P5 +2.04 / +1.39
ms, P6 dnsmasq +8.34 / +7.91 pp, P3 +1.23 / +2.53 pp, P4 11.0 ms, P1
rpcd +220 KiB) and `20261111T042902Z-37426` (`7ed430e`: P5 +2.23 / +0.96 ms,
P6 dnsmasq +8.81 / +7.35 pp). An earlier prototype that ran a resident
`logread -f` reader (`20261110T195320Z-79115`) failed its own budgets
(reader CPU 11.3 / 35.6 % at 50 / 200 qps); its reader alone cost 3.4 /
8.1 %, which is the ceiling P3 is set under.

## Known gaps

- **Boot-window invocations under hvf are faster than the watch.** The
  boot watch scans `/proc` every 100 ms from `S11` on; under hvf the init
  script's boot start, procd's `running` check and the trigger's
  `logging.uc` each finish within one scan, so P1's boot counts are lower
  bounds there. TCG sees them (above) and they are within budget.
- **P4 depends on the UI hook and on the host.** Without `abfm-poll` marks
  the gate measures parse + classify only (labelled in the verdict). The
  browser runs on the host next to QEMU, so P4 is a host number.
- **hvf is not a router.** An M4 core is much faster than a typical
  router's CPU; relative costs (P5, P6, P3 CPU deltas) transfer better
  than absolute times. KVM on x86 is the other accelerated option (CI host
  class); it has not been run for this revision.
- **200 qps exceeds the ring.** At 200 qps a 128 KiB ring holds about 5 s
  of traffic, so every 2 s poll requests N = 900 and gaps are expected and
  counted by the page, not avoided.
