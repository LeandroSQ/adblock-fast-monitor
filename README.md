# adblock-fast-monitor verification infrastructure

This repository contains an OpenWrt package shell plus host-side CI and test
infrastructure. All components are implemented against the frozen v1 interface
contract in [`docs/CONTRACT.md`](docs/CONTRACT.md).
Contributors and coding agents: start with [`AGENTS.md`](AGENTS.md) and
[`CONTRIBUTING.md`](CONTRIBUTING.md); all docs: [`docs/README.md`](docs/README.md).

## Install

Requires OpenWrt 25.12 (apk). The package depends on `luci-base`,
`adblock-fast` and the `ucode-mod-io`, `-resolv` and `-uloop` modules, which
come from the official feeds.

### On a router (signed feed, LuCI only)

Releases are signed and published as an apk feed on GitHub Pages:
<https://leandrosq.github.io/adblock-fast-monitor/> (instructions, key
fingerprint, packages). Once per router:

1. **System → Administration → Repository Public Keys**: paste
   `https://leandrosq.github.io/adblock-fast-monitor/keys/adblock-fast-monitor.pem`
   and click **Add key** (saved as `/etc/apk/keys/adblock-fast-monitor.pem`).
2. **System → Software → Configure apk**: add
   `https://leandrosq.github.io/adblock-fast-monitor/apk/packages.adb` to
   `customfeeds.list` and **Save**.
3. **Update lists…**, filter for `luci-app-adblock-fast-monitor`,
   **Install…**. The app is under **Services → Adblock Fast Monitor**.

Updates appear under **System → Software → Updates**. Without the feed: add the
key (step 1), download the signed `.apk` from a GitHub release and use
**Upload Package…**. LuCI never passes `--allow-untrusted`, so an unsigned
package is always refused there. The package lists the key file for
sysupgrade (`/lib/upgrade/keep.d/`); `customfeeds.list` is kept by apk. Key
custody, rotation and fingerprint: [`keys/README.md`](keys/README.md).

### Developer builds (unsigned)

Build locally (`scripts/in-docker.sh --platform linux/amd64 -- scripts/build-package.sh`)
or download the `luci-app-adblock-fast-monitor-unsigned-dev` artifact of a CI
run, then install over SSH:

```sh
scp -O luci-app-adblock-fast-monitor-*.apk root@router:/tmp/
ssh root@router apk add --allow-untrusted /tmp/luci-app-adblock-fast-monitor-*.apk
```

### Packaging

`Makefile` uses `luci.mk` out of tree (`include $(TOPDIR)/feeds/luci/luci.mk`):
everything under `root/` is installed, `po/<lang>/` becomes
`luci-i18n-adblock-fast-monitor-<lang>`, file modes are normalised (0755 for
`/etc/init.d` and `/usr/libexec`, 0644 otherwise), and install and removal
clear LuCI's caches and reload rpcd, so no restart is needed.

### Releasing

Push a tag `vX.Y.Z-rN` equal to `PKG_VERSION-rPKG_RELEASE`.
`.github/workflows/release.yml` builds and tests without secrets, then the
`sign` job (environment `release`, secret `APK_SIGNING_KEY`) runs
`scripts/release/sign-feed.sh` (`apk adbsign`, `apk mkndx --sign-key`,
mandatory `apk verify` against `keys/`), attests build provenance, creates the
GitHub release, deploys the feed to Pages and smoke-tests it from a stock
25.12.6 rootfs. `scripts/release/selftest.sh WORKDIR PKG.apk` exercises the
signing pipeline with throwaway keys (run in CI on every build);
`scripts/release/verify-luci-install.sh PKG.apk` checks the LuCI install
path end to end (Testing).

## Testing

Everything runs locally with Node.js 22+ and Docker; nothing needs secrets.

```sh
npm ci
npm run verify:host                      # no guest; ~10 s (first run builds the userland image, ~30 s)
npm run verify:guest -- path/to/pkg.apk  # boots a stock 25.12.6 guest, installs, runs test/guest
npm run verify:guest -- --browser path/to/pkg.apk   # also Playwright against the guest's LuCI
scripts/release/verify-luci-install.sh path/to/pkg.apk  # T22: install/remove through LuCI from a signed feed
scripts/release/verify-upgrade.sh path/to/pkg.apk       # upgrade from an older build of the same source
```

The APK path must be inside the worktree or `.local-validation/` (both are
mounted into the container). Build one with
`scripts/in-docker.sh --platform linux/amd64 -- scripts/build-package.sh`
(prints the path under `.local-validation/artifacts/`).

`verify-luci-install.sh` is the end-user install check (T22). It signs a feed
with a throwaway key using the release script, serves it like GitHub Pages,
boots a guest **without** the package and drives LuCI with Playwright: an
unsigned upload is refused, the key is added on Repository Public Keys, the
signed package installs with Upload Package… (objects and ACL work without
restarting rpcd), removal through LuCI leaves no files, drop-ins or objects,
and the package installs again from the feed via Configure apk. It runs on
Linux x86_64 directly and on macOS through Docker (the key never leaves a
throwaway container). In ordinary `verify:guest` runs this test is skipped.

`verify-upgrade.sh` builds an older variant of the same source (PKG_VERSION
0.0.9, from the APK's `source/` directory when it came from
`build-package.sh`), signs it and the given APK as two consecutive feed
releases with a throwaway key (outside the repo, deleted after signing), and
on a fresh guest: installs the old one from the feed, enables monitoring,
changes `recent_size`, applies one block rule, publishes the next release and
runs `apk update && apk upgrade` (what LuCI's Update lists… / Upgrade… run).
`test/guest/package-upgrade.host.sh` then checks that the modified conffile is
kept, the daemon was restarted onto the new code with exactly one ucode and
one logread and no orphans, the objects answer through `/ubus` without an
rpcd restart, the drop-in is still there with at most one dnsmasq restart,
the adblock-fast rule is intact, and LuCI's caches were cleared.

### Host suites (`verify:host`)

| Command | Runs | Against |
| --- | --- | --- |
| `npm run check:static` | JSON, JS (LuCI views compiled as function bodies), `bash -n`, `ash -n` for every POSIX sh script including extensionless ones, `ucode -c` | real OpenWrt BusyBox/ucode |
| `npm run test:unit` | `node --test` on `test/unit` (real `model.js`) | Node |
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

`.github/workflows/ci.yml` runs on pull requests to `main`, pushes to `main`
(both skipped for docs-only changes) and manual dispatch with read-only
permissions, no secrets, SHA-pinned actions and job timeouts: `host`
(verify:host), `package` (SDK build, cached tarball, signing self-test,
unsigned developer artifact), `guest` (KVM-backed run-guest-tests), `browser`
(Playwright against a guest) and `install` (T22,
`scripts/release/verify-luci-install.sh`, see Testing). `release.yml` is
described under Install → Releasing. Lint the workflows with
`docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest`.
