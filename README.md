# adblock-fast-monitor verification infrastructure

This repository contains an OpenWrt package shell plus host-side CI and test
infrastructure. All components are implemented against the frozen v1 interface
contract in [`docs/CONTRACT.md`](docs/CONTRACT.md).

## Local host checks

Requires Node.js 22+ and npm:

```sh
npm ci
npm run verify:host
```

`verify:host` validates the tooling, schemas, unit/contract fixtures, and the
tooling build. It deliberately does **not** claim to test a runtime that is not
present.

## Real runtime checks

The host-only checks never substitute a runtime. `npm run test:performance`
therefore reports an explicit P0 proposed-baseline skip. The mandatory CI
runtime job supplies its own disposable OpenWrt guest, credentials, deterministic
list server, package artifact, and browser. To run it locally:

```sh
PACKAGE_IPK=/absolute/path/to/luci-app-adblock-fast-monitor.apk \
npm run test:qemu
```

The runner needs Linux, QEMU, guestfish, `dig`, Playwright Chromium, and its
host prerequisite tools. It downloads the official 25.12.6 x86-64 image,
verifies its SHA-256, injects a generated one-run SSH key and root password,
and uses KVM when present or TCG otherwise. It serves only versioned local
fixture lists. Details, pinned 25.12.6 sources, and the target-neutral APK
policy are in
[`docs/openwrt-25.12.6.md`](docs/openwrt-25.12.6.md).

`npm run test:browser` exits with a prerequisite-blocked result unless
`MONITOR_BASE_URL` names a real LuCI endpoint. It never starts a substitute or
mock server. QEMU forwards guest port 80 to host port 8080 before package
removal.

QEMU writes mandatory **P0 measured** process-tree CPU/RSS and DNS
p95/throughput output. Missing or invalid measured output fails CI.

## CI policy

`.github/workflows/ci.yml` runs host verification, a pinned SDK package build,
and the GitHub-hosted QEMU lifecycle gate on every push and pull request. It
uses no repository secrets and has read-only permissions.

## Reproducible local Linux harness

When a local Docker daemon is available, run:

```sh
scripts/integration/run-local-docker-validation.sh
```

It builds an amd64 Linux validation image, verifies/downloads the pinned SDK,
builds the APK, and runs the same bounded QEMU gate without publishing ports or
changing existing containers. The harness stores generated SDK/image data only
under `.local-validation/`.
