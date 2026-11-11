# Changelog

All notable changes to `luci-app-adblock-fast-monitor`. Versions are
`PKG_VERSION-rPKG_RELEASE`; the versioning policy is in
[`docs/releasing.md`](docs/releasing.md). The interface version (`api`) is
defined in [`docs/CONTRACT.md`](docs/CONTRACT.md).

## [Unreleased]

First public release (contract api 2), for OpenWrt 25.12 with adblock-fast
1.2.4.

### Added

- Dashboard (Services → Adblock Fast Monitor): recent DNS queries read from
  the system log in the browser, with the adblock-fast decision and its
  source, blocked percentage and counters, and the number of missed log
  entries.
- Allow and Block on each row, staged in the browser and applied together
  with one adblock-fast rebuild, checked with real DNS lookups.
- Settings: query logging through a runtime dnsmasq drop-in, without editing
  `/etc/config/dhcp`.
- Signed apk feed on GitHub Pages for installation from LuCI.
