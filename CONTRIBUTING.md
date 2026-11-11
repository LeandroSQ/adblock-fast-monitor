# Contributing

The rules every change must follow (hard restrictions, architecture,
commands, testing obligations) are in [`AGENTS.md`](AGENTS.md); they apply to
humans and coding agents alike. The interface is frozen in
[`docs/CONTRACT.md`](docs/CONTRACT.md). This file covers the workflow.
Contributions are licensed under the [Apache License 2.0](LICENSE).

## Setup

- Node.js ≥ 22.13 and Docker, then `npm ci` (also needed for
  `npm run verify:host`; see Tooling).
- The first `npm run verify:host` builds the host userland image (cached).
- Guest suites need the baseline image, built once with
  `scripts/guest/prepare-baseline.sh`; see [`docs/testing.md`](docs/testing.md).

## Workflow

1. Fork, then branch from `main`. One topic per branch.
2. Change code and its tests together (AGENTS.md → Testing obligations). A
   contract change edits `docs/CONTRACT.md` in the same commit.
3. Run `npm run verify:host` (must pass). For package code, build an APK
   and run the affected guest and browser tests:
   `npm run verify:guest -- [--browser] PKG.apk [test/guest/FILE...]`.
   A change to the upgrade path also needs
   `scripts/release/verify-upgrade.sh PKG.apk`.
4. Update `docs/test-traceability.md` with the runs you executed when your
   change alters a feature's tests or result, and add a line under
   `Unreleased` in `CHANGELOG.md` for user-visible changes.
5. Open a pull request. CI repeats the checks ([`docs/testing.md`](docs/testing.md) → CI)
   and reports them as the required check `ci-ok`; push only after local
   validation passes.

## Tooling

- Node.js ≥ 22.13. `npm ci` installs ESLint, markdownlint and Playwright and
  points git at the repository hooks (`core.hooksPath=.githooks`); without
  `npm ci`, run `npm run hooks:install` (undo: `npm run hooks:uninstall`).
- `npm run lint:tools` (`scripts/lint/fetch-tools.sh`) installs the pinned
  ShellCheck 0.11.0 and actionlint 1.7.12 into the local validation cache
  (SHA-256 checked). A copy on PATH is used only if it is the same version;
  otherwise the run reports them as SKIPPED locally and fails under `CI`.
- `npm run lint` runs ESLint (`eslint.config.mjs`: JS, JSON, LuCI views as
  function bodies with their `'require'` bindings, HTML-sink and `E()`
  string-child guards), markdownlint (`.markdownlint.jsonc`), ShellCheck
  (`.shellcheckrc`; `-s sh` for BusyBox files, `-s bash` for bash),
  actionlint and a whitespace check. `npm run verify:host` starts with it.
  `npm run lint:fix` applies ESLint autofixes. Style follows `.editorconfig`;
  no Prettier or shfmt.
- `scripts/lint/baseline.json` lists tolerated existing findings per file
  and rule. It only shrinks: a new finding fails, and so does a fixed one
  until `npm run lint:baseline` lowers the count. Never add entries.
- Hooks (Docker-free): `pre-commit` runs `npm run verify:commit` (lint,
  check-static without its container phase, reported as SKIPPED, and the
  docs self-check) plus gitleaks on the staged diff when installed;
  `commit-msg` enforces the subject rule below. Bypass once with
  `git commit --no-verify`; `npm run verify:host` and CI still run.

## Commits

- Subject: imperative, ≤ 72 characters, optionally prefixed with the area
  (`UI:`, `perf gate:`, `packaging:`, `docs:`). Body: what and why, wrapped
  at ~72 columns, citing CONTRACT sections or test IDs (T01–T32, P1–P10).
- Coherent increments: each commit passes `npm run verify:host`.
- Move or rename files with `git mv` so history follows them.
- Commits written with an AI coding agent end with its `Co-authored-by:`
  trailer.
- Never commit build output, `.local-validation/`, APKs, images, private
  keys, passwords or DNS logs (see `.gitignore`).

## Translations

User-visible strings use `_()`; regenerate
`po/templates/adblock-fast-monitor.pot` with LuCI's `build/i18n-scan.pl`.
Translations go in `po/<lang>/adblock-fast-monitor.po` and are packaged as
`luci-i18n-adblock-fast-monitor-<lang>` by `luci.mk`.

## Security issues

Do not open public issues for vulnerabilities; see [`SECURITY.md`](SECURITY.md).
