# Performance and resource budgets (P0)

Resource use is a P0 requirement: the monitor must not waste a small
router's memory, CPU or wakeups. This document defines how the budgets of
[`CONTRACT.md` §11](CONTRACT.md#11-performance-budgets) are measured (test
T26), why each number is what it is, and what has been measured so far.

## Running it

```sh
node scripts/integration/measure-performance.mjs path/to/package.apk   # ~25-40 min under TCG
node scripts/performance-gate.mjs .local-validation/perf/<run>          # re-evaluate a run
```

The APK must be inside the worktree or `.local-validation/` (the guest runs
in Docker on non-Linux hosts). `measure-performance.mjs` boots a fresh
OpenWrt 25.12.6 guest with `scripts/verify-guest.sh --no-install --no-tests
--host-cmd scripts/perf/run.sh`, so the stock system is measured before the
package is installed, and then runs the gate. The exit code is the verdict.
`npm run test:performance` without a run directory prints `SKIP` and exits 0
(the CI host job has no guest); with `PERFORMANCE_REQUIRE_MEASURED=1` it
evaluates the newest run and fails if there is none.

Tuning (environment): `ABFM_PERF_REPEATS` (default 3), `ABFM_PERF_LOAD_SECONDS`
(30), `ABFM_PERF_IDLE_SECONDS` (60, never less), `ABFM_PERF_QPS` (`"50 200"`),
`ABFM_PERF_SKIP_BOOT=1` (skips the two boots; P10 then reports
`NOT_MEASURED`), `ABFM_PERF_SELFTEST=1` (see [Self-test](#self-test)). `GUEST_ACCEL`, `GUEST_CPUS` (2) and `GUEST_MEMORY` (256 MiB)
come from `scripts/guest/lib.sh`.

Output: `.local-validation/perf/<run>/raw/*.json` (every snapshot, window,
load run and RPC timing, unreduced), `run.json` (index, harness errors),
`summary.json` (all derived numbers with the raw file names behind each
metric) and `verdict.json` (`PASS`/`FAIL` per metric). A metric that cannot
be measured is `NOT_MEASURED`, which fails the gate.

## Files

| Path | Role |
|---|---|
| `scripts/integration/measure-performance.mjs` | entrypoint: guest run + gate |
| `scripts/perf/run.sh` | host-side driver, phases below |
| `scripts/perf/guest/probe.uc` | guest probe (ucode, stock `fs`/`ubus`/`uloop` only): `/proc` snapshots, measurement windows, timed ubus calls, rpcd responsiveness probe, regex and memory calibration |
| `scripts/perf/guest/lib.sh` | guest helpers (BusyBox ash): fixtures, install, enable/disable/save through `reload_config`, restart counting |
| `scripts/perf/dnsload.mjs` | open-loop UDP DNS load generator with per-query latency |
| `scripts/perf/guest/adblock-fast-monitor-standin.uc` | self-test stand-in daemon (never shipped) |
| `scripts/perf/budgets.json` | the numbers of §11 |
| `scripts/performance-gate.mjs` | reduces raw data to P1–P10 and judges them |
| `test/guest/perf-p1-disabled.sh` | P1 in the regular guest suite (`verify:guest`) |

## Method

### Environment and fixtures

- Guest: stock OpenWrt 25.12.6 x86/64 + adblock-fast 1.2.4-r4 (the harness
  baseline image), 2 vCPUs, 256 MiB, QEMU user networking.
- No WAN: `perf_prepare` starts a second dnsmasq on `127.0.0.1:5300` that
  answers `*.perf.test` with `192.0.2.1` (TTL 300) and adds a drop-in
  `abfm-perf.conf` to the system dnsmasq: `server=/perf.test/127.0.0.1#5300`,
  `rebind-domain-ok=/perf.test/` (dnsmasq treats TEST-NET as private) and
  `local=/perf-block.test/`. The system dnsmasq is restarted once, before any
  measurement. `sysntpd` is stopped so that no background DNS query or log
  line disturbs the idle windows.
- Queries come from the host through the QEMU port forward, so dnsmasq sees
  the LAN address `10.0.2.2`, never `127.0.0.1` (which `exclude_router`
  drops). The mix is deterministic: 50 % unique names (`query` + `forwarded`
  + `reply` lines), 30 % 20 cached names (`query` + `cached`), 20 % unique
  blocked names (`query` + `config … is NXDOMAIN`), about 2.5 log lines per
  query. Every reply is checked: unique and cached names must carry an
  answer, blocked names are `NXDOMAIN`.
- Accelerator: KVM when `/dev/kvm` is usable, otherwise TCG. Apple-silicon
  hosts (Docker Desktop, OrbStack) have no x86 KVM, so local runs are TCG.
  The CI `guest` job enables KVM.

### Memory

The OpenWrt x86/64 kernel is built without `CONFIG_PROC_PAGE_MONITOR`, so
`/proc/<pid>/smaps` and `smaps_rollup` do not exist and PSS cannot be read.
The harness records `VmRSS`, `RssAnon`, `RssFile` and `VmHWM` from
`/proc/<pid>/status` instead. Budgets use **RSS** for the monitor's own
processes (conservative: shared libc/libubox pages are counted in full) and
**RssAnon** (private heap) for deltas of other daemons, where file pages are
shared and unchanged.

### Phases (`scripts/perf/run.sh`)

1. **Stock**: three `/proc` snapshots 5 s apart, before installation.
2. **Install** (`apk add --allow-untrusted`), ensure `enabled=0`, wait for
   procd to settle, three snapshots 5 s apart.
3. **Calibration**: the cost of the contract §4.3 regexes per line in this
   guest's ucode (20 000 lines, 3×); the RssAnon of a reference ucode process
   with `ubus`+`uloop` and a published object, empty and with tables of
   500/256/512, 2000/256/512 and 2000/1024/4096 entries (recent/top/pending,
   rows shaped like §4.5); the ubus round trip of `system board` and
   `session list`.
4. **Off/on alternation**, `REPEATS` times: set `enabled` through
   `uci commit` + `reload_config` (what LuCI's apply does) and wait until the
   dnsmasq and package pids are stable for 5 s. In the first repetition,
   a 60 s idle window per state. Then for each rate a 3 s warm-up and a
   measured load run: the guest opens a window (snapshot, sleep, snapshot)
   while the host sends `LOAD_SECONDS + 4` s of queries, so the window lies
   inside the load. Alternating off/on in every repetition spreads drift
   (host contention, cache state) evenly over both states.
5. **Settings save** `recent_size=2000`, then 3000 distinct names at 200 qps
   (60 % allowed, 40 % blocked), 15 s for pending entries to expire, a
   snapshot (P2 at the cap) and 20 timed calls each of `status`,
   `domains` recent / recent with `q` and offset 1000 / `top_blocked` /
   `top_allowed` (`limit` 100).
6. **rules/apply**: a 100 000-line `dnsmasq.servers` output file (3.4 MB,
   the `dns` mode of the baseline), then `rules` for 50 names (3 calls; the
   first is cold), `apply` with `dry_run` (10 calls) and one real `apply`
   (adblock-fast is disabled in the baseline, so the plan is `persist-only`
   and the job has no runtime step). A separate process calls rpcd's
   `session list` every 20 ms for 12 s around these calls and records the
   worst latency: that is how long rpcd's single-threaded loop was blocked.
   The output file and `/etc/config/adblock-fast` are restored.
7. **Boot**: power-cycle with `enabled=1`, then disable and power-cycle
   again (poweroff, then a fresh QEMU on the same overlay: a second warm
   `reboot` of one TCG QEMU process on an arm64 host stalled after GRUB for
   over 10 minutes). Count dnsmasq starts since boot each time; after the
   disabled boot, scan `/proc` every 250 ms for 20 s and take three
   snapshots. The same 250 ms watch runs for 15 s after installation, so a
   procd respawn loop of a short-lived process cannot hide between
   snapshots.

### Metric definitions

- **CPU %** = Δ(`utime`+`stime`) of the selected processes between the two
  snapshots of a window ÷ `USER_HZ` (100) ÷ wall seconds, in percent of one
  CPU. A process that starts inside the window counts from zero. Ticks are
  10 ms, so each 30 s window resolves 0.03 %.
- **Package processes** = every process whose command line names
  `adblock-fast-monitor`, plus their descendants (the `logread` child).
- **Wakeups** = Δ`voluntary_ctxt_switches` + Δ`nonvoluntary_ctxt_switches`
  from `/proc/<pid>/status`. The window starts after a `logger` marker; the
  syslog lines after the marker (and how many are dnsmasq's) are counted.
- **Timer evidence**: once a second the probe reads `/proc/<pid>/syscall` of
  the daemon. A daemon idle in uloop is blocked in `epoll_pwait` (281) /
  `epoll_wait` (232) whose timeout argument is `-1` when no uloop timer is
  armed; any finite timeout is a timer.
- **dnsmasq restarts** = dnsmasq `started, version` lines logged after a
  marker that precedes the action (the logd ring wraps under load, so
  absolute counts are not used). Boot counts all such lines since boot.
- **Latency** = per-query round trip at the load generator, including QEMU
  user networking. p95 per run; delta = median(on p95) − median(off p95);
  **noise floor** = max − min of the off-run p95s at the same rate.

### Self-test

`ABFM_PERF_SELFTEST=1` replaces the package's enable/disable/save with a
stand-in (`scripts/perf/guest/adblock-fast-monitor-standin.uc`): a ucode
process with a `logread -f -e ^dnsmasq\[` child that applies the §4.3
regexes to every line and keeps a bounded table of `recent_size` rows, plus
a real `log-queries=extra` drop-in (dnsmasq restarted on enable/disable).
It blocks in `read(2)` and arms no timer. It proves the daemon-side
measurements on real processes and gives a reference for what a minimal
contract-shaped daemon costs. Boot phases are skipped, it publishes no ubus
object (P7–P10 stay unmeasured) and the gate labels the run `SELF-TEST`
and exits non-zero: a self-test is never a package result.

## Budgets

All CPU figures are percent of one CPU of the measurement guest. A budget
measured under TCG is not transferable to KVM or real hardware; the gate
records the accelerator in `verdict.json`.

| ID | Budget (gate) | Why this number |
|---|---|---|
| P1 | 0 extra processes in any of 3 snapshots after install and 3 after a disabled boot, and none at the post-boot check (**hard**); RssAnon growth of pre-existing daemons ≤ 1024 KiB | D1: disabled means no process. The only allowed cost is the rpcd plugin, loaded once into rpcd's heap; 1 MiB bounds that. |
| P2 | daemon + `logread` RSS ≤ 4 MiB idle, ≤ 8 MiB with 2000 recent rows (top 256, pending 512) | Reference ucode process with ubus+uloop+published object: 1.3 MiB RSS; tables at the cap add 3.9 MiB RssAnon (≈ 2 KiB per row) → 5.2 MiB; `logread` ≈ 0.6 MiB. The self-test stand-in measured 1.9 MiB idle and 4.6 MiB with 2000 rows. 8 MiB keeps it single-digit with headroom. The contract maxima (2000/1024/4096) project to ≈ 10.5 MiB: see [Known gaps](#known-gaps). |
| P3 | in a quiet 60 s window: 0 voluntary wakeups of the daemon and no finite `epoll` timeout in any sample (**hard**); daemon + child wakeups − syslog lines ≤ 2 | §4.1: no timer while the pending map is empty. `logread -f` legitimately wakes once per syslog line of any daemon. |
| P4 | daemon + `logread` CPU ≤ 8 % at 50 qps, ≤ 25 % at 200 qps (TCG) | The [self-test](#self-test) stand-in, the least a contract-shaped ucode daemon can do per line, measured 7.1 % / 23.0 % (daemon ≈ 3.8 % / 13.1 %, `logread` ≈ 3.3 % / 9.8 %). The §4.3 regexes alone cost 71–121 µs per line in this guest depending on host load; at ≈ 2.5 lines per query that is 0.9–1.5 % / 3.6–6 %. The budget allows ≈ 10 % above the reference, no more. |
| P5 | median(on p95) − median(off p95) ≤ max(2 ms, noise floor), ≥ 3 runs per state and rate, loss ≤ 0.5 % | "Within noise": the noise floor (largest run-to-run p95 spread of either state) is measured in the same run, never assumed. The 2 ms floor covers what query logging itself costs under TCG: the self-test measured +1.0 ms p95 and +1.0 ms p50 at 200 qps with a 0.35 ms spread (dnsmasq formats and sends 2.5 syslog lines per query synchronously). |
| P6 | per process (logd, dnsmasq, rpcd, uhttpd, ubusd): CPU delta ≤ 4 pp at 50 qps, ≤ 12 pp at 200 qps; RssAnon delta ≤ 256 KiB | Query logging is inherent to D2. The self-test (real drop-in, one `logread -f` subscriber) measured logd +2.8 / +8.0 pp and dnsmasq +0.6 / +9.3 pp at 50 / 200 qps, RssAnon +0 KiB. The budget is that plus ≈ 30 %. |
| P7 | `status` p95 ≤ 50 ms; each `domains` view p95 ≤ 100 ms at full tables | ubus round trip floor ≈ 1–2 ms. The UI polls these every `poll_interval`; 100 ms bounds a poll's daemon time to ≤ 2 % at the 5 s default. |
| P8 | `apply` return ≤ 200 ms (dry run and real), rpcd never blocked > 200 ms (**hard**) | §6: rpcd is single-threaded. |
| P9 | `rules` cold reply ≤ 5 s on a 100 000-line output file; rpcd blocked ≤ 200 ms meanwhile (**hard**) | The scan runs in a child; 5 s keeps the UI's action menu usable. Baseline `session list` worst case during the window: 23–24 ms. |
| P10 | dnsmasq restarts: boot 0, enable 1 (every repetition), settings save 0 (**hard**) | D2. Boot is the on-boot count minus the off-boot count. |

## Measured results

Host: Apple-silicon Mac, OrbStack Docker (`linux/arm64`), QEMU **TCG** (no
x86 KVM on this host), guest 2 vCPU / 256 MiB. Other agents' guests and
builds ran concurrently, so these numbers carry host-contention noise. Raw
data stays in the shared cache (not committed); re-run the gate on a
directory to regenerate `summary.json`.

### Current main (`ad6fe53`, v0 package)

Run `.local-validation/perf/20261110T173944Z-66070` (APK sha256
`c9b7c23c…`, built from `ad6fe53`; 3 repeats × 30 s × {50, 200} qps per
state, 60 s idle windows, two power cycles). Verdict **FAIL**: P1 PASS, P10
FAIL, the rest NOT_MEASURED.

- **The v0 daemon cannot run**: `/etc/init.d/adblock-fast-monitor` is
  installed without the execute bit (`ash: …: Permission denied`; the
  interim Makefile installs `root/` without modes), so enabling starts
  nothing and no dnsmasq restart happens (P10: enable 0, save 0, boot 0 →
  FAIL "enabling started no monitor process"). With an earlier v0 build
  (correct modes) the harness recorded, in development runs, 2 dnsmasq
  restarts per settings save and, after a disabled boot, a respawning
  `/bin/sh /usr/libexec/adblock-fast-monitor-collector`: P1 and P10
  violations that v1 (D1, D2) removes.
- **P1** PASS: 0 extra processes (3 snapshots + 56 scans at 250 ms after
  install, 3 snapshots + 72 scans after a disabled boot); RssAnon of the
  existing daemons +4 KiB; MemAvailable −2.9 MiB (installed files in
  page cache/overlay).
- **Off-state baselines**: idle 60 s with no syslog line: logd 60 wakeups
  (its 1 Hz timer), dnsmasq 0. RssAnon: rpcd 560 KiB, dnsmasq 356 KiB,
  uhttpd 168 KiB, logd 164 KiB, ubusd 116 KiB. dnsmasq CPU without query
  logging: 8.6 % at 50 qps, 20.4 % at 200 qps.
- **A/A latency noise floor** (both states identical because no daemon
  ran): p95 off [9.35, 5.83, 6.05] / on [10.77, 6.18, 6.16] ms at 50 qps,
  off [1.67, 3.47, 3.66] / on [3.32, 3.58, 3.61] ms at 200 qps; 5100 and
  20400 samples per state, 0 loss. Delta of medians +0.13 / +0.12 ms;
  run-to-run spread up to 4.6 ms (50 qps) and 2.0 ms (200 qps). p50 is far
  steadier (Δ +0.09 / −0.00 ms).
- Calibration: §4.3 regexes 71 µs per line; ubus round trip p95 1–2 ms;
  rpcd `session list` worst case 17 ms during the rules/apply window.

### Self-test (stand-in daemon, real query logging)

Run `.local-validation/perf/20261110T172536Z-65134` (same APK, labelled
`SELF-TEST`; not a package result):

| Metric | 50 qps | 200 qps |
|---|---|---|
| daemon + logread CPU (P4) | 7.1 % (3.8 + 3.3) | 23.0 % (13.1 + 9.8) |
| logd CPU delta (P6) | +2.8 pp | +8.0 pp |
| dnsmasq CPU delta (P6) | +0.6 pp | +9.3 pp |
| p95 off → on (P5) | [8.55, 5.17, 4.85] → [3.38, 3.80, 4.82] ms, Δ −1.37 | [2.17, 1.82, 2.06] → [3.31, 3.05, 3.09] ms, Δ +1.03 |
| p50 Δ | +0.70 ms | +0.97 ms |

P2: 1.9 MiB RSS idle, 4.6 MiB with 2000 rows. P3: 0 wakeups of the daemon
and of `logread` in a quiet 60 s window, 60/60 samples blocked in `read(2)`.
P1 PASS. The whole-system cost of monitoring at 200 qps under TCG is thus
≈ 40 % of one CPU (daemon 13, logread 10, logd 8, dnsmasq 9); it scales
linearly with query rate, so a home network averaging 5 qps pays ≈ 1 %.

## Known gaps

- **TCG only.** No KVM was available for these runs; absolute CPU and
  latency numbers are TCG numbers. Run the gate under KVM (CI `guest` job
  host) before treating CPU/latency budgets as hardware-representative.
- **Contract maxima vs single-digit memory.** `recent_size=2000`,
  `top_size=1024`, `pending_size=4096` together project to ≈ 10.5 MiB RSS
  (reference process). The P2 budget is defined at the 2000-row cap with
  default top/pending sizes.
- **Query logging dominates.** At 200 qps `logread`, logd and dnsmasq cost
  more than the daemon. dnsmasq's synchronous syslog writes add ≈ 1 ms p50
  under TCG; `log-async` in the drop-in would take the writes off the query
  path (a §5 contract change, not made here).
- **P7–P9** need the v1 ubus object and rpcd plugin; they have only been
  exercised against their absence (calls recorded as `Not found`).
