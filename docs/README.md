# Documentation index

| Document | What it is | Status |
| --- | --- | --- |
| [`AGENTS.md`](../AGENTS.md) | Rules, architecture map, commands and testing obligations for agents and humans | canonical |
| [`CONTRIBUTING.md`](../CONTRIBUTING.md) | Contribution workflow, commit conventions, pre-commit checklist | canonical |
| [`docs/CONTRACT.md`](CONTRACT.md) | Frozen v1 interface: architecture decisions, files, UCI, ubus/rpcd methods, ACL, budgets, test matrix T01–T26 | frozen (change rule: AGENTS.md hard restriction 10) |
| [`docs/performance.md`](performance.md) | P0 budget method, rationale and measured results (T26) | living |
| [`docs/test-traceability.md`](test-traceability.md) | Feature-to-test ledger of **executed** evidence only | living |
| [`docs/openwrt-25.12.6.md`](openwrt-25.12.6.md) | Target platform facts and pins | reference |
| [`README.md`](../README.md) | Install, packaging, releasing; [Testing](../README.md#testing) is the harness reference | canonical for users |
| [`keys/README.md`](../keys/README.md) | Signing-key custody, rotation and compromise | canonical |
| [`scripts/perf/budgets.json`](../scripts/perf/budgets.json) | Machine-readable P0 budgets | canonical numbers |

Tool pointers (no content of their own beyond tool-specific deltas):
[`.github/copilot-instructions.md`](../.github/copilot-instructions.md),
[`CLAUDE.md`](../CLAUDE.md) and the path-specific
`.github/instructions/*.instructions.md` files.

`MONITORING_API.md`, `RULE_ACTION_API.md`, `INTEGRATION_CONTRACT.md` and
`RUNTIME_TEST_REQUIREMENTS.md` at the repository root are superseded stubs that
point to `docs/CONTRACT.md`.

References in all of these files (repository paths, `npm run` scripts,
`applyTo` globs) are checked by `test/unit/docs-references.test.mjs` as part
of `npm run test:unit`.
