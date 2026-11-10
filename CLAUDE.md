# Claude Code

The project instructions are in AGENTS.md (single source of truth), imported here:

@AGENTS.md

Claude-specific deltas:

- Claude Code does not read `.github/instructions/`. Before editing files that
  match a glob below, read the matching file:
  - `root/usr/share/ucode/**`, `root/usr/libexec/**`, `root/usr/share/rpcd/ucode/**` → `.github/instructions/ucode.instructions.md`
  - `root/www/**` → `.github/instructions/luci-js.instructions.md`
  - `root/etc/**` → `.github/instructions/shell-init.instructions.md`
  - `test/**` → `.github/instructions/tests.instructions.md`
  - `.github/workflows/**` → `.github/instructions/workflows.instructions.md`
  - `scripts/**` → `.github/instructions/scripts.instructions.md`
- Keep personal notes out of the repository: a `CLAUDE.local.md` is
  personal and must never be committed.
