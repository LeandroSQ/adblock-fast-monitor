# Claude Code

The project instructions are in AGENTS.md (single source of truth), imported here:

@AGENTS.md

Claude-specific deltas:

- Claude Code does not read `.github/instructions/`. Before editing files that
  match a glob below, read the matching file (this list is checked against
  their `applyTo` by `test/unit/docs-references.test.mjs`):
  - `root/usr/share/ucode/**`, `root/usr/libexec/**`, `root/usr/share/rpcd/ucode/**` → `.github/instructions/ucode.instructions.md`
  - `htdocs/**` → `.github/instructions/luci-js.instructions.md`
  - `root/etc/**` → `.github/instructions/shell-init.instructions.md`
  - `test/**` → `.github/instructions/tests.instructions.md`
  - `.github/workflows/**` → `.github/instructions/workflows.instructions.md`
  - `scripts/**` → `.github/instructions/scripts.instructions.md`
  - `Makefile`, `po/**` → `.github/instructions/packaging.instructions.md`
  - `**/*.md` → `.github/instructions/docs.instructions.md`
- `.claude/settings.json` denies pushing, tagging, releases, workflow runs,
  secrets and SSH (AGENTS.md hard restrictions 7–9).
- Keep personal notes out of the repository: a `CLAUDE.local.md` is
  personal and must never be committed.
