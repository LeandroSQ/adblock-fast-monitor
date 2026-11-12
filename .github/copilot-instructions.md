# Copilot instructions

Read and follow [`AGENTS.md`](../AGENTS.md): it is the single source of truth
for rules, architecture, commands and testing obligations. The frozen
interface is [`docs/CONTRACT.md`](../docs/CONTRACT.md). Path-specific rules
live in `.github/instructions/*.instructions.md` and only add to AGENTS.md.

## Hard restrictions (copy of AGENTS.md; edit there first)

<!-- hard-restrictions:begin -->
1. **Standalone, not a fork.** Never copy, patch or wrap adblock-fast's code,
   and never edit files it generates (its dnsmasq outputs, cache, status).
   Rules live only in adblock-fast's own UCI (`/etc/config/adblock-fast`),
   written only by the rpcd `apply` method.
2. **Never call upstream `adblock-fast allow`.** It unblocks the wrong names
   (CONTRACT §14.1). Every rule change is applied with one adblock-fast
   rebuild (CONTRACT §6–§7).
3. **No edits to `/etc/config/dhcp`** or other packages' configuration. How
   query logging is enabled, and when dnsmasq may restart, is defined in
   CONTRACT (budget P10).
4. **Native LuCI only.** `view`/`form`/`rpc`/`uci`/`ui` and `E()`; menu in
   `menu.d`, ACL in `acl.d`, an rpcd **ucode** plugin, `luci.mk` packaging,
   `_()` strings and `po/`. No frameworks, bundlers, CDNs, custom CSS
   systems or Lua.
5. **Resources are P0** (budgets in `scripts/perf/budgets.json`, method in
   `docs/performance.md`, process inventory in CONTRACT §1 and §11): zero
   resident processes of this package in every state (only the job runs,
   during an Apply); no per-query work on the router (the browser parses
   the log); RPC methods return in milliseconds and long work runs in the
   job; no full-list scans on hot paths; no copies of block lists in tmpfs;
   no idle timers or polling on the router; the page polls `log read` with
   bounded `lines` only while it is visible; every structure is bounded.
6. **Privacy and security.** Render untrusted data as text (`E()` children,
   `textContent`); never `innerHTML` or HTML strings with dynamic data.
   Keep the ACL's read and write grants separate (CONTRACT §9); write to
   adblock-fast UCI only via `apply`; never grant `log write` or
   `:subscribe`. The read grant exposes the whole system log, so the app is
   for admins only (user docs say so). The page shows client addresses
   (maintainer's choice); nothing stores them on the router. Never commit
   secrets, private keys, passwords, real DNS logs or client addresses
   (fixtures use reserved names and TEST-NET addresses).
7. **No live systems.** Never SSH to or change a real router; use the QEMU
   guest harness. Outside your own fork and pull request, never change
   GitHub state: no tag, release, workflow dispatch or re-run, and no change
   to settings, environments, secrets or visibility. Coding agents never
   push.
8. **CI and supply chain.** Validate locally before proposing a change; CI
   repeats the same scripts and is not a test bench. Add no workflow
   trigger, schedule, matrix or job without a stated need; every job keeps
   `timeout-minutes` and least-privilege `permissions`. Pin every external
   input: actions by commit SHA, container images by digest, downloads by
   SHA-256, npm packages by `package-lock.json`.
9. **Signing keys.** Only public keys live in `keys/`; the private key is an
   environment secret used by the `sign` job of `release.yml` alone
   (`keys/README.md`). Only the maintainer generates the
   real key, offline; never print or commit a private key.
10. **Contract changes** go into `docs/CONTRACT.md` in the same commit as the
    code; bump `api` when a name, field, type, bound, state or error code
    changes.
<!-- hard-restrictions:end -->

## Copilot-specific deltas

- Before finishing any change run `npm run verify:host` and make it pass.
  Guest and browser suites need Docker and an APK (AGENTS.md → Build and
  test); run the affected `test/guest/` and `test/browser/` files when you
  touch package code.
- Code review: flag any violation of the hard restrictions above as
  blocking, and also behavioural tests that assert on source or doc text.
