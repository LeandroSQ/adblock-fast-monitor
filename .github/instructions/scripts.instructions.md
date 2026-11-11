---
applyTo: "scripts/**"
---

# Host scripts (build, guest harness, perf, release)

Adds to [AGENTS.md](../../AGENTS.md).

- Host scripts are bash (`set -euo pipefail`, or `set -uo pipefail` with
  explicit status checks in test drivers) or Node ≥ 22 ESM (`.mjs`);
  scripts copied into the guest (`scripts/perf/guest/`) are POSIX sh or
  ucode for BusyBox. `npm run check:static` syntax-checks all of them.
- Scripts must run on Linux x86_64 and, through `scripts/in-docker.sh`, on
  macOS. Paths given to a container must be inside the worktree or
  `.local-validation/`.
- Never write to the baseline guest image or delete the shared
  `.local-validation/` cache; per-run state goes in a fresh run directory.
- Pick ports per run (`GUEST_SSH_PORT=auto`) so guests can run concurrently;
  wait on readiness markers, not fixed sleeps.
- Release scripts (`scripts/release/`) handle keys: throwaway keys stay in a
  directory deleted on exit; never print or persist a private key. Exercise
  changes with `scripts/release/selftest.sh WORKDIR PKG.apk`.
- Perf code changes need a fresh run of
  `npm run test:performance:measure -- PKG.apk`; budgets live only in
  `scripts/perf/budgets.json`.
- Pin what scripts download (SHA-256 for files, digests for images) and
  verify it before use (AGENTS.md hard restriction 8).
- Document usage in a header comment; keep `docs/testing.md` or
  `docs/releasing.md` in sync.
