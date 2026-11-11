# Performance and resource budgets (P0)

Resource use is a P0 requirement: the package must not waste a small
router's memory, CPU or wakeups. Design B-min has **no resident process**:
the browser reads logd's ring with `log read` and parses it itself, so what
is measured is (a) that nothing of ours runs on the router, (b) what query
logging costs dnsmasq and logd, (c) what one open page costs uhttpd, ubusd,
logd and rpcd, and (d) what parsing costs in the browser. This document
defines how the budgets of [`CONTRACT.md` §11](CONTRACT.md#11-performance-budgets)
are measured (test T26), why each number is what it is, and what has been
measured so far.

## Running it

```sh
npm run test:performance:measure -- path/to/package.apk     # ~35-45 min under TCG
node scripts/performance-gate.mjs .local-validation/perf/<run>  # re-evaluate a run
```

The APK must be inside the worktree or `.local-validation/` (the guest runs
in Docker on non-Linux hosts). `scripts/integration/measure-performance.mjs`
boots a fresh OpenWrt 25.12.6 guest with `scripts/verify-guest.sh
--no-install --no-tests --host-cmd scripts/perf/run.sh`, so the stock
system is measured before the package is installed, and then runs the gate.
The exit code is the verdict. `npm run test:performance` without a run
directory prints `SKIP` and exits 0 (the CI host job has no guest); with
`PERFORMANCE_REQUIRE_MEASURED=1` it evaluates the newest B-min run and fails
if there is none. Runs recorded by the design A harness are refused.

The B-min result comes from an APK built from `main` with the backend,
querylog and UI work merged (`scripts/in-docker.sh --platform linux/amd64 --
scripts/build-package.sh`). The harness expects from that package: the UCI
switch `query_logging` (it falls back to `enabled` for older packages), the
drop-in `adblock-fast-monitor.conf` in each dnsmasq confdir, `info` and
`apply` on `luci.adblock-fast-monitor`, the overview page polling `log read`
every 2 s while visible, and the `abfm-poll` measure (P4, below).

Tuning (environment): `ABFM_PERF_REPEATS` (default and minimum 3),
`ABFM_PERF_LOAD_SECONDS` (30), `ABFM_PERF_HIDDEN_SECONDS` (60, never less),
`ABFM_PERF_QPS` (`"50 200"`), `ABFM_PERF_PAGE` (the LuCI page the browser
opens; default `/cgi-bin/luci/admin/services/adblock-fast-monitor/overview`),
`ABFM_PERF_SKIP_BOOT=1` (skips the two power cycles: P10 and P1 report
`NOT_MEASURED`), `ABFM_PERF_SKIP_BROWSER=1` (skips Playwright: P2–P4 report
`NOT_MEASURED`). `GUEST_ACCEL`, `GUEST_CPUS` (2) and `GUEST_MEMORY`
(256 MiB) come from `scripts/guest/lib.sh`.

Output: `.local-validation/perf/<run>/raw/*.json` (every snapshot, window,
load run, browser session and RPC timing, unreduced), `run.json` (index,
harness errors), `summary.json` (all derived numbers with the raw file names
behind each metric) and `verdict.json` (`PASS`/`FAIL` per metric plus the
noise block). A metric that cannot be measured is `NOT_MEASURED`, which
fails the gate.

## Files

| Path | Role |
|---|---|
| `scripts/integration/measure-performance.mjs` | entrypoint: guest run + gate |
| `scripts/perf/run.sh` | host-side driver, phases below |
| `scripts/perf/browser.mjs` | Playwright driver: the real LuCI page, logged in as `root`; request counter, hidden/closed phases, `abfm-poll` marks, querylog module timing |
| `scripts/perf/guest/probe.uc` | guest probe (ucode, stock `fs`/`ubus` only): `/proc` snapshots, measurement windows, 250 ms process watch, timed ubus calls, rpcd responsiveness probe, `log read` latency |
| `scripts/perf/guest/lib.sh` | guest helpers (BusyBox ash): fixtures, install, query logging and settings saves through `reload_config`, restart counting |
| `scripts/perf/dnsload.mjs` | open-loop UDP DNS load generator with per-query latency |
| `scripts/perf/budgets.json` | the numbers of §11 |
| `scripts/performance-gate.mjs` | reduces raw data to P1–P8, P10 and judges them |
| `scripts/perf/ab-dnsmasq.sh` | P6 diagnosis: dnsmasq CPU A/B on one guest (no drop-in, hand-written drop-in ± `logread -f` subscriber, the package with and without its procd trigger, the design A package) |
| `test/guest/perf-p1-disabled.sh` | P1 in the regular guest suite (`verify:guest`): no package process with `query_logging` 0 and 1 |

## Method

### Environment and fixtures

- Guest: stock OpenWrt 25.12.6 x86/64 + adblock-fast 1.2.4-r4 (the harness
  baseline image), 2 vCPUs, 256 MiB, QEMU user networking, logd ring
  `log_size=128` KiB (the 25.12 default).
- No WAN: `perf_prepare` starts a second dnsmasq on `127.0.0.1:5300` that
  answers `*.perf.test` with `192.0.2.1` and adds a drop-in `abfm-perf.conf`
  to the system dnsmasq (`server=/perf.test/127.0.0.1#5300`,
  `rebind-domain-ok=/perf.test/`, `local=/perf-block.test/`). The system
  dnsmasq is restarted once, before any measurement; `sysntpd` is stopped so
  no background query or log line disturbs a window.
- Queries come from the host through the QEMU port forward, so dnsmasq sees
  the LAN address `10.0.2.2`. The mix is deterministic: 50 % unique names
  (`query` + `forwarded` + `reply`), 30 % 20 cached names (`query` +
  `cached`), 20 % unique blocked names (`query` + `config … is NXDOMAIN`):
  about 2.5 log lines per query. Every reply is checked.
- The browser is headless Chromium (Playwright 1.55, the repository's
  devDependency; in Docker its browsers are cached under
  `.local-validation/playwright-<platform>`). It runs on the host, so its
  own CPU is not the router's; requests reach uhttpd through QEMU user
  networking like a LAN client. It logs in as `root` with the per-run
  password, as an admin would.
- Accelerator: KVM when `/dev/kvm` is usable, otherwise TCG. Apple-silicon
  hosts have no x86 KVM, so local runs are TCG.

### Phases (`scripts/perf/run.sh`)

1. **Browser preparation** (`npm ci` if needed, `playwright install
   --with-deps chromium`), before anything is measured.
2. **Stock**: three `/proc` snapshots 5 s apart, before installation.
3. **Install** (`apk add --allow-untrusted`). With `query_logging=0`: a
   15 s `/proc` watch every 250 ms and three snapshots; the same with
   `query_logging=1`. Switches go through `uci commit` + `reload_config`
   (what LuCI's Save & Apply does), then the harness waits until the
   dnsmasq and package pid sets are stable for 5 s.
4. **Alternation**, `REPEATS` (≥ 3) times, each rate (50, 200 qps) in each
   state: query logging **off**; **on** with no page; **on with one visible
   page** (a fresh browser per repeat, logged in, polling). Each load run
   is a 3 s warm-up, then the guest opens a window (snapshot, sleep,
   snapshot) while the host sends `LOAD_SECONDS + 4` s of queries.
   Alternating inside every repeat spreads host drift over all states.
   After the page state, `log read` latency is measured under each load
   (below).
5. **P2**: a fresh browser opens the page (visible control 12 s), hides it
   for 60 s, shows it again (polling must resume), closes it and waits 60 s.
6. **Settings save** of an option that does not touch query logging
   (`perf_save_probe=1`, then deleted the same way), 20 timed `info` calls,
   then 10 `apply` dry runs and one real `apply` while a separate process
   calls rpcd's `session list` every 20 ms for 12 s and records the worst
   latency (how long rpcd's single-threaded loop was blocked). The job is
   awaited before anything else is sampled.
7. **Boot**: power-cycle with `query_logging=1`, then with `0` (poweroff,
   then a fresh QEMU on the same overlay: a second warm `reboot` of one TCG
   QEMU on an arm64 host stalled after GRUB for over 10 minutes). Each
   boot: a 30 s watch at 100 ms from the first SSH login (the boot
   window), dnsmasq starts since boot, three snapshots, then a 60 s watch
   at 100 ms once boot has settled (idle).

### Metric definitions

- **Package processes** = every process whose command line names
  `adblock-fast-monitor`, plus their descendants, plus any `logread -f`
  follower and the `adblock-fast-monitor` ubus object (design A's daemon).
  P1 collects them from every snapshot and watch of every state
  (installed off/on, all load windows including the page runs, both boots)
  and from the settled state after every switch. Installed snapshots are
  also compared with stock: any new userland command line counts.
  `job.uc` may run only during an Apply, and no sample is taken before the
  job has finished. They split into two classes:
  - **transient init invocations**: `rc.common` running
    `/etc/init.d/adblock-fast-monitor` (and the `logging.uc` it starts) that
    lives ≤ 10 s. The watch records every pid with its parent and first/last
    sighting; an invocation is a top-level one (its parent is not another
    package process, so `reload` → `running` counts once) and its wall time
    is last − first sighting + one scan interval. They are counted per boot
    window and in the idle watches (installed off/on, 60 s after each boot
    has settled); a sighting in any snapshot or settled state is idle.
  - **resident**: everything else, and any init invocation living > 10 s.
- **rpcd RssAnon** = median rpcd `RssAnon` installed (logging off and on)
  minus stock; the rpcd plugin is loaded into rpcd's heap once.
- **CPU %** = Δ(`utime`+`stime`) of the selected processes between the two
  snapshots of a window ÷ `USER_HZ` (100) ÷ wall seconds, in percent of one
  CPU. Ticks are 10 ms, so a 30 s window resolves 0.03 %.
- **P3 CPU delta** = median over repeats of uhttpd + ubusd + logd + rpcd
  CPU in the page windows minus the same in the no-page windows, same rate.
  The gate requires the page to have polled at least every 4 s during the
  hold (half the 2 s schedule; requests closer than 700 ms are one poll),
  else P3 is `NOT_MEASURED`.
- **`log read` latency** (P3): the guest probe calls `log read {lines:N,
  stream:false, oneshot:true}` over ubus exactly as the page does. It first
  reads the newest id twice 2 s apart (one poll of the logged traffic) and
  derives the page's adaptive N = clamp(1.5 × batch + 16, 16, 900): N ≈ 391
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
- **P4 browser time** comes from the page itself: the UI wraps each poll's
  parse + classify + render in a performance measure named **`abfm-poll`**
  (`performance.measure('abfm-poll', {start, detail: {entries, rows}})`,
  where `entries` is the length of the `log read` reply and `rows` the
  rows kept). The gate takes the p95 of all measures with ≥ 810 entries
  (the first load is always N = 900 on a full ring; at 200 qps every poll
  is). Without marks it falls back to the querylog module
  (`adblock-fast-monitor/querylog.js`) timed in the page on a real
  900-entry `log read` reply fetched with the page's session:
  `create` + `ingest` + `rows` + `stats`, 20 times; the verdict then says
  "module only (no render)".
- **dnsmasq restarts** = dnsmasq `started, version` lines logged after a
  marker that precedes the action (the logd ring wraps under load).
  Boot counts all such lines since boot; the budget is on-boot minus
  off-boot.
- **Latency** (P5) = per-query round trip at the load generator, including
  QEMU user networking. p95 per run; delta = median(on p95) − median(off
  p95); noise floor = the larger p95 spread (max − min) of either state.
- **Noise**: `verdict.json` reports, per rate, the run-to-run spread over
  the repeats of P3 CPU (page and no page), `log read` p95 (incremental and
  N = 900), P5 p95 (off and on) and P6 CPU per process. Under TCG these
  spreads are the harness's resolution: compare a delta with them before
  reading anything into it.

## Budgets

All CPU figures are percent of one CPU of the measurement guest. A budget
measured under TCG is not transferable to KVM or real hardware; the gate
records the accelerator. Budgets change only with measured data recorded
below.

| ID | Budget (gate) | Why this number |
|---|---|---|
| P1 | 0 resident package processes in every sample of every state (**hard**); transient init invocations ≤ 2 per boot window and 0 while idle; rpcd RssAnon growth ≤ 1024 KiB | B-min has no resident process; the only cost allowed is the rpcd plugin in rpcd's heap. The init script's procd `instance.update` trigger (§4: re-attaches dnsmasq to a restarted logd) fires 3 s after the last instance start or stop. At boot procd starts every instance, and the 3 s debounce collapses that burst into one firing, which runs two top-level invocations: `reload` and then procd's `running` check. ≤ 2 is exactly one firing per boot; when nothing starts or stops, nothing may run. Measured (run `20261111T042902Z-37426`, 100 ms watch): logging on, `reload` 0.22 s + `running` 0.10 s = 0.32 s wall, 2.4 s into the window (uptime ≈ 19 s); logging off (no trigger registered) 0; 0 in both 60 s idle watches after boot and in the installed watches. |
| P2 | 0 requests in 60 s hidden, 0 in 60 s closed (**hard**) | LuCI's `Poll` never pauses for hidden tabs; the page must remove its poll on `visibilitychange`. |
| P3 | uhttpd+ubusd+logd+rpcd CPU with one visible page polling every 2 s minus the same load with no page ≤ 2 pp at 50 qps, ≤ 6 pp at 200 qps; `log read` p95 ≤ 50 ms at the adaptive N (< 900), ≤ 150 ms at N = 900 | Design A's `logread -f` child alone cost 3.4 / 8.1 % at 50 / 200 qps (run `20261110T195320Z-79115`); a page must cost less than that while open, and nothing when closed. A poll is one `log read`, all in C plus rpcd's session check. |
| P4 | `abfm-poll` p95 ≤ 20 ms at ≥ 810 entries; ≤ 500 rows kept | One poll every 2 s: 20 ms is 1 % of one browser core, and a 900-entry first load stays within about one 60 Hz frame (16.7 ms) plus layout. |
| P5 | median(on p95) − median(off p95) ≤ max(3 ms, noise floor), ≥ 3 runs per state and rate, loss ≤ 0.5 % | "Within noise", with the noise floor measured in the same run. The floor is what query logging itself costs under TCG (dnsmasq's syslog write per line). The former 2 ms came from design A measurements (+1.0 ms) that, like P6, always had a `logread -f` subscriber, which hides the cost (A/B below: hand-written drop-in +1.3 ms p95 / +1.4 ms p50, with a subscriber −0.4 ms). B-min measured +1.95 and +2.23 ms p95 (p50 +1.58 / +1.59 ms, stable) at 50 qps and +0.23 / +0.96 ms at 200 qps in two full runs; 3 ms is the larger plus the on-state spread (≈ 1.2 ms) rounded down. |
| P6 | logd, rpcd, uhttpd, ubusd: CPU delta ≤ 4 pp at 50 qps, ≤ 12 pp at 200 qps each; dnsmasq ≤ 10 pp at 50 qps, ≤ 12 pp at 200 qps; RssAnon delta ≤ 256 KiB | Query logging is the feature, and its cost is dnsmasq's own: one syslog datagram per log line. The 4 pp dnsmasq figure came from design A runs that always had a `logread -f` subscriber attached, which (measured below) hides most of that cost. Without one, the same drop-in written by hand with no package installed costs dnsmasq +7.2 pp (median, 5 repeats) at 50 qps on the same guest, and the package's +5.5 / +7.9 pp. 10 pp is the largest median measured (+7.9) plus the observed run-to-run spread (≈ 2 pp). See [P6: dnsmasq cost of query logging](#p6-dnsmasq-cost-of-query-logging). |
| P7 | `info` p95 ≤ 50 ms | Cheap UCI reads, `stat` and one `service list` call (§6.1); the ubus round-trip floor is 1–2 ms. |
| P8 | `apply` ≤ 200 ms (dry run and real) and rpcd never blocked > 200 ms (**hard**) | §6: rpcd is single-threaded. |
| P10 | dnsmasq restarts: boot 0, enabling query logging 1 (every time), a settings save 0 (**hard**) | §5. Boot is the on-boot count minus the off-boot count. |

## Measured results

Host: Apple-silicon Mac, OrbStack Docker (`linux/arm64`), QEMU **TCG**,
guest 2 vCPU / 256 MiB. Other agents' guests and builds ran concurrently,
so these numbers carry host-contention noise. Raw data stays in the shared
cache (not committed); re-run the gate on a directory to regenerate
`summary.json`.

### B-min (gate artifact, `main` `7ed430e`)

Run `.local-validation/perf/20261111T042902Z-37426` (`npm run
test:performance:measure`, APK `.local-validation/artifacts/20261111T025656Z-1`,
sha256 `a8e9da5b…`; 3 repeats × 30 s × {50, 200} qps, two power cycles):
**PASS** with the P5 and P6 dnsmasq budgets recalibrated from the
measurements in [P6: dnsmasq cost of query logging](#p6-dnsmasq-cost-of-query-logging)
(with the former 2 ms / 4 pp it fails P5 by 0.23 ms and P6 by 4.8 pp).

| ID | Result | Noise (spread over 3 repeats) |
|---|---|---|
| P1 | 0 resident processes in 48 snapshots, every window and watch; transient: one trigger firing at the logging-on boot (`reload` + `running`, 0.32 s), 0 at the logging-off boot, 0 idle; rpcd RssAnon +212 KiB (556 → 768) | |
| P2 | 0 requests hidden 60.3 s (Page Visibility emulation), 0 closed 60.3 s; visible control 7 requests / 12 s; resumed 2 ms after showing | |
| P3 | +1.26 pp at 50 qps, +2.49 pp at 200 qps; `log read` p95 24.7 ms at N = 394, 60.0 ms at N = 900 (50 qps); 50.4 / 57.4 ms at 200 qps; the page polled every 2.02 s, N 16…900 | CPU 0.13 / 0.26 pp (page / no page) at 50, 0.1 / 0.9 at 200; `log read` 0.6–2.3 ms |
| P4 | `abfm-poll` p95 13.1 ms (max 17.6) over 60 polls of ≥ 810 entries; 500 rows kept | |
| P5 | Δp95 +2.23 ms at 50 qps, +0.96 ms at 200 qps (≤ 3); p50 +1.59 / +0.20 ms; 0 loss | p95 0.25 / 1.20 ms (off / on) at 50, 0.64 / 1.53 at 200 |
| P6 | dnsmasq +8.81 pp at 50 qps, +7.35 at 200; logd +3.96 / +7.25; rpcd, uhttpd, ubusd 0 | dnsmasq 3.0 / 1.1 pp, logd 0.26 / 0.9 pp |
| P7 | `info` p95 6.2 ms | |
| P8 | apply dry max 9.8 ms, real 30.0 ms; rpcd worst 31.1 ms | |
| P10 | boot 0, enable [1, 1, 1, 1], save 0 | |

The integrator's earlier run on the same artifact,
`.local-validation/perf/20261111T032551Z-32856`, matches: P6 dnsmasq +7.91 /
+6.42 pp, P5 +1.95 / +0.23 ms, P3 +1.17 / +3.02 pp, P4 12.9 ms. Its P1
was a false FAIL (the trigger's `reload`/`running` counted as package
processes, before the resident/transient split); it predates the idle
watch, so the current gate reports it as not fully measured.

### B-min harness self-test (design A APK, before BE/QL/UI landed)

Run `.local-validation/perf/20261111T000814Z-8256` (`npm run
test:performance:measure`, 3 repeats × 30 s × {50, 200} qps per state, two
power cycles; APK sha256 `973c6867…`, the design A package of `main`
`d27b5d4`'s tree, because no B-min package existed yet). It proves the
harness end to end against a real package and the current LuCI page; the
verdict (**FAIL**: P1, P3, P4) describes design A, not B-min:

| ID | Result | Reading |
|---|---|---|
| P1 | FAIL: 61 package-process samples (`monitord.uc` + `logread -f`) in the logging-on states, 0 with logging off; rpcd RssAnon +236 KiB (556 → 792) | Detects design A's daemon in every on-state snapshot, watch and load window; B-min must show 0. |
| P2 | PASS: 0 requests hidden 60.3 s, 0 closed 60.4 s; visible control 4 requests in 12 s; resumed 7 ms after showing; router ticks uhttpd/rpcd/ubusd 0 while hidden | Hide method: Page Visibility emulation (headless Chromium keeps a background tab `visible`). |
| P3 | NOT_MEASURED: design A's page polls every 5.3 s (its `poll_interval`), not 2 s. Measured anyway: CPU delta +0.40 pp at 50 qps, +1.43 pp at 200 qps (uhttpd +0.3, ubusd +0.13, rpcd +0.5 pp); `log read` p95 29.3 ms at N ≈ 391 (50 qps), 52.8–56.6 ms at N = 900 | `log read` of 900 entries (141 KB JSON) costs about 53 ms through ubus under TCG: well inside 150 ms. |
| P4 | NOT_MEASURED: no `abfm-poll` marks and no `querylog.js` in that package | The module fallback was exercised separately on a dev guest with unit QL's work-in-progress `querylog.js` copied in: the module loaded through `L.require`, the page fetched a real reply and the timing loop ran. |
| P5 | PASS: Δp95 −6.7 ms (allowed 7.4) at 50 qps, −1.0 ms (4.4) at 200 qps; p50 +0.8 / +0.7 ms; 0 loss | Off-state p95 spread 7.4 ms at 50 qps: host contention. |
| P6 | PASS: max Δ 3.6 pp at 50 qps, 7.9 pp at 200 qps (both logd, which still served design A's `logread -f`); RssAnon +16 KiB dnsmasq | dnsmasq's off-state CPU varied 6–17 % at 50 qps (spread 10 pp). |
| P7 | PASS: `info` p95 14.7 ms (ubus floor 1.3–1.4 ms) | |
| P8 | PASS: dry run max 13.9 ms, real 56.4 ms; rpcd `session list` worst 58.3 ms | |
| P10 | PASS: boot 0, enable [1, 1, 1, 1], save 0 (and 0 for the delete) | |

**Noise (TCG, spread over 3 repeats):** P3 CPU 2.8 pp (page) / 1.7 pp (no
page) at 50 qps, 0.2 / 1.3 pp at 200 qps; `log read` p95 10.4 / 9.8 ms
(N ≈ 391 / 900) at 50 qps, 3.7 / 5.9 ms at 200 qps; P5 p95 7.4 ms (off) /
1.4 ms (on) at 50 qps, 4.4 / 0.3 ms at 200 qps; P6 dnsmasq 10.2 / 6.0 pp.
At 50 qps the P3 budget (2 pp) is of the order of the spread, so the
integrator's run should be compared with these spreads before any budget
is recalibrated.

Earlier development run `.local-validation/perf/dev-perf2-1` (10 s
windows, 50 qps, no boots) gave the same picture: P3 Δ +0.89 pp,
`log read` p95 20 / 49 ms, P2 0 / 0 requests.

### P6: dnsmasq cost of query logging

The integrator's B-min run `.local-validation/perf/20261111T032551Z-32856`
(gate artifact from `main` `7ed430e`) failed P6: dnsmasq +7.91 pp at
50 qps (off [7.28, 7.85, 7.64] %, on [15.69, 15.29, 15.56] %), +6.42 pp at
200 qps, while the design A run `20261110T195320Z-79115` measured +0.4 pp
with the same `log-queries=extra` + `log-async=25` drop-in. Diagnosis with
`scripts/perf/ab-dnsmasq.sh` on single guests (50 qps, 20 s windows, every
arm interleaved in each repeat, dnsmasq pids recorded before and after each
window):

| Arm (run `ab-perf2-run2`, 5 repeats) | dnsmasq % median [runs] | logd % | dnsmasq ctx switches / query (vol + invol) |
|---|---|---|---|
| off: package installed, `query_logging=0` | 8.22 [8.51, 7.08, 7.12, 8.22, 8.26] | 0.10 | 1.25 + 0.00 |
| manual: hand-written drop-in, same content, no trigger | 15.40 [12.95, 15.89, 15.80, 15.40, 14.79] | 3.74 | ≈ 1.0 + 0.04–0.60 |
| manual + one `logread -f` subscriber | 10.56 [9.86, 6.73, 12.36, 12.31, 10.56] | 3.88 | 0.84 + 0.01–0.06 |
| product: `query_logging=1` (drop-in + procd trigger) | 13.76 [10.46, 12.16, 13.76, 16.50, 15.00] | 3.69 | ≈ 1.0 + 0.02–0.66 |
| product without the trigger line | 11.71 [10.11, 7.28, 11.71, 11.96, 12.16] | 2.74 | 0.84 + 0.01 |
| design A package, `enabled=0` / `=1` (daemon + subscriber) | 8.41 / 11.06 | 0.10 / 3.49 | 1.25 / ≈ 1.0 + 0.37 |

An earlier run (`ab-perf2-run1`, 3 repeats, arms in blocks) gave off 6.68,
`log-queries=extra` alone 8.87, with `log-async=25` 9.50, with a subscriber
6.33 %.

Findings:
- **Not the procd trigger.** No dnsmasq restart happened in any of the 59
  A/B windows or the 18 load windows of the integrator's run (pids
  unchanged). The hand-written drop-in with no trigger registered
  (`query_logging=0`) is the most expensive arm; removing the trigger line
  from the package changes nothing beyond the spread.
- **Not `log-async`.** `log-queries=extra` alone vs with `log-async=25`:
  8.87 vs 9.50 % (spread 1.3 pp).
- **Not a stale jailed `/dev/log`.** Lines arrive in full: logd wakes once
  per line (≈ 2 voluntary switches per query at 2.5 lines per query), and
  `log read` sees 250 lines per 2 s at 50 qps.
- **The cost is dnsmasq's syslog writes, and design A hid it.** With
  logging on, dnsmasq's involuntary context switches rise from 0 to up to
  0.66 per query, consistent with logd (woken by each datagram) preempting
  dnsmasq on the same vCPU; under TCG every switch is expensive. Windows
  without that contention (0.84 + ≈ 0 switches per query: with a
  `logread -f` subscriber attached, and in the A/B arm measured 40 s after
  the restart) cost +2–4 pp. Which pattern a window gets is not under the
  harness's control, which is why the spread is large. Design A always ran a subscriber, so its runs measured
  the cheap case; B-min has none.
- **Rate.** The cost per query falls with the rate (+7.9 pp at 50 qps,
  +6.4 at 200 qps): at higher rates `log-async` batches lines and logd
  drains several per wakeup.

This is the inherent cost of the feature under TCG, not a harness artifact
(the harness's on and off windows are taken the same way after a dnsmasq
restart) and not a defect in the package's files. No product change reduces
it except running a log subscriber, which costs more in logd and the
subscriber than it saves. The dnsmasq P6 budget is therefore set from these
measurements (table above); the other processes keep 4 / 12 pp.

### Design A reference (superseded)

The last design A run, `.local-validation/perf/20261110T195320Z-79115`
(TCG), failed its own budgets: daemon + `logread` CPU 11.3 % / 35.6 % at
50 / 200 qps (budget 8 / 25), `domains` p95 560 ms (budget 100). Its
`logread -f` child alone cost 3.4 / 8.1 %, which is the ceiling P3 is set
under. Query logging itself (P5/P6) passed: p95 delta −1.2 / −0.7 ms with a
spread of 1.2–1.7 ms, i.e. within noise.

## Known gaps

- **TCG only.** Absolute CPU and latency numbers are TCG numbers. Run the
  gate under KVM (the CI `guest` job host) before treating them as
  hardware-representative.
- **P4 render time depends on the UI hook.** Without `abfm-poll` marks the
  gate measures parse + classify only (labelled in the verdict).
- **The browser shares the host with QEMU.** Under TCG, Chromium's CPU on
  the host competes with the guest's vCPU threads; its polling is light
  (one request per 2 s), but this is not a separate machine as on a LAN.
- **200 qps exceeds the ring.** At 200 qps a 128 KiB ring holds about 5 s
  of traffic, so every 2 s poll requests N = 900 and gaps are expected and
  counted by the page, not avoided.
