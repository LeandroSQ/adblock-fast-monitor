---
applyTo: "**/*.md"
---

# Documentation

Adds to [AGENTS.md](../../AGENTS.md).

- One owner per fact (AGENTS.md → Where facts live): link to the owner
  instead of copying numbers, triggers, budgets or interface details.
- Describe the code as it is. Executed evidence goes only into
  `docs/test-traceability.md`; intended coverage is never written as passed.
- The repository is public: no internal planning names, private hostnames,
  real client addresses or DNS logs; examples use reserved names
  (`example.com`, `*.test`) and TEST-NET addresses.
- Every repository path, link and `npm run` script you name must exist;
  `test/unit/docs-references.test.mjs` (part of `npm run verify:host`)
  checks all Markdown files.
- User-facing text (README) speaks to router admins; contributor detail goes
  to `docs/testing.md` or `docs/releasing.md`.
