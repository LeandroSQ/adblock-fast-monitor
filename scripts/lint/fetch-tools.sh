#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Installs the pinned ShellCheck and actionlint into
# .local-validation/bin/<uname -s>-<uname -m>/, where scripts/lint/run.mjs
# finds them first. The pins are the only versions `npm run lint` accepts
# (a tool on PATH is used only if it reports the same version), so local runs,
# hooks and CI agree. actionlint >= 1.7.10 is needed for the YAML anchors in
# the workflows; ShellCheck runs with `-s sh` (POSIX + `local`, see .shellcheckrc).
#
#   scripts/lint/fetch-tools.sh        # idempotent; ~10 MB download once
#
# Bump a pin: change the version and every per-platform SHA-256 below
# (actionlint: its release checksums.txt; ShellCheck publishes none, so hash
# the downloaded assets) and the matching constants in scripts/lint/tools.mjs.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
plat="$(uname -s)-$(uname -m)"
SC=0.11.0
AL=1.7.12
case "$plat" in
	Linux-x86_64) sc=linux.x86_64 al=linux_amd64
		sc_sha=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198
		al_sha=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8 ;;
	Linux-aarch64) sc=linux.aarch64 al=linux_arm64
		sc_sha=12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588
		al_sha=325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6 ;;
	Darwin-arm64) sc=darwin.aarch64 al=darwin_arm64
		sc_sha=56affdd8de5527894dca6dc3d7e0a99a873b0f004d7aabc30ae407d3f48b0a79
		al_sha=aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f ;;
	*) echo "fetch-tools: no pinned build for $plat; install ShellCheck $SC and actionlint $AL on PATH" >&2; exit 2 ;;
esac

dest="$root/.local-validation/bin/$plat"
if [[ -x "$dest/shellcheck" && -x "$dest/actionlint" ]] &&
	"$dest/shellcheck" --version | grep -qx "version: $SC" &&
	[[ "$("$dest/actionlint" --version | head -n 1)" == "$AL" ]]; then
	echo "fetch-tools: ShellCheck $SC and actionlint $AL already in $dest"
	exit 0
fi

# Scratch space inside the shared cache (never /tmp), removed on exit.
mkdir -p "$root/.local-validation/bin"
work="$root/.local-validation/bin/.fetch.$$"
rm -rf "$work"
mkdir "$work"
trap 'rm -rf "$work"' EXIT

sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
get() {
	curl -fsSL --retry 3 -o "$work/$3" "$1"
	local got
	got="$(sha256 "$work/$3")"
	[[ "$got" == "$2" ]] || { echo "fetch-tools: SHA-256 mismatch for $1: got $got, want $2" >&2; exit 1; }
}
get "https://github.com/koalaman/shellcheck/releases/download/v$SC/shellcheck-v$SC.$sc.tar.xz" "$sc_sha" sc.tar.xz
get "https://github.com/rhysd/actionlint/releases/download/v$AL/actionlint_${AL}_$al.tar.gz" "$al_sha" al.tar.gz
tar -xJf "$work/sc.tar.xz" -C "$work"
tar -xzf "$work/al.tar.gz" -C "$work" actionlint
mkdir -p "$dest"
install -m 0755 "$work/shellcheck-v$SC/shellcheck" "$work/actionlint" "$dest/"
echo "fetch-tools: installed ShellCheck $SC and actionlint $AL into $dest"
