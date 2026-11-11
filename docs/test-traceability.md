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
| Source | `main` at `7ed430e` (later commits change only tests, scripts and docs) |
| Artifact | `.local-validation/artifacts/20261111T025656Z-1/package.apk` |
| SHA-256 | `a8e9da5b07f6950c0851eb855f96b331f7ce0012e5e9f45817dea2644d7df555` |
| Guest | OpenWrt 25.12.6 x86/64, stock image + adblock-fast 1.2.4-r4, QEMU TCG (no KVM) in Docker on an arm64 Mac |
| Date | 2026-11-11 |

| Suite | Command | Result | Run directory |
| --- | --- | --- | --- |
| Host (static, unit, ucode, shell, docs self-check) | `npm run verify:host` | pass: static 86 files, unit 64/64, ucode 5/5 files, shell 2/2 files | n/a |
| Guest + browser | `npm run verify:guest -- --browser PKG.apk` | 17/17 guest files pass (369 checks, 0 `not ok`); Playwright 12 passed, 1 skipped (`install-luci`, run separately below) | `qemu/runs/20261111T030512Z-1-24307` |
| T22 LuCI install from a signed feed | `scripts/release/verify-luci-install.sh PKG.apk` | pass (3/3; Playwright 1/1) | `qemu/runs/20261111T030514Z-1-21268` |
| T30 upgrade api 1 → 2 | `scripts/release/verify-upgrade.sh PKG.apk` | pass (31/31) | `qemu/runs/20261111T032453Z-1-7317` |
| T26 P0 | `npm run test:performance:measure -- PKG.apk` | see "P0" below | `perf/20261111T032551Z-32856` |

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
| Page states (`healthy`, `logging-off`) | T23 `ui-queries.spec.mjs`, `ui-acl.spec.mjs` | browser | pass; remaining §8.5 states: see open items |
| Installable from LuCI (key + Upload + feed), no `--allow-untrusted` | T22 | guest + browser | pass |
| Upgrade from api 1 (config migrated, daemon gone) | T07 `test/shell/uci-defaults-migrate.test.sh`, T30 | BusyBox + guest | pass |
| Package inventory, deps, modes, sysupgrade keep list | T31 `package-files.host.sh` | guest | pass |
| Release signing pipeline (throwaway key) | `scripts/release/selftest.sh` (14/14, 2026-11-10, design-A tree; script unchanged since) | Linux x86_64 container | pass |

## P0 (T26)

P0_PLACEHOLDER

## Superseded evidence

Earlier runs of design A (resident ucode daemon, contract api 1) are
superseded: that design failed its own CPU and latency budgets (P4, P7) and
was replaced. Its evidence is not carried over.
