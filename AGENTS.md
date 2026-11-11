# AGENTS.md — luci-app-adblock-fast-monitor

Canonical guide for coding agents **and** humans. Other instruction files
(`.github/copilot-instructions.md`, `CLAUDE.md`,
`.github/instructions/*.instructions.md`) only point here and add
tool- or path-specific deltas; change rules here, not there.
`test/unit/docs-references.test.mjs` fails if a path or `npm run` script named
in these files stops existing. Trust this file; search only when it is
incomplete or wrong, then fix it.

## What this is

A standalone LuCI app for OpenWrt 25.12.6 (apk) that **depends on**
adblock-fast 1.2.4-r4: a dashboard of recent DNS queries (blocked/allowed,
blocked %) that the **browser** reads from the system log (`log read`), and
staged allow/block applied with one explicit Apply (one rebuild). No
resident process runs on the router. The frozen interface (api 2) is [`docs/CONTRACT.md`](docs/CONTRACT.md); all
code implements it. Docs index: [`docs/README.md`](docs/README.md).

## Hard restrictions (never violate)

1. **Standalone, not a fork.** Never copy, patch or wrap adblock-fast's code,
   and never edit files it generates (its dnsmasq outputs, cache, status).
   Rules live only in adblock-fast's own UCI (`/etc/config/adblock-fast`),
   written only by the rpcd `apply` method.
2. **Never call upstream `adblock-fast allow`.** It is defective (unblocks
   the wrong names, never the right one): [`docs/CONTRACT.md`](docs/CONTRACT.md) §14.1.
   Every rule change is applied with one adblock-fast rebuild (CONTRACT §6–§7).
3. **No edits to `/etc/config/dhcp`** or other packages' configuration. How
   query logging is enabled, and when dnsmasq may restart, is defined in
   [`docs/CONTRACT.md`](docs/CONTRACT.md) (budget P10).
4. **Native LuCI only.** `view`/`form`/`rpc`/`uci`/`ui` and `E()`; menu in
   `menu.d`, ACL in `acl.d`, an rpcd **ucode** plugin, `luci.mk` packaging,
   `_()` strings and `po/`. No frameworks, bundlers, CDNs, custom CSS
   systems or Lua.
5. **P0 resources** ([`scripts/perf/budgets.json`](scripts/perf/budgets.json),
   rationale in [`docs/performance.md`](docs/performance.md), the process
   inventory and budgets in CONTRACT §1 and §11): zero package processes in
   every state (the only exception is the job during an Apply); no
   per-query work on the router (log processing happens in the browser); no
   full-list scans on hot paths (RPC methods return in milliseconds; long
   work runs in the job); no copies of block lists in tmpfs; no idle timers
   or polling on the router; the UI polls `log read` with bounded `lines`
   (16–900) only while the page is visible; bounded structures only.
6. **Privacy and security.** Render untrusted data as text (`E()` children,
   `textContent`); never `innerHTML` or HTML strings with dynamic data.
   Keep the ACL's read and write grants separate (§9); writes to adblock-fast
   UCI only via `apply`; never grant `log write` or `:subscribe`. The read
   grant includes the whole system log, so the app is for admins only (say
   so in user docs). The client column is hidden by default; nothing stores
   client addresses on the router. Never commit
   secrets, private keys, guest passwords, real DNS logs or client IPs
   (fixtures use reserved names and TEST-NET addresses).
7. **No live routers.** Never SSH to or change a real device; use the QEMU
   guest harness.
8. **GitHub Actions minutes are scarce** (private repo on the Free plan).
   Validate locally first. Never push, dispatch workflows, enable Actions or
   change repository settings/secrets. Don't add triggers, matrices or jobs
   without need; keep `timeout-minutes` and SHA-pinned actions.
9. **Signing keys:** only public keys live in `keys/`; the private key is an
   environment secret used by `release.yml` alone. Custody and rotation:
   [`keys/README.md`](keys/README.md). Never generate or commit a real key.
10. **Contract changes** go into [`docs/CONTRACT.md`](docs/CONTRACT.md) in the
    same commit as the code; bump `api` when a name, field, type, bound,
    state or error code changes.

## Architecture map

The design (no resident process, how query logging is switched on, how the
browser reads and classifies the log, RPC methods) is defined **only** in
[`docs/CONTRACT.md`](docs/CONTRACT.md): §1 decisions, §2 file inventory with
each file's role, §4–§8 behaviour. Read those sections before changing code
under `root/`; do not restate them elsewhere.

| Path | Holds |
| --- | --- |
| `root/` | everything installed by the APK (layout = target filesystem; roles: CONTRACT §2) |
| `root/www/luci-static/resources/` | LuCI views and the pure UI modules (`model.js`, `querylog.js`; §8) |
| `root/usr/share/rpcd/` | rpcd ucode plugin and ACL (§6, §9) |
| `root/usr/share/ucode/abfm/` | pure ucode modules, unit-tested on the host |
| `Makefile`, `po/` | `luci.mk` package definition; translation template |
| `scripts/` | build (`scripts/build-package.sh`), container wrapper (`scripts/in-docker.sh`), guest harness (`scripts/guest/`), perf (`scripts/perf/`), release (`scripts/release/`) |
| `test/` | `ucode/`, `shell/`, `unit/` (host), `guest/` (QEMU), `browser/` (Playwright), `lib/`, `fixtures/` |
| `.github/workflows/` | `ci.yml` (PR/push to main; docs-only changes run only `changes` and `host`), `release.yml` (tags `v*`) |

