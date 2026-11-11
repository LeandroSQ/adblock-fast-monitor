---
applyTo: "Makefile,po/**"
---

# Packaging and translations

Adds to [AGENTS.md](../../AGENTS.md). File roles: `docs/CONTRACT.md` §2.

- `Makefile` is a `luci.mk` package built out of tree in the pinned SDK
  (`scripts/build-package.sh`). Dependencies stay the minimal set CONTRACT §2
  lists; a new dependency is a contract change.
- File modes come from the Makefile, not from git. Install and removal clear
  LuCI's caches and reload rpcd, so no reboot or rpcd restart is needed;
  `test/guest/package-files.host.sh` and T22 check both.
- `PKG_VERSION` / `PKG_RELEASE` follow the versioning policy in
  [`docs/releasing.md`](../../docs/releasing.md); add a `CHANGELOG.md` entry
  in the same change.
- `po/templates/adblock-fast-monitor.pot` is generated from the `_()`
  strings with LuCI's `build/i18n-scan.pl`; never edit it by hand.
  Translations go in `po/<lang>/adblock-fast-monitor.po`.
