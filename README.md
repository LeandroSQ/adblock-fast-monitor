# adblock-fast-monitor verification infrastructure

This repository contains an OpenWrt package shell plus host-side CI and test
infrastructure. Collector and RPC behavior are independently implemented; see
[`INTEGRATION_CONTRACT.md`](INTEGRATION_CONTRACT.md) for the package boundary.

## Testing

Everything runs locally with Node.js 22+ and Docker; nothing needs secrets.

```sh
npm ci
npm run verify:host                      # no guest; ~10 s (first run builds the userland image, ~30 s)
npm run verify:guest -- path/to/pkg.apk  # boots a stock 25.12.6 guest, installs, runs test/guest
npm run verify:guest -- --browser path/to/pkg.apk   # also Playwright against the guest's LuCI
```

The APK path must be inside the worktree or `.local-validation/` (both are
mounted into the container). Build one with
`scripts/in-docker.sh --platform linux/amd64 -- scripts/build-package.sh`
(prints the path under `.local-validation/artifacts/`).

### Host suites (`verify:host`)

| Command | Runs | Against |
| --- | --- | --- |
| `npm run check:static` | JSON, JS (LuCI views compiled as function bodies), `bash -n`, `ash -n` for every POSIX sh script including extensionless ones, `ucode -c` | real OpenWrt BusyBox/ucode |
| `npm run test:unit`, `test:contract` | `node --test` on `test/unit`, `test/contract` | Node |
| `npm run test:ucode` | `test/ucode/**/*.uc` | ucode 85922056 + OpenWrt patches |
| `npm run test:shell` | `test/shell/**/*.sh` under `ash` | BusyBox 1.37.0 with only OpenWrt's default applets |

The ucode and shell suites run in `abfm-openwrt-userland`, a scratch image
built by `scripts/build-host-ucode.sh` from the sources OpenWrt v25.12.6 pins
(`scripts/hosttools/pins.env`): BusyBox with OpenWrt's patches and
`Config-defaults.in`, ucode (modules fs io math struct uloop ubus uci log
debug resolv socket zlib digest; no nl80211/rtnl), uci, ubus/ubusd, jshn and
jsonfilter. Nothing else is in the image, so `stat`, `timeout`, `realpath`
and fractional `sleep` fail exactly as on a stock router. The image is cached
by tag and as a tarball in `.local-validation/host-ucode/`.

Writing tests:

- ucode: `let t = require("testlib");` then `t.test(name, fn)`, `t.eq`,
  `t.ok`, `t.match`, `t.throws`, `t.done()`. Run one file with
  `test/lib/ucode-runner test/ucode/x.test.uc`.
- shell: `. "$ABFM_TESTLIB/sh/testlib.sh"` then `t_ok`, `t_not`, `t_eq`,
  `t_match`, `t_skip`, `t_done`; helpers `abfm_stat FORMAT PATH` (replaces
  `stat -c`, tokens `%u %g %a %s %i %F %Y`), `abfm_timeout SECS cmd`,
  `abfm_wait_until SECS cmd`, `abfm_tmpdir`. Run one file with
  `test/lib/busybox-runner test/shell/x.sh`.
- The repository is mounted read-only at `/src` (the working directory);
  write to `/tmp`. Files under `fixtures/`, `lib/` or `helpers/` are not
  run as tests. A file passes if it exits 0 with no `not ok` line.

### Guest suite (`verify:guest`)

`scripts/guest/run-guest-tests.sh [--isolate] [--no-install] [--no-tests]
[--host-cmd CMD] [--keep] PKG.apk [TEST...]` (wrapped by `verify:guest`, which
uses a fresh container from `Dockerfile.validation` on non-Linux hosts):

1. Boots a per-run copy-on-write overlay of the baseline
   `.local-validation/qemu/abfm-baseline-25.12.6.qcow2` (stock 25.12.6 x86/64
   + adblock-fast, built once by `scripts/guest/prepare-baseline.sh`; never
   written by test runs). Boot is driven by serial-console markers and
   in-guest readiness checks, not fixed sleeps: ~25 s under TCG, faster
   with KVM.
2. Provisions a random root password, a per-run SSH key and a
   `monitor-readonly` LuCI login limited to the package's read ACL.
3. Points apk at a host pull-through cache of downloads.openwrt.org
   (`.local-validation/openwrt-package-mirror`; `GUEST_OFFLINE=1` serves the
   cache only, `GUEST_FEEDS=official` uses the stock feeds over NAT).
4. Copies `test/lib`, `test/fixtures` and the APK to `/tmp/abfm-test`,
   verifies its SHA-256 and runs `apk add --allow-untrusted` (the LuCI upload
   path with a trusted key is a separate, feature-owned test).
5. Runs each `test/guest/*.sh` inside the guest as `sh FILE`, and each
   `test/guest/*.host.sh` on the host with bash; then `--host-cmd`.

Guest tests get `ABFM_TESTLIB`, `ABFM_APK`, `ABFM_FIXTURES`, `ABFM_HOST_URL`,
`ABFM_FIXTURE_URL` and `PACKAGE_SHA256` and use the same `testlib.sh`. Host
tests get `guest_exec CMD`, `guest_copy SRC DST`, `guest_copy_dir`,
`guest_fetch SRC DST` and `GUEST_SSH_PORT`, `GUEST_HTTP_URL`,
`GUEST_DNS_PORT`, `GUEST_ROOT_PASSWORD`, `GUEST_READONLY_USER`,
`GUEST_READONLY_PASSWORD`, `GUEST_RUN_DIR`. Other scripts can
`source scripts/guest/lib.sh` and call `guest_start`/`guest_reboot`/
`guest_stop` directly; the options are documented at the top of that file.
Host ports are picked per run (`GUEST_SSH_PORT=auto`), so guests can run
concurrently. Logs and per-test results land in the run directory under
`.local-validation/qemu/runs/`.

`npm run test:browser` never starts a substitute server: it needs
`MONITOR_BASE_URL`, which `--browser` / `--host-cmd scripts/guest/browser-tests.sh`
set to the guest's LuCI.

### CI

`.github/workflows/ci.yml` runs on pull requests, pushes to `main` and manual
dispatch with read-only permissions, no secrets, SHA-pinned actions and job
timeouts: `host` (verify:host), `package` (SDK build, cached tarball),
`guest` (KVM-backed run-guest-tests) and `browser` (Playwright against a
guest). Lint it with
`docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest`.
