# Test evidence ledger

This file records **executed** evidence only: the command, the artifact, the
run directory and the result. Intended coverage is never recorded as passed.
Test IDs (T01–T32) and their owning files are defined in
[`CONTRACT.md` §13](CONTRACT.md). Run directories are under the ignored
`.local-validation/` cache of the machine that ran them, so they are not in
the repository.

## Release-candidate gate (contract api 2)

| Item | Value |
| --- | --- |
| Source | `main` at `230ef0b` |
| Artifact | `.local-validation/artifacts/20261112T063248Z-1/package.apk` |
| SHA-256 | `9b48690a4ea3cba2dc3d78ab75b371025110118f8b7fa0893614e89acadae257` |
| Functional guest | OpenWrt 25.12.6 x86/64, stock image + adblock-fast 1.2.4-r4, QEMU TCG in Docker on an Apple-silicon Mac |
| P0 guest (run of record) | OpenWrt 25.12.6 armsr-armv8 + adblock-fast 1.2.4-r4, QEMU with hvf acceleration on the same Mac |
| Date | 2026-11-12 |

Behavioural tests execute the shipped code (Node on the real LuCI modules,
the ucode interpreter, BusyBox ash, the guest and the browser). Repository
checks (lint, static syntax, docs self-check, `.pot` sync, coverage and
mutation thresholds) keep the tree consistent and are not counted as
feature evidence.

| Suite | Kind | Command | Result | Run directory |
| --- | --- | --- | --- | --- |
| Repository checks | repository | `npm run verify:host` (lint, static, docs self-check) | pass: lint clean over 187 files (empty baseline), static over 138 files | n/a |
| Node unit (real `querylog.js`, `model.js`, perf gate) | behavioural | `npm run test:unit` | 127/127 pass; coverage gate lines ≥ 98 %, branches ≥ 90 % | n/a |
| ucode (real modules and rpcd plugin) | behavioural | `npm run test:ucode` | 7/7 files pass | n/a |
| BusyBox ash | behavioural | `npm run test:shell` | 1/1 file pass | n/a |
| Guest + browser | behavioural | `npm run verify:guest -- --browser PKG.apk` | 18/18 guest files, 444 checks, 0 `not ok`; Playwright 42/42 (install spec runs separately) | `qemu/runs/20261112T064003Z-1-9648` |
| T22 LuCI install from a signed feed | behavioural | `scripts/release/verify-luci-install.sh PKG.apk` | pass (Playwright 1/1) | `qemu/runs/20261112T065742Z-1-10281` |
| T30 upgrade api 2 → api 2 | behavioural | `scripts/release/verify-upgrade.sh PKG.apk` | 30/30 | `qemu/runs/20261112T070619Z-1-30423` |
| Release signing (throwaway key) | behavioural | `scripts/release/selftest.sh WORKDIR PKG.apk` (linux/amd64 container) | 16/16 | n/a |
| T26 P0 | behavioural | `ABFM_PERF_GUEST=armsr-hvf npm run test:performance:measure -- PKG.apk` | PASS, all budgets (below) | `perf/20261112T070716Z-38758` |

Not run here: the GitHub workflows (Actions are disabled until go-live),
mutation testing (`npm run test:mutation`, last run by its owner at 87.6 %
with break 85), and any real router.

## Feature → executed evidence

| Feature (user requirement) | Tests | Environment | Result |
| --- | --- | --- | --- |
| Last queries with blocked/allowed result, parsed in the browser | T01–T04 (`test/unit/querylog*.test.mjs`), T09 (`dataplane-live.host.sh`), `ui-queries.spec.mjs` "real queries from a LAN client" | Node + guest + browser | pass |
| Parser decisions unchanged against the frozen expected results | T05 differential oracle (`test/fixtures/logread/differential/`, one intentional difference: an in-flight query becomes `no-answer` on dnsmasq restart) | Node | pass |
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
| Hidden page polls nothing; one read in flight; idle pause and back-off | T28 `ui-queries.spec.mjs` | browser | pass |
| Settings (query logging toggle, note about luci-app-adblock-fast) | T25 `ui-acl.spec.mjs` admin settings | browser | pass |
| Page states from real guest conditions: `healthy`, `logging-off`, `logging-unavailable` (dnsmasq stopped, logs to file, logging not active), `adblock-fast-missing` (no actions), `error` (logd stopped), log-stalled notice, dismissible warnings | T23 `ui-states.spec.mjs`, `ui-queries.spec.mjs`, `ui-acl.spec.mjs` | browser | pass (`confdir-invalid` not exercised: it needs a broken dnsmasq `confdir`) |
| Installable from LuCI (key + Upload + feed), no `--allow-untrusted` | T22 | guest + browser | pass |
| Upgrade api 2 → api 2 (config and drop-ins kept, no extra dnsmasq restart) | T30 `package-upgrade.host.sh`; removal `package-remove.host.sh` | guest | pass |
| Package inventory, deps, modes, sysupgrade keep list | T31 `package-files.host.sh` | guest | pass |
| Release signing pipeline (throwaway key: adbsign, mkndx, mandatory verify, tamper/foreign-key rejection, non-root `--usermode`) | `scripts/release/selftest.sh WORKDIR PKG.apk` | Linux x86_64 container | pass 16/16 |

## P0 (T26)

The run of record above passed every budget. Its per-metric results, the
budgets and the method are in
[`performance.md` → Run of record](performance.md#run-of-record-release-candidate).
