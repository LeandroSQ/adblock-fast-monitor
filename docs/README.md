# Documentation index

| Document | What it is |
| --- | --- |
| [`README.md`](../README.md) | What it is, install and use, how it works, resource usage, limitations (for router admins); screenshots in `docs/images/` |
| [`AGENTS.md`](../AGENTS.md) | Rules, architecture map, commands and testing obligations for humans and coding agents; owner of each fact |
| [`CONTRIBUTING.md`](../CONTRIBUTING.md) | Contribution workflow and commit conventions |
| [`docs/CONTRACT.md`](CONTRACT.md) | Frozen interface (api 2): decisions, files, UCI, rpcd methods, `log read` usage, ACL, budgets, test matrix T01–T32; changed only per AGENTS.md hard restriction 10 |
| [`docs/design.md`](design.md) | Non-normative background to the contract: history, reasons for the decisions, verified upstream facts |
| [`docs/testing.md`](testing.md) | How the host, guest, browser, install, upgrade and performance harnesses, the README screenshots and CI work |
| [`docs/releasing.md`](releasing.md) | Versioning, one-time repository settings and release steps |
| [`docs/performance.md`](performance.md) | P0 budget method, rationale, the run of record and the smoke reference (T26) |
| [`docs/test-traceability.md`](test-traceability.md) | Feature-to-test ledger of **executed** evidence only |
| [`keys/README.md`](../keys/README.md) | Signing-key generation, custody, rotation and compromise |
| [`scripts/perf/budgets.json`](../scripts/perf/budgets.json) | Machine-readable P0 budgets |
| [`CHANGELOG.md`](../CHANGELOG.md) | Changes per release |
| [`SECURITY.md`](../SECURITY.md) | Vulnerability reporting and scope |
| [`LICENSE`](../LICENSE) | Apache License 2.0 |

Tool pointers with only tool-specific deltas:
[`.github/copilot-instructions.md`](../.github/copilot-instructions.md),
[`CLAUDE.md`](../CLAUDE.md) and the path-specific
`.github/instructions/*.instructions.md` files.

`test/unit/docs-references.test.mjs` (part of `npm run verify:host`) checks
that every repository path, link and `npm run` script named in any Markdown
file exists.
