---
applyTo: ".github/workflows/**"
---

# GitHub Actions workflows

Adds to [AGENTS.md](../../AGENTS.md) (hard restrictions 8 and 9).

- Keep the existing triggers (what each job does: `docs/testing.md` → CI,
  `docs/releasing.md`). No new triggers, schedules or matrices without a
  stated need.
- Every job has `timeout-minutes` and least-privilege `permissions`
  (workflow default read-only or none); each workflow has a `concurrency`
  group (CI cancels superseded runs; releases never cancel).
- Pin third-party actions by full commit SHA with a version comment, and
  container images by digest (AGENTS.md hard restriction 8).
- Workflows call the same scripts developers run locally (`npm run
  verify:host`, `scripts/build-package.sh`, `scripts/guest/run-guest-tests.sh`,
  `scripts/release/verify-luci-install.sh`); put logic in `scripts/`, not YAML.
- Only the `sign` job of `release.yml` (environment `release`) may use the
  `APK_SIGNING_KEY` secret; no PR-triggered job gets secrets.
- `npm run lint` runs the pinned actionlint. Never push or dispatch
  to test a workflow.
