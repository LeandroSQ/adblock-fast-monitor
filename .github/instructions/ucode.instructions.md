---
applyTo: "root/usr/share/ucode/**,root/usr/libexec/**,root/usr/share/rpcd/ucode/**"
---

# ucode (router-side code, rpcd plugin, abfm modules)

Adds to [AGENTS.md](../../AGENTS.md). What each file does and its interface:
[`docs/CONTRACT.md`](../../docs/CONTRACT.md) §2 and the section it cites.

- Target the pinned ucode (`scripts/hosttools/pins.env`) and only the
  `ucode-mod-*` modules the package depends on (`Makefile`). Start every
  file with `'use strict';`.
- `root/usr/share/ucode/abfm/` modules stay pure: callers pass in UCI values,
  file lines, DNS answers and `now`, so they run under a bare interpreter.
- No resident process and no per-query work on the router (the browser
  parses the log, CONTRACT §1); no timers. Every table has a cap.
- The rpcd plugin runs inside rpcd's single-threaded uloop: every method
  returns in milliseconds (P7–P9); long work goes to a child or a detached
  job that does not use fds inherited from rpcd. Replies carry `"api": 2`
  and only contract error codes.
- Upstream pitfalls are listed in CONTRACT §12 and §14 (e.g. adblock-fast
  `reload` does not rebuild). Spawn with an argument array, never a shell string built
  from input; validate domains with `abfm.domain` first.
- Never call adblock-fast's `allow`; never write its generated files; write
  only `/etc/config/adblock-fast`, through `apply`.
- Tests: `test/ucode/**/*.test.uc` with `require("testlib")`
  (`test/lib/ucode/testlib.uc`); one file: `test/lib/ucode-runner FILE`; all:
  `npm run test:ucode`. ubus/procd/dnsmasq behaviour is tested in
  `test/guest/`.
