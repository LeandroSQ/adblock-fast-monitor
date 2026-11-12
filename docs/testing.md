# Testing

How the test harnesses work. The commands and their run times are listed in
[AGENTS.md → Build and test](../AGENTS.md#build-and-test); what each test
must assert is the matrix in [`CONTRACT.md` §13](CONTRACT.md); executed
results are in [`test-traceability.md`](test-traceability.md).

Everything runs locally with Node.js and Docker; nothing needs secrets. An
APK passed to a harness must be inside the worktree or `.local-validation/`
(both are mounted into the containers). Build one with
`scripts/in-docker.sh --platform linux/amd64 -- scripts/build-package.sh`.
It packages the committed files (git `HEAD`) and refuses to build when
packaged paths have uncommitted changes, so an APK always matches a commit;
`ABFM_BUILD_FROM=worktree` builds the working tree instead (options at the
top of `scripts/build-package.sh`). It prints the container path
`/workspace/.local-validation/artifacts/<run>/package.apk`, which is
`.local-validation/artifacts/<run>/package.apk` in your checkout.

## Host suites (`npm run verify:host`)

| Command | Runs | Against |
| --- | --- | --- |
| `npm run check:static` | JSON, JS (LuCI views compiled as function bodies), `bash -n`, `ash -n` for every POSIX sh script including extensionless ones, `ucode -c` | real OpenWrt BusyBox and ucode |
| `npm run test:unit` | `node --test` on `test/unit`: the real LuCI modules, plus repository checks such as the docs self-check | Node |
| `npm run test:ucode` | `test/ucode/**/*.uc` | ucode at the OpenWrt 25.12.6 pin, with OpenWrt's patches |
| `npm run test:shell` | `test/shell/**/*.sh` under `ash` | BusyBox 1.37.0 with only OpenWrt's default applets |

`verify:host` starts with `npm run lint` (CONTRIBUTING.md → Tooling). The ucode and shell suites run in
`abfm-openwrt-userland`, a scratch image built by
`scripts/build-host-ucode.sh` from the sources OpenWrt v25.12.6 pins
(`scripts/hosttools/pins.env`): BusyBox with OpenWrt's patches and
`Config-defaults.in`, ucode with the stock modules, uci, ubus/ubusd, jshn
and jsonfilter. Nothing else is in the image, so `stat`, `timeout`,
`realpath` and fractional `sleep` fail exactly as on a stock router. The
image is cached by tag and as a tarball in `.local-validation/host-ucode/`.

Writing host tests:

- ucode: `let t = require("testlib");` then `t.test(name, fn)`, `t.eq`,
  `t.ok`, `t.match`, `t.throws`, `t.done()`. Run one file with
  `test/lib/ucode-runner test/ucode/x.test.uc`.
- shell: `. "$ABFM_TESTLIB/sh/testlib.sh"` then `t_ok`, `t_not`, `t_eq`,
  `t_match`, `t_skip`, `t_done`; helpers `abfm_stat FORMAT PATH` (replaces
  `stat -c`, tokens `%u %g %a %s %i %F %Y`), `abfm_timeout SECS cmd`,
  `abfm_wait_until SECS cmd`, `abfm_tmpdir`. Run one file with
  `test/lib/busybox-runner test/shell/x.sh`.
- The repository is mounted read-only at `/src` (the working directory);
  write to `/tmp` inside the container. Files under `fixtures/`, `lib/` or
  `helpers/` are not run as tests. A file passes if it exits 0 with no
  `not ok` line.

## Guest suite (`npm run verify:guest`)

`scripts/guest/run-guest-tests.sh [--isolate] [--no-install] [--no-tests]
[--host-cmd CMD] [--keep] PKG.apk [TEST...]` is wrapped by `verify:guest`,
which runs it in a container from `Dockerfile.validation` on non-Linux
hosts. It:

1. Boots a per-run copy-on-write overlay of the baseline image
   `.local-validation/qemu/abfm-baseline-25.12.6.qcow2` (stock 25.12.6
   x86/64 plus adblock-fast, built once by `scripts/guest/prepare-baseline.sh`
   and never written by test runs). Boot waits on serial-console markers
   and in-guest readiness checks, not fixed sleeps.
2. Provisions a random root password, a per-run SSH key and a
   `monitor-readonly` LuCI login limited to the package's read ACL.
3. Points apk at a host pull-through cache of downloads.openwrt.org
   (`.local-validation/openwrt-package-mirror`; `GUEST_OFFLINE=1` serves the
   cache only, `GUEST_FEEDS=official` uses the stock feeds over NAT).
4. Copies `test/lib`, `test/fixtures` and the APK into the guest, checks its
   SHA-256 and installs it with `apk add --allow-untrusted` (the signed
   LuCI path is T22, below).
5. Runs each `test/guest/*.sh` inside the guest as `sh FILE`, each
   `test/guest/*.host.sh` on the host with bash, then `--host-cmd`.

Guest tests get `ABFM_TESTLIB`, `ABFM_APK`, `ABFM_FIXTURES`,
`ABFM_HOST_URL`, `ABFM_FIXTURE_URL` and `PACKAGE_SHA256` and use the same
`testlib.sh`. Host tests get `guest_exec CMD`, `guest_copy SRC DST`,
`guest_copy_dir`, `guest_fetch SRC DST` and `GUEST_SSH_PORT`,
`GUEST_HTTP_URL`, `GUEST_DNS_PORT`, `GUEST_ROOT_PASSWORD`,
`GUEST_READONLY_USER`, `GUEST_READONLY_PASSWORD`, `GUEST_RUN_DIR`. Other
scripts can `source scripts/guest/lib.sh` and call `guest_start`,
`guest_reboot` and `guest_stop`; the options are documented at the top of
that file. Host ports are picked per run, so several guests can run at the
same time. Logs and per-test results go to a run directory under
`.local-validation/qemu/runs/`.

## Browser suite

`npm run verify:guest -- --browser PKG.apk` runs Playwright
(`test/browser/*.spec.mjs`, needs `npm ci`) against the guest's LuCI after
the guest files. `npm run test:browser` never starts a substitute server: it
needs `MONITOR_BASE_URL`, which `--browser` (or
`--host-cmd scripts/guest/browser-tests.sh`) sets to the guest.

## Install and upgrade (T22, T30)

`scripts/release/verify-luci-install.sh PKG.apk` is the end-user install
check. It signs a feed with a throwaway key using the release scripts,
serves it like GitHub Pages, boots a guest **without** the package and
drives LuCI with Playwright: an unsigned upload is refused, the key is added
on Repository Public Keys, the signed package installs with Upload Package…
(the plugin and ACL work without restarting rpcd), removal through LuCI
leaves no files or drop-ins, and the package installs again from the feed
through Configure apk. It runs on Linux x86_64 directly and on macOS
through Docker; the throwaway key never leaves its container. Ordinary
`verify:guest` runs skip this test.

`scripts/release/verify-upgrade.sh PKG.apk` publishes an older build and the
given APK as two consecutive releases of a throwaway signed feed, installs
the older one on a fresh guest, upgrades with `apk update && apk upgrade`
(what LuCI's Update lists… and Upgrade… run) and runs
`test/guest/package-upgrade.host.sh`: configuration, rules and the
query-logging drop-in survive, the methods answer without an rpcd restart
and dnsmasq is not restarted needlessly. The older source and its options
are documented at the top of the script.

## Performance (T26)

`npm run test:performance:measure -- PKG.apk` measures the P-budgets on a
guest, writes a run directory under `.local-validation/perf/` and judges it
against `scripts/perf/budgets.json`; `node scripts/performance-gate.mjs
RUN_DIR` re-judges a run. The run of record uses the hardware-accelerated
armsr-armv8 guest (`ABFM_PERF_GUEST=armsr-hvf`, Apple-silicon Mac); the
default x86/64 guest is a smoke run under TCG. Setup, method, budgets and
results: [`performance.md`](performance.md). The gate's own logic is
unit-tested on synthetic run directories (`test/unit/perf-gate.test.mjs`,
part of `npm run test:unit`).

## README screenshots

`npm run docs:screenshots -- PKG.apk` (`scripts/docs/screenshots.sh`)
boots a guest like `verify:guest --no-tests`, prepares it with the browser
suite's setup (`test/browser/global-setup.mjs`: the fixture block list and a
fake upstream answering `*.up.example.test` with `192.0.2.10`), sends test
queries from the host and saves `docs/images/overview.png` and
`docs/images/apply.png` (1280 px wide). It stages two changes and opens the
Apply dialog but never applies them, and fails if an image is 300 KB or
larger.

## CI

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) is the source;
this is a summary. It runs on pull requests to `main`, pushes to `main` and
manual dispatch, with read-only permissions, no secrets, pinned actions and
job timeouts:

- `changes` decides whether anything outside the docs changed;
- `host` always runs `npm run verify:host` (lint, static checks, unit,
  ucode and shell suites, docs self-check), and `secrets` runs gitleaks
  over the full history;
- only when code changed: `package` (SDK build and the signing self-test),
  `guest`, `browser` and `install` (T22), each on a fresh KVM guest;
- `ci-ok` aggregates the result and is the check to require on `main`.

The P0 measurement (T26) needs a long guest run and is not part of CI; it
runs locally before a release ([`releasing.md`](releasing.md)).

The unsigned developer APK (`luci-app-adblock-fast-monitor-unsigned-dev`) is
uploaded only for pushes to `main`, never for pull requests. Releases:
[`releasing.md`](releasing.md).
