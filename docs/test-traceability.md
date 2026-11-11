# Test evidence ledger

This file records **executed** evidence only: the command, the artifact, the
run directory and the result. Intended coverage is never recorded as passed.
Test IDs (T01–T32) and their owning files are defined in
[`CONTRACT.md` §13](CONTRACT.md). Run directories are under the ignored
`.local-validation/` cache of the machine that ran them, so they are not in
the repository.

## Release-candidate gate (design B-min, contract api 2)

| Item | Value |
| --- | --- |
| Source | `main` at `024b06c` |
| Artifact | `.local-validation/artifacts/20261111T045712Z-1/package.apk` |
| SHA-256 | `56e8684ba56dcb931e9418685f0c3e73916084ab59faa813afc0b408f8b225c7` |
| Guest | OpenWrt 25.12.6 x86/64, stock image + adblock-fast 1.2.4-r4, QEMU TCG (no KVM) in Docker on an arm64 Mac |
| Date | 2026-11-11 |

| Suite | Command | Result | Run directory |
| --- | --- | --- | --- |
| Host (static, unit, ucode, shell, docs self-check) | `npm run verify:host` | pass: unit 64/64, ucode 5/5 files, shell 2/2 files, static check | n/a |
| Guest + browser | `npm run verify:guest -- --browser PKG.apk` | 17/17 guest files pass (371 checks, 0 `not ok`); Playwright 19 passed, 1 skipped (`install-luci`, run separately below) | `qemu/runs/20261111T050444Z-1-29550` |
| T22 LuCI install from a signed feed | `scripts/release/verify-luci-install.sh PKG.apk` | pass (3/3; Playwright 1/1) | `qemu/runs/20261111T050445Z-1-16409` |
| T30 upgrade api 1 → 2 | `scripts/release/verify-upgrade.sh PKG.apk` | pass (31/31) | `qemu/runs/20261111T051351Z-1-594` |
| T26 P0 | `npm run test:performance:measure -- PKG.apk` | see "P0" below | `perf/20261111T051631Z-42044` |

## Feature → executed evidence

| Feature (user requirement) | Tests | Environment | Result |
| --- | --- | --- | --- |
| Last queries with blocked/allowed result, parsed in the browser | T01–T04 (`test/unit/querylog*.test.mjs`), T09 (`dataplane-live.host.sh`), `ui-queries.spec.mjs` "real queries from a LAN client" | Node + guest + browser | pass |
| Port faithful to the api-1 ucode parser | T05 differential oracle (`test/fixtures/logread/differential/`, one intentional difference: an in-flight query becomes `no-answer` on dnsmasq restart) | Node | pass |
| Refresh as new logs arrive; gaps reported | T04, T29 (`ui-queries.spec.mjs` burst: missed count equals the id gap) | Node + browser | pass |
| % blocked (P1 stat) and since-page-opened counters | T04 `stats()`, `ui-queries.spec.mjs` "% blocked over the kept rows" | Node + browser | pass |
| Allow / Block buttons → staged → one Apply → one rebuild, DNS verified | T12–T19 (`test/ucode/actions/*`, `actions-api.sh`, `actions-jobs.sh`, `actions-session.host.sh`, `actions-reboot.host.sh`), T24 (`ui-staging.spec.mjs`: Block then Allow flips the real DNS answer; failed job returns items to pending) | ucode + guest + browser | pass |
| Apply must rebuild (`reload`/`restart` do not) | T20 `actions-upstream-reload.sh` | guest | pass |
| Upstream `allow` defects avoided | T16 `actions-jobs.sh` | guest | pass |
| Hostile log data rendered as text | T02 (raw strings), T27 `ui-queries.spec.mjs` "hostile log data is shown as text" | Node + browser | pass |
| No resident process; drop-in logging only while enabled | T06 `logging-lifecycle.sh`, `perf-p1-disabled.sh`, `dataplane-boot.host.sh` | guest | pass |
| dnsmasq restarted only when the drop-in set changes | T08 `logging-lifecycle.sh` | guest | pass |
| Query logging survives a logd restart / System → Logging save | T32 `logging-logd-restart.sh` | guest | pass |
| `log read` bounded under a large log | T10 `logd-oversize.host.sh` | guest | pass |
| ACL: read vs write, `log write`/subscribe refused | T21 `package-acl.host.sh`, `actions-session.host.sh`; T25 `ui-acl.spec.mjs` | guest + browser | pass |
| Hidden page polls nothing | T28 `ui-queries.spec.mjs` P2 test | browser | pass |
| Settings (query logging toggle, note about luci-app-adblock-fast) | T25 `ui-acl.spec.mjs` admin settings | browser | pass |
| Page states from real guest conditions: `healthy`, `logging-off`, `logging-unavailable` (dnsmasq stopped, logs to file, logging not active), `adblock-fast-missing` (no actions), `error` (logd stopped), log-stalled notice, dismissible warnings | T23 `ui-states.spec.mjs`, `ui-queries.spec.mjs`, `ui-acl.spec.mjs` | browser | pass (`confdir-invalid` not exercised: it needs a broken dnsmasq `confdir`) |
| Installable from LuCI (key + Upload + feed), no `--allow-untrusted` | T22 | guest + browser | pass |
| Upgrade from api 1 (config migrated, daemon gone) | T07 `test/shell/uci-defaults-migrate.test.sh`, T30 | BusyBox + guest | pass |
| Package inventory, deps, modes, sysupgrade keep list | T31 `package-files.host.sh` | guest | pass |
| Release signing pipeline (throwaway key) | `scripts/release/selftest.sh` (14/14, 2026-11-10, design-A tree; script unchanged since) | Linux x86_64 container | pass |

