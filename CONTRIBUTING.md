# Contributing

The rules that every change must follow (hard restrictions, architecture,
commands, testing obligations) are in [`AGENTS.md`](AGENTS.md); they apply to
humans and agents alike. The interface is frozen in
[`docs/CONTRACT.md`](docs/CONTRACT.md). This file covers the workflow.

## Setup

- Node.js ≥ 22 and Docker. `npm ci` (only needed for Playwright suites).
- First `npm run verify:host` builds the host userland image (~30 s, cached).
- Guest suites need the baseline image, built once with
  `scripts/guest/prepare-baseline.sh`; see [README Testing](README.md#testing).

## Workflow

1. Branch from `main`. One topic per branch.
2. Change code and the matching tests together (AGENTS.md → Testing
   obligations). A contract change edits `docs/CONTRACT.md` in the same
   commit.
3. Run `npm run verify:host` (must pass). For changes under `root/`, build an
   APK and run the affected guest/browser tests:
   `npm run verify:guest -- [--browser] PKG.apk [test/guest/FILE...]`.
4. Record executed evidence in `docs/test-traceability.md` when a feature's
   status changes.
5. Open a pull request. CI (`.github/workflows/ci.yml`) reruns host, package,
   guest, browser and install checks (a docs-only change runs only the host
   job, which includes the docs self-check); GitHub Actions minutes are
   limited, so push only after local validation passes. A change to the
   package's upgrade path also needs `scripts/release/verify-upgrade.sh PKG.apk`.

## Commits

- Subject: imperative, ≤ 72 characters, optionally prefixed with the area
  (`UI:`, `perf gate:`, `packaging:`, `docs:`). Body: what and why, wrapped
  at ~72 columns, citing CONTRACT sections or test IDs (T01–T32, P1–P10).
- Coherent increments: each commit passes `npm run verify:host`.
- Move or rename files with `git mv` so history follows them.
- Commits made by an AI agent end with its trailer, e.g.
  `Co-authored-by: Copilot App <223556219+Copilot@users.noreply.github.com>`;
  the trailer is optional for human-only commits.
- Never commit build output, `.local-validation/`, APKs, images, private
  keys, passwords or DNS logs (see `.gitignore`).

## Translations

User-visible strings use `_()`; regenerate
`po/templates/adblock-fast-monitor.pot` with LuCI's `build/i18n-scan.pl`.
Translations go in `po/<lang>/adblock-fast-monitor.po` and are packaged as
`luci-i18n-adblock-fast-monitor-<lang>` by `luci.mk`.
