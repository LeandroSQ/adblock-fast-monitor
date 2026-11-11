---
applyTo: "root/etc/**"
---

# Init script and UCI defaults

Adds to [AGENTS.md](../../AGENTS.md). Lifecycle and configuration are
defined in [`docs/CONTRACT.md`](../../docs/CONTRACT.md) (§2 inventory, §3
config and the lifecycle section it references).

- Init scripts are procd scripts for BusyBox ash (`#!/bin/sh /etc/rc.common`,
  `USE_PROCD=1`). POSIX sh only: no bash-isms, no `stat`, `timeout`,
  `realpath` or fractional `sleep` (absent on a stock router;
  `npm run test:shell` uses the same BusyBox).
- The init script starts no procd instance, so the package has zero
  resident processes in every state (P1); it only reconciles the
  query-logging drop-ins. dnsmasq restarts only as the contract allows
  (P10). Never touch `/etc/config/dhcp` or adblock-fast's files.
- `root/etc/config/adblock-fast-monitor` holds the contract defaults (§3:
  only `query_logging`, off by default). Adding, changing, renaming or
  removing an option is a contract change (AGENTS.md hard restriction 10)
  and updates `test/guest/package-files.host.sh`; it must also keep the
  upgrade from the previous release working (T30,
  `scripts/release/verify-upgrade.sh`).
- Lifecycle behaviour is tested on the guest (`test/guest/`), including
  `test/guest/logging-lifecycle.sh` and `test/guest/perf-p1-disabled.sh`.