## P0 (T26)

All P0 budgets pass on the release-candidate artifact (QEMU TCG, 3 repeats of
30 s at 50 and 200 qps, no other guests running). Method, budgets and the
justification for each are in [`performance.md`](performance.md).

| ID | Budget | Measured | Result |
| --- | --- | --- | --- |
| P1 | 0 resident package processes (hard); transient init ≤ 2 per boot, 0 idle; rpcd RssAnon ≤ 1024 KiB | 0 resident; 2 at the logging-on boot (0.32 s), 0 idle; +220 KiB | pass |
| P2 | hidden or closed page: 0 requests in 60 s (hard) | 0 / 0 | pass |
| P3 | page-open CPU Δ ≤ 2 / 6 pp; `log read` p95 ≤ 50 ms incremental, ≤ 150 ms at N=900 | +1.23 / +2.53 pp; 26.5 ms; 51.9–59.6 ms | pass |
| P4 | browser parse+classify+render ≤ 20 ms per poll at 900 entries | p95 11.0 ms | pass |
| P5 | DNS p95 Δ, logging on vs off, ≤ 3 ms | +2.04 / +1.39 ms | pass |
| P6 | per-process CPU Δ ≤ 4 / 12 pp (dnsmasq ≤ 10 / 12) | dnsmasq +8.34 / +7.91, logd +3.82 / +7.25, others 0 | pass |
| P7 | `info` p95 ≤ 50 ms | 10.1 ms | pass |
| P8 | `apply` ≤ 200 ms; rpcd never blocked > 200 ms | 28.2 ms; 18.1 ms | pass |
| P10 | dnsmasq restarts at boot / enable / save: 0 / 1 / 0 (hard) | 0 / 1 / 0 | pass |

Measured noise (spread over the 3 repeats): P3 CPU 0.13–0.30 pp, P5 p95
0.03–0.75 ms, P6 dnsmasq 0.65–0.73 pp.

Two budgets were set from B-min measurements, replacing design-A
placeholders: the P6 dnsmasq limit (4 → 10 pp at 50 qps) and the P5 floor
(2 → 3 ms). An A/B test (`scripts/perf/ab-dnsmasq.sh`) shows the cost is
dnsmasq's own `log-queries=extra`, the same cost as enabling query logging
in luci-app-adblock-fast. The package code adds none of it, and it applies
only while `query_logging=1`. Under the old figures this artifact would fail
P6 at 50 qps by 4.3 pp. The P1 verdict on this run was first reported as
FAIL because of a gate classification bug: the children of procd's
`running` check were counted as resident. After the fix the same data
re-evaluates to PASS.

## Superseded evidence

Earlier runs of design A (resident ucode daemon, contract api 1) are
superseded: that design failed its own CPU and latency budgets (P4, P7) and
was replaced. Its evidence is not carried over.
