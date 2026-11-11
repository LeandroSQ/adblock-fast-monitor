# AGENTS.md — luci-app-adblock-fast-monitor

Canonical guide for coding agents **and** humans. Other instruction files
(`.github/copilot-instructions.md`, `CLAUDE.md`,
`.github/instructions/*.instructions.md`) only point here and add tool- or
path-specific deltas; change rules here, not there. Each fact has one owner
(see [Where facts live](#where-facts-live)); link to it instead of
restating it. Trust this file; search only when it is incomplete or wrong,
then fix it.

## What this is

A standalone LuCI app for OpenWrt 25.12.6 (apk) that **depends on**
adblock-fast 1.2.4-r4: a dashboard of recent DNS queries (blocked/allowed,
blocked %) that the **browser** reads from the system log (`log read`), and
staged allow/block applied with one explicit Apply (one rebuild). No
resident process runs on the router. The frozen interface (api 2) is
[`docs/CONTRACT.md`](docs/CONTRACT.md); all code implements it. Docs index:
[`docs/README.md`](docs/README.md).

## Hard restrictions (never violate)

They bind every contributor, human or agent. Steps reserved for maintainers
(tags, releases, settings, the signing key) are in
[`docs/releasing.md`](docs/releasing.md). `.github/copilot-instructions.md`
repeats this block byte for byte (checked by
`test/unit/docs-references.test.mjs`).

<!-- hard-restrictions:begin -->
1. **Standalone, not a fork.** Never copy, patch or wrap adblock-fast's code,
   and never edit files it generates (its dnsmasq outputs, cache, status).
   Rules live only in adblock-fast's own UCI (`/etc/config/adblock-fast`),
   written only by the rpcd `apply` method.
2. **Never call upstream `adblock-fast allow`.** It unblocks the wrong names
   (CONTRACT §14.1). Every rule change is applied with one adblock-fast
   rebuild (CONTRACT §6–§7).
3. **No edits to `/etc/config/dhcp`** or other packages' configuration. How
   query logging is enabled, and when dnsmasq may restart, is defined in
   CONTRACT (budget P10).
4. **Native LuCI only.** `view`/`form`/`rpc`/`uci`/`ui` and `E()`; menu in
   `menu.d`, ACL in `acl.d`, an rpcd **ucode** plugin, `luci.mk` packaging,
   `_()` strings and `po/`. No frameworks, bundlers, CDNs, custom CSS
   systems or Lua.
5. **Resources are P0** (budgets in `scripts/perf/budgets.json`, method in
   `docs/performance.md`, process inventory in CONTRACT §1 and §11): zero
   resident processes of this package in every state (only the job runs,
   during an Apply); no per-query work on the router (the browser parses
   the log); RPC methods return in milliseconds and long work runs in the
   job; no full-list scans on hot paths; no copies of block lists in tmpfs;
   no idle timers or polling on the router; the page polls `log read` with
   bounded `lines` only while it is visible; every structure is bounded.
6. **Privacy and security.** Render untrusted data as text (`E()` children,
   `textContent`); never `innerHTML` or HTML strings with dynamic data.
   Keep the ACL's read and write grants separate (CONTRACT §9); write to
   adblock-fast UCI only via `apply`; never grant `log write` or
   `:subscribe`. The read grant exposes the whole system log, so the app is
   for admins only (user docs say so). The client column is hidden by
   default; nothing stores client addresses on the router. Never commit
   secrets, private keys, passwords, real DNS logs or client addresses
   (fixtures use reserved names and TEST-NET addresses).
7. **No live systems.** Never SSH to or change a real router; use the QEMU
   guest harness. Outside your own fork and pull request, never change
   GitHub state: no tag, release, workflow dispatch or re-run, and no change
   to settings, environments, secrets or visibility. Coding agents never
   push.
8. **CI and supply chain.** Validate locally before proposing a change; CI
   repeats the same scripts and is not a test bench. Add no workflow
   trigger, schedule, matrix or job without a stated need; every job keeps
   `timeout-minutes` and least-privilege `permissions`. Pin every external
   input: actions by commit SHA, container images by digest, downloads by
   SHA-256, npm packages by `package-lock.json`.
9. **Signing keys.** Only public keys live in `keys/`; the private key is an
   environment secret used by the `sign` job of `release.yml` alone
   (`keys/README.md`). Only the maintainer generates the
   real key, offline; never print or commit a private key.
10. **Contract changes** go into `docs/CONTRACT.md` in the same commit as the
    code; bump `api` when a name, field, type, bound, state or error code
    changes.
<!-- hard-restrictions:end -->

## Architecture map

The design (no resident process, how query logging is switched on, how the
browser reads and classifies the log, RPC methods) is defined **only** in
[`docs/CONTRACT.md`](docs/CONTRACT.md): §1 decisions, §2 file inventory with
each file's role, §4–§8 behaviour. Read those sections before changing
package code; do not restate them elsewhere.

| Path | Holds |
| --- | --- |
| `htdocs/` | web assets installed under `/www`: LuCI views and the pure UI modules (`model.js`, `querylog.js`; CONTRACT §8) |
| `root/` | every other installed file (layout = target filesystem; roles: CONTRACT §2) |
| `root/usr/share/rpcd/` | rpcd ucode plugin and ACL (CONTRACT §6, §9) |
| `root/usr/share/ucode/abfm/` | pure ucode modules, unit-tested on the host |
| `Makefile`, `po/` | `luci.mk` package definition; translations |
| `scripts/` | build (`scripts/build-package.sh`), container wrapper (`scripts/in-docker.sh`), guest harness (`scripts/guest/`), perf (`scripts/perf/`), release (`scripts/release/`) |
| `test/` | `ucode/`, `shell/`, `unit/` (host), `guest/` (QEMU), `browser/` (Playwright), `lib/`, `fixtures/` |
| `.github/workflows/` | `ci.yml` (pull requests and pushes to `main`), `release.yml` (tags `v*`) |

## Build and test

Node.js ≥ 22 and Docker are required; nothing needs secrets. `npm ci`
installs the Playwright and lint dependencies. Harness internals:
[`docs/testing.md`](docs/testing.md). APK paths must be inside the worktree
or `.local-validation/`.

| Purpose | Command | Needs | Time (M-series Mac, TCG) |
| --- | --- | --- | --- |
| All host checks (run before every commit) | `npm run verify:host` | Docker | ~25 s |
| Syntax: JSON, JS, `ash -n`, `bash -n`, `ucode -c` | `npm run check:static` | Docker | |
| Node unit tests and repository checks (`test/unit/**/*.test.mjs`) | `npm run test:unit` | Node | |
| ucode suites on the pinned interpreter | `npm run test:ucode` (one file: `test/lib/ucode-runner FILE`) | Docker | |
| BusyBox ash suites | `npm run test:shell` (one file: `test/lib/busybox-runner FILE`) | Docker | |
| Build the APK (pinned SDK; prints the APK path) | `scripts/in-docker.sh --platform linux/amd64 -- scripts/build-package.sh` | Docker, amd64 | ~9 min (cached SDK) |
| Guest (functional) tests | `npm run verify:guest -- PKG.apk [test/guest/FILE...]` | Docker/QEMU | ~30 s boot + tests |
| Guest + browser tests | `npm run verify:guest -- --browser PKG.apk` | Docker/QEMU, `npm ci` | ~6 min |
| T22 LuCI install from a signed feed | `scripts/release/verify-luci-install.sh PKG.apk` | Docker/QEMU, `npm ci` | ~3 min |
| T30 upgrade from the previous release | `scripts/release/verify-upgrade.sh PKG.apk` | Docker/QEMU, amd64 | ~12 min |
| P0 gate (T26) | `npm run test:performance:measure -- PKG.apk` | Docker/QEMU | 25–40 min |
| Re-judge a perf run | `npm run test:performance` (SKIP without a run) | Node | |
| Release signing self-test | `scripts/release/selftest.sh WORKDIR PKG.apk` (macOS: prefix `scripts/in-docker.sh --platform linux/amd64 --`) | Linux x86_64 | ~10 s |

The baseline guest image is built once by `scripts/guest/prepare-baseline.sh`;
never write to it. CI jobs and releases: [`docs/testing.md`](docs/testing.md)
and [`docs/releasing.md`](docs/releasing.md).

## Testing obligations

- **Behavioural tests** execute the real code: the ucode interpreter
  (`test/ucode/**/*.test.uc`), BusyBox ash (`test/shell/`), the QEMU guest
  (`test/guest/*.sh` runs inside the guest, `test/guest/*.host.sh` on the
  host with `guest_exec`), Playwright against the guest's LuCI
  (`test/browser/*.spec.mjs`), or Node loading the real LuCI modules
  (`test/unit/*.test.mjs`). Every feature and behaviour needs one. The
  T01–T32 matrix is CONTRACT §13; a test that covers a row names its T-ID
  (e.g. `T15: allow of a listed name …`); `test/unit/docs-references.test.mjs`
  checks the IDs.
- **Forbidden in behavioural tests:** asserting on source or doc text,
  re-implementing the logic under test, stubs where a real backend is
  available, sleeps instead of readiness checks. Fix root causes, never
  loosen a test to pass.
- **Repository checks** (lint, `npm run check:static`, the docs self-check
  `test/unit/docs-references.test.mjs`) read files on purpose to keep the
  tree consistent. They are not feature evidence and are reported apart from
  behavioural tests.
- New test files are picked up by the runners automatically (files under
  `fixtures/`, `lib/` or `helpers/` are not run). Use the helpers of
  `test/lib/sh/testlib.sh` and `test/lib/ucode/testlib.uc`.
- [`docs/test-traceability.md`](docs/test-traceability.md) records only
  **executed** evidence (command, artifact, run directory, result), never
  intended coverage. Update it once per release candidate, and in the same
  pull request that changes a feature's tests or result.
- Budgets in `scripts/perf/budgets.json` change only with measured data in
  [`docs/performance.md`](docs/performance.md).

## Conventions

- ucode: `'use strict';`, pure modules without I/O where possible, bounded
  structures. Spawning: use an argument array (`system([ … ])`) whenever an
  argument is not a constant; a command string (needed for `fs.popen` and
  redirections) contains only constants and values validated by
  `abfm.domain` and passed through its `shell_quote`.
- Shell: POSIX sh for BusyBox ash (no bash-isms, no `stat`, `timeout`,
  `realpath` or fractional `sleep`); bash only for host scripts.
- Comments explain why, citing CONTRACT sections. New source files start
  with an `SPDX-License-Identifier: Apache-2.0` line.
- Commits: [`CONTRIBUTING.md`](CONTRIBUTING.md). Move files with `git mv`.
  Never commit `.local-validation/`, APKs, images, SDK output or keys.

## Where facts live

| Fact | Owner |
| --- | --- |
| Interface, file roles, behaviour, test matrix | [`docs/CONTRACT.md`](docs/CONTRACT.md) |
| P0 budget numbers | `scripts/perf/budgets.json` (method and results: [`docs/performance.md`](docs/performance.md)) |
| Commands and their run times | this file, [Build and test](#build-and-test) |
| Harness internals, CI jobs and triggers | [`docs/testing.md`](docs/testing.md) (the workflows are the source) |
| Release steps, versioning, key handling | [`docs/releasing.md`](docs/releasing.md), [`keys/README.md`](keys/README.md) |
| Executed evidence | [`docs/test-traceability.md`](docs/test-traceability.md) |
| User-facing install and use | [`README.md`](README.md) |
