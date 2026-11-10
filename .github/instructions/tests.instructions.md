---
applyTo: "test/**"
---

# Tests

Adds to [AGENTS.md](../../AGENTS.md) → Testing obligations; matrix:
`docs/CONTRACT.md` §13 (T01–T26). Harness details: README.md → Testing.

- Execute the real code: ucode files via `require`, `model.js` via the
  LuCI factory wrapper, shell via BusyBox, services on the guest, UI with
  Playwright. Never assert on source or doc text; never re-implement the
  logic under test; never mock a backend that the guest provides.
- Where a test goes:
  - pure ucode → `test/ucode/<area>/*.test.uc` (`t.test`, `t.eq`, `t.done()`)
  - BusyBox ash helpers → `test/shell/*.sh` (`testlib.sh`: `t_ok`, `t_eq`, `t_done`)
  - UI model and repo self-checks → `test/unit/*.test.mjs` (`node:test`)
  - installed package, procd, dnsmasq, ubus, rpcd → `test/guest/*.sh` (runs
    in the guest) or `test/guest/*.host.sh` (runs on the host via `guest_exec`)
  - rendered LuCI → `test/browser/*.spec.mjs`
- Shared code goes in `lib/`, `fixtures/` or `helpers/` directories (never run
  as tests). Fixtures use reserved names (`*.test`, `example.*`) and TEST-NET
  addresses; no real DNS logs or client data.
- Wait on readiness (`abfm_wait_until`), never fixed sleeps; bound waits with
  `abfm_timeout`. Write only to `/tmp` (the repo is mounted read-only).
- A guest file must be self-contained and leave the guest usable for the
  next file (or document that it needs `--isolate`).
- After a run, record executed evidence in `docs/test-traceability.md`.
