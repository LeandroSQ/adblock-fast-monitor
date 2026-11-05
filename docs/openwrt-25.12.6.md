# OpenWrt 25.12.6 verification facts

The reproducible integration target is **OpenWrt 25.12.6 x86/64**. It is not a
claim that the resulting package is x86-specific: the package is
shell/ucode/JavaScript and deliberately declares `PKGARCH:=all`. Its installed
dependencies can still be target-specific.

The official target index records these inputs:

| Input | URL | SHA-256 |
| --- | --- | --- |
| x86-64 ext4 combined image | `https://downloads.openwrt.org/releases/25.12.6/targets/x86/64/openwrt-25.12.6-x86-64-generic-ext4-combined.img.gz` | `f8538784d0288b4133a99ac2a68443e4922ffde6343e80df56a5882364b9d499` |
| x86-64 SDK | `https://downloads.openwrt.org/releases/25.12.6/targets/x86/64/openwrt-sdk-25.12.6-x86-64_gcc-14.3.0_musl.Linux-x86_64.tar.zst` | `1864152619092e781fa36a401960c8e9ae42d6a364c44ee5f0b197ca5f3c0fcc` |

These values were verified from the release target index and `sha256sums` on
2026-11-05. Verify the signed checksum manifest (`sha256sums.asc` and/or
`sha256sums.sig`) and the selected artifact hash again at execution time.
OpenWrt uses usign Ed25519 signatures for repository metadata; release checksum
manifests are also distributed with detached GPG signatures.

CI deliberately does not possess a signing key. It builds an unsigned APK for
testing with `apk add --allow-untrusted`; that is not a release distribution
procedure. Release publishers must sign repository metadata with their
protected usign key, distribute the matching public key through the trusted
feed/key mechanism, and test installation without `--allow-untrusted`.

## What the real-system gate proves

`scripts/integration/run-openwrt-qemu.sh` is intentionally strict. It downloads
the pinned image, verifies its checksum, injects disposable credentials, and
boots it with KVM or TCG. It validates:

1. APK control metadata declares `arch: all`.
2. `apk` accepts the architecture and resolves/install package dependencies.
3. Both rpcd plugins and LuCI assets are installed and executable where needed.
4. start, UCI change/reload, upgrade/config preservation, and removal behavior.
5. the in-repository Playwright automation exercises the LuCI Software
   upload/install path, rather than treating an API install as equivalent.

The runner serves only versioned local fixtures to the guest and performs real
dnsmasq, RPC/action, browser, and measured-performance assertions.

## Artifact portability

Build the package in an SDK for each intended release/ABI. Because `PKGARCH` is
`all`, the APK metadata should be target-neutral and apk should accept it on
architectures whose repositories can satisfy the dependencies. Publish the
target-neutral artifact only after the APK metadata check. The x86-64 gate is a
compatibility proof for the pinned release, not evidence for every device.

Resource measurements (RSS, CPU, timing) are hardware/model-dependent. Record
the QEMU host/CPU, RAM, image, package hashes, and workload with each result;
do not generalize those measurements to hardware targets.