Files at the repository root named `*_API.md`, `INTEGRATION_CONTRACT.md` and
`RUNTIME_TEST_REQUIREMENTS.md` are superseded stubs.

## Build and test

Node.js ≥ 22 and Docker are required; nothing needs secrets. `npm ci` is only
needed for Playwright (browser and T22). Details of every harness:
[README Testing](README.md#testing). APK paths must be inside the worktree or
`.local-validation/`.

| Purpose | Command | Needs | Time (M-series Mac, TCG) |
| --- | --- | --- | --- |
| All host checks (run before every commit) | `npm run verify:host` | Docker | ~25 s |
| Syntax: JSON, JS, `ash -n`, `bash -n`, `ucode -c` | `npm run check:static` | Docker | |
| Node unit tests (`test/unit/**/*.test.mjs`) | `npm run test:unit` | Node | |
| ucode suites on the pinned interpreter | `npm run test:ucode` (one file: `test/lib/ucode-runner FILE`) | Docker | |
| BusyBox ash suites | `npm run test:shell` (one file: `test/lib/busybox-runner FILE`) | Docker | |
| Build the APK (pinned SDK; prints the APK path) | `scripts/in-docker.sh --platform linux/amd64 -- scripts/build-package.sh` | Docker, amd64 | ~9 min (cached SDK) |
| Guest (functional) tests | `npm run verify:guest -- PKG.apk [test/guest/FILE...]` | Docker/QEMU | ~30 s boot + tests |
| Guest + browser tests | `npm run verify:guest -- --browser PKG.apk` | Docker/QEMU, `npm ci` | ~6 min |
| T22 LuCI install from a signed feed | `scripts/release/verify-luci-install.sh PKG.apk` | Docker/QEMU, `npm ci` | ~3 min |
| T30 upgrade from the api-1 package | `scripts/release/verify-upgrade.sh PKG.apk` | Docker/QEMU, amd64 | ~12 min (builds the old APK) |
| P0 gate (T26) | `npm run test:performance:measure -- PKG.apk` | Docker/QEMU | 25–40 min |
| Re-judge a perf run | `npm run test:performance` (SKIP without a run) | Node | |
| Release signing self-test | `scripts/release/selftest.sh WORKDIR PKG.apk` (macOS: prefix `scripts/in-docker.sh --platform linux/amd64 --`) | Linux x86_64 | ~10 s |

The baseline guest image is built once by `scripts/guest/prepare-baseline.sh`;
never write to it. Lint workflows with
`docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest`.

Releases: a tag `vX.Y.Z-rN` matching `PKG_VERSION-rPKG_RELEASE` in
`Makefile` runs `.github/workflows/release.yml` (build, guest, browser, T22,
then sign with `scripts/release/sign-feed.sh` and publish). Maintainers only.

## Testing obligations

- Every feature and behaviour needs an **executed** behavioural test against
  the real code: ucode interpreter (`test/ucode/**/*.test.uc`), BusyBox ash
  (`test/shell/`), the QEMU guest (`test/guest/*.sh` runs inside the guest,
  `test/guest/*.host.sh` on the host with `guest_exec`), or Playwright against
  the guest's LuCI (`test/browser/*.spec.mjs`), or Node loading the real
  LuCI modules (`test/unit/*.test.mjs`). The T01–T32 matrix is CONTRACT §13.
- **Forbidden:** tests that grep source or docs, re-implementations of the
  logic under test, stubs where a real backend is available, sleeps instead of
  readiness checks. Fix root causes, never loosen a test to pass.
- New test files are picked up by the runners automatically (files under
  `fixtures/`, `lib/` or `helpers/` are not run). Use the helpers of
  `test/lib/sh/testlib.sh` and `test/lib/ucode/testlib.uc`.
- [`docs/test-traceability.md`](docs/test-traceability.md) records only
  **executed** evidence (command, artifact, run directory, result). Never
  record intended coverage as passed.
- Budgets in `scripts/perf/budgets.json` change only with measured data in
  [`docs/performance.md`](docs/performance.md).

## Conventions

- ucode: `'use strict';`, pure modules without I/O where possible, bounded
  structures, string executables for spawned commands.
- Shell: POSIX sh for BusyBox ash (no bash-isms, no `stat`, `timeout`,
  `realpath` or fractional `sleep`); bash only for host scripts.
- Comments explain why, citing CONTRACT sections. SPDX header
  `Apache-2.0` on new source files.
- Commits: see [`CONTRIBUTING.md`](CONTRIBUTING.md). Move files with
  `git mv`. Never commit `.local-validation/`, APKs, images, SDK output or
  keys (`.gitignore`).
