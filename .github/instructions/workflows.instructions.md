---
applyTo: ".github/workflows/**"
---

# GitHub Actions workflows

Adds to [AGENTS.md](../../AGENTS.md) (hard restrictions 8 and 9).

- Minutes are limited: keep triggers as they are (`ci.yml`: PRs and pushes to
  `main` and manual dispatch, with the `changes` job skipping the package
  and QEMU jobs for docs-only changes while `host` and its docs self-check
  still run; `release.yml`: tags `v*`). No new triggers, schedules or matrices without a stated need.
- Every job has `timeout-minutes` and least-privilege `permissions`
  (workflow default read-only or none); each workflow has a `concurrency`
  group (CI cancels superseded runs; releases never cancel).
- Pin third-party actions by full commit SHA with a version comment.
- Workflows call the same scripts developers run locally (`npm run
  verify:host`, `scripts/build-package.sh`, `scripts/guest/run-guest-tests.sh`,
  `scripts/release/verify-luci-install.sh`); put logic in `scripts/`, not YAML.
- Only the `sign` job of `release.yml` (environment `release`) may use the
  `APK_SIGNING_KEY` secret; no PR-triggered job gets secrets.
- Lint with `docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest`.
  Never push or dispatch to test a workflow.
