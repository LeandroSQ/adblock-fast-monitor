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
   boot: 20 s watch at 250 ms, dnsmasq starts since boot, three snapshots.

### Metric definitions

- **Package processes** = every process whose command line names
  `adblock-fast-monitor`, plus their descendants, plus any `logread -f`
  follower and the `adblock-fast-monitor` ubus object (design A's daemon).
  P1 collects them from every snapshot and watch of every state
  (installed off/on, all load windows including the page runs, both boots)
  and from the settled state after every switch. Installed snapshots are
  also compared with stock: any new userland command line counts.
  `job.uc` may run only during an Apply, and no sample is taken before the
  job has finished.
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
| P1 | 0 package processes in every sample of every state (**hard**); rpcd RssAnon growth ≤ 1024 KiB | B-min has no resident process; the only cost allowed is the rpcd plugin in rpcd's heap. |
| P2 | 0 requests in 60 s hidden, 0 in 60 s closed (**hard**) | LuCI's `Poll` never pauses for hidden tabs; the page must remove its poll on `visibilitychange`. |
| P3 | uhttpd+ubusd+logd+rpcd CPU with one visible page polling every 2 s minus the same load with no page ≤ 2 pp at 50 qps, ≤ 6 pp at 200 qps; `log read` p95 ≤ 50 ms at the adaptive N (< 900), ≤ 150 ms at N = 900 | Design A's `logread -f` child alone cost 3.4 / 8.1 % at 50 / 200 qps (run `20261110T195320Z-79115`); a page must cost less than that while open, and nothing when closed. A poll is one `log read`, all in C plus rpcd's session check. |
| P4 | `abfm-poll` p95 ≤ 20 ms at ≥ 810 entries; ≤ 500 rows kept | One poll every 2 s: 20 ms is 1 % of one browser core, and a 900-entry first load stays within about one 60 Hz frame (16.7 ms) plus layout. |
| P5 | median(on p95) − median(off p95) ≤ max(2 ms, noise floor), ≥ 3 runs per state and rate, loss ≤ 0.5 % | "Within noise", with the noise floor measured in the same run. Query logging is dnsmasq's synchronous syslog write per line: the design A self-test measured +1.0 ms p95 / +1.0 ms p50 at 200 qps under TCG. |
| P6 | logd, dnsmasq, rpcd, uhttpd, ubusd: CPU delta ≤ 4 pp at 50 qps, ≤ 12 pp at 200 qps each; RssAnon delta ≤ 256 KiB | Query logging is inherent. With a `logread -f` subscriber (design A) logd measured +2.8 / +6.0 pp and dnsmasq +0.4 / +5.6 pp at 50 / 200 qps (run `20261110T195320Z-79115`); B has no subscriber, so logd should drop. Budget unchanged. |
| P7 | `info` p95 ≤ 50 ms | Cheap UCI reads, `stat` and one `service list` call (§6.1); the ubus round-trip floor is 1–2 ms. |
| P8 | `apply` ≤ 200 ms (dry run and real) and rpcd never blocked > 200 ms (**hard**) | §6: rpcd is single-threaded. |
| P10 | dnsmasq restarts: boot 0, enabling query logging 1 (every time), a settings save 0 (**hard**) | §5. Boot is the on-boot count minus the off-boot count. |

## Measured results

Host: Apple-silicon Mac, OrbStack Docker (`linux/arm64`), QEMU **TCG**,
guest 2 vCPU / 256 MiB. Other agents' guests and builds ran concurrently,
so these numbers carry host-contention noise. Raw data stays in the shared
cache (not committed); re-run the gate on a directory to regenerate
`summary.json`.

### B-min harness self-test (design A APK, before BE/QL/UI landed)

RESULTS_PLACEHOLDER

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
