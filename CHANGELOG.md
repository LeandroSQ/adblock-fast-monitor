# Changelog

All notable changes to `luci-app-adblock-fast-monitor`. Versions are
`PKG_VERSION-rPKG_RELEASE`; the versioning policy is in
[`docs/releasing.md`](docs/releasing.md). The interface version (`api`) is
defined in [`docs/CONTRACT.md`](docs/CONTRACT.md).

## [Unreleased]

First public release (contract api 2), for OpenWrt 25.12 with adblock-fast
1.2.4.

### Added

- One page (Services → Adblock Fast Monitor): the blocked share of recent
  DNS queries and the newest 50 queries, read from the system log in the
  browser and updated every 2 seconds, with the adblock-fast decision and
  its source, and the number of missed log entries.
- Block and Allow on each row, staged in the browser and applied together
  with **Apply and save**: written to adblock-fast's own Allowed/Blocked
  Domains lists, then one rebuild, checked with real DNS lookups.
- A Status → Overview section with the same blocked share.
- Turn query logging on or off from the page, through a runtime dnsmasq
  drop-in, without editing `/etc/config/dhcp`.
- Signed apk feed on GitHub Pages for installation from LuCI.
