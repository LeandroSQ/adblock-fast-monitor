# Releasing

Maintainer guide. Contributors never tag, release or change repository
settings (AGENTS.md hard restriction 7). The signing key's custody and
rotation are in [`keys/README.md`](../keys/README.md); the workflow
[`.github/workflows/release.yml`](../.github/workflows/release.yml) is the
source for the release jobs.

## Versioning

The package version is `PKG_VERSION-rPKG_RELEASE` in the `Makefile`, and a
release tag is `v` plus that string (for example `v0.2.0-r1`).

- `PKG_VERSION` follows semantic versioning for the user-visible package:
  patch for fixes, minor for features, major for changes that need user
  action. Reset `PKG_RELEASE` to `1` when it changes.
- `PKG_RELEASE` alone goes up for packaging-only changes (file modes,
  scripts, translations) with no behaviour change.
- The contract's `api` number goes up with any change to a name, field,
  type, bound, state or error code (AGENTS.md hard restriction 10); such a
  release is at least a minor version.
- Every release has a section in [`CHANGELOG.md`](../CHANGELOG.md).

## Before the first release (once)

Nothing in the repository changes these settings; the maintainer sets them
by hand.

1. Turn on **private vulnerability reporting** (Settings → Security), which
   [`SECURITY.md`](../SECURITY.md) points to.
2. Generate the signing key and commit its public half as
   [`keys/README.md`](../keys/README.md) describes; record the fingerprint
   there.
3. **Environment `release`** (Settings → Environments): the maintainer as
   required reviewer (the `sign` job waits for approval); under
   *Deployment branches and tags*, only a **tag** rule `v*`; the
   environment secret `APK_SIGNING_KEY`. Only the `sign` job uses it.
4. **Pages**: Settings → Pages → Source = *GitHub Actions*. GitHub creates
   the `github-pages` environment allowing only the default branch;
   releases deploy from a tag, so add a **tag** rule `v*` there or the
   `deploy` job is rejected. The URL must stay
   `https://leandrosq.github.io/adblock-fast-monitor` (it is baked into the
   feed page and the release notes; the `smoke` job fails on another URL).
5. **Branch ruleset for `main`**: pull requests required, required check
   `ci-ok` (it fails when any other CI job failed or was skipped without a
   docs-only reason), review from code owners
   ([`CODEOWNERS`](../.github/CODEOWNERS)).
6. **Tag ruleset for `v*`**: only maintainers may create tags, and nobody
   may update or delete them.
7. **Actions**: workflow permissions *Read repository contents*; require
   approval for workflows from outside collaborators.

## Cutting a release

1. Bump `PKG_VERSION`/`PKG_RELEASE` and move the `Unreleased` entries of
   `CHANGELOG.md` under the new version, in one pull request.
2. Build the APK from that commit and run, locally, the suites that CI does
   not run on every change: T30 (`scripts/release/verify-upgrade.sh`) when
   the upgrade path may be affected, and T26
   (`npm run test:performance:measure`) when package code changed. Record
   the executed results in [`test-traceability.md`](test-traceability.md).
3. After the pull request merges and `ci-ok` is green on `main`, push the
   tag `vX.Y.Z-rN` from that commit.

`release.yml` then:

1. builds the APK in the pinned SDK without caches or secrets, and records
   its SHA-256;
2. runs the host checks, the guest and browser suites and T22 against it;
3. `sign` (environment `release`, the only job with the key) checks the
   artifact's SHA-256 against the build output, signs the package and the
   feed index with `scripts/release/sign-feed.sh`, verifies them against
   `keys/`, attests build provenance and creates a **draft** GitHub release;
4. deploys the feed to GitHub Pages;
5. installs the exact new version from the published feed on a stock
   25.12.6 guest (retrying for up to ~12 min while the Pages cache
   expires), then publishes the draft.

A failed run can be re-run; assets of an existing draft are replaced. The
feed holds the published releases, so a withdrawn release is removed by
deleting it on GitHub and cutting a fixed release (note both in
`CHANGELOG.md`). Security fixes follow [`SECURITY.md`](../SECURITY.md).
