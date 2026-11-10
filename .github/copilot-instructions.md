# Copilot instructions

Read and follow [`AGENTS.md`](../AGENTS.md) — it is the single source of truth
for restrictions, architecture, commands and testing obligations. The frozen
interface is [`docs/CONTRACT.md`](../docs/CONTRACT.md). Path-specific rules
live in `.github/instructions/*.instructions.md` and only add to AGENTS.md.

Copilot-specific deltas:

- Before finishing any change run `npm run verify:host` and make it pass.
  Guest/browser suites need Docker and an APK (AGENTS.md → Build and test);
  run the affected `test/guest/` files when touching code under `root/`.
- Code review: flag any violation of the AGENTS.md hard restrictions (fork or
  patch of adblock-fast, upstream `allow`, per-query subprocess or write,
  idle timers, dynamic `innerHTML`, ACL read/write mixing, committed secrets,
  source-regex tests) as blocking.
- Do not trigger, re-run or add GitHub Actions workflows to "check" a change;
  Actions minutes are limited.
