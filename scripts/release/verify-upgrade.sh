#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Package upgrade check in one command:
#
#   scripts/release/verify-upgrade.sh NEW.apk
#
# 1. Builds the old package with PKG_VERSION lowered to $ABFM_OLD_PKG_VERSION
#    (default 0.0.9), through scripts/build-package.sh in a scratch copy
#    (.ci-work/upgrade-old). Its source is the source of NEW.apk (its
#    build-package.sh source/ directory when present, else this worktree):
#    api 1 was never released, so every real upgrade is api 2 -> api 2.
#    ABFM_OLD_REF=<git ref> builds the old package from that ref instead.
# 2. Signs old and new into one feed with a throwaway ECDSA key that never
#    touches this repository: on Linux x86_64 it lives in a mktemp directory,
#    elsewhere only inside a disposable linux/amd64 container; it is deleted
#    right after signing.
# 3. Boots a guest without the package and runs
#    test/guest/package-upgrade.host.sh (install old from the feed, query
#    logging on, conffile change, one applied rule, `apk upgrade`, assertions).
# NEW.apk must be inside the worktree or .local-validation.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
new="${1:?usage: scripts/release/verify-upgrade.sh NEW.apk}"
[[ -f "$new" ]] || { echo "not found: $new" >&2; exit 2; }
old_pkg_version="${ABFM_OLD_PKG_VERSION:-0.0.9}"
old_ref="${ABFM_OLD_REF:-same}"
log() { printf 'verify-upgrade: %s\n' "$*" >&2; }
linux_x86=0
[[ "$(uname -s)-$(uname -m)" == Linux-x86_64 ]] && linux_x86=1
amd64() { if ((linux_x86)); then "$@"; else scripts/in-docker.sh --platform linux/amd64 -- "$@"; fi; }

# 1. old package
scratch=.ci-work/upgrade-old
rm -rf "$scratch"
mkdir -p "$scratch/scripts"
if [[ "$old_ref" == same ]]; then
	src="$(dirname "$new")/source"
	[[ -f "$src/Makefile" && -d "$src/root" ]] || src="$root"
	tar -C "$src" -cf - Makefile root $([[ -d "$src/po" ]] && echo po) | tar -C "$scratch" -xf -
else
	src="git $old_ref"
	git -C "$root" archive "$old_ref" Makefile root po | tar -C "$scratch" -xf -
fi
# api 1 shipped the resident daemon (docs/CONTRACT.md §3 migration).
old_api=2
[[ -e "$scratch/root/usr/libexec/adblock-fast-monitor/monitord.uc" ]] && old_api=1
cp scripts/build-package.sh "$scratch/scripts/"
mkdir -p .local-validation
ln -s ../../.local-validation "$scratch/.local-validation"
sed -i.bak -e "s/^PKG_VERSION:=.*/PKG_VERSION:=$old_pkg_version/" -e 's/^PKG_RELEASE:=.*/PKG_RELEASE:=1/' "$scratch/Makefile"
rm -f "$scratch/Makefile.bak"
log "building $old_pkg_version-r1 from $src"
old="$(ABFM_BUILD_FROM=worktree amd64 "$scratch/scripts/build-package.sh" | tail -n 1)"
# scripts/in-docker.sh mounts the checkout at /workspace.
old="${old/#\/workspace\//$root/}"
[[ -f "$old" ]] || { log "old build failed"; exit 1; }
cp "$old" "$scratch/old.apk"
cp "$new" "$scratch/new.apk"

# 2. throwaway-key feed: v1 (old only) and v2 (new + the same signed old),
#    like two consecutive releases
feed=.ci-work/upgrade-feed
rm -rf "$feed"
sign='set -euo pipefail
	k="$1"; shift
	(umask 077 && mkdir -p "$k/secret" && openssl ecparam -name prime256v1 -genkey -noout -out "$k/secret/key.pem")
	mkdir -p "$k/keys"
	openssl pkey -in "$k/secret/key.pem" -pubout -out "$k/keys/adblock-fast-monitor.pem"
	trap "rm -rf \"$k/secret\"" EXIT
	out="$1" old="$2" new="$3"
	scripts/release/sign-feed.sh --key "$k/secret/key.pem" --keys-dir "$k/keys" --out "$out/v1" "$old"
	scripts/release/sign-feed.sh --key "$k/secret/key.pem" --keys-dir "$k/keys" --out "$out/v2" \
		--previous "$out/v1/apk" "$new"'
if ((linux_x86)); then
	keydir="$(mktemp -d)"
	trap 'rm -rf "$keydir"' EXIT
	bash -c "$sign" _ "$keydir" "$feed" "$scratch/old.apk" "$scratch/new.apk"
	rm -rf "$keydir"
else
	scripts/in-docker.sh --platform linux/amd64 -- bash -c "$sign" _ /root/feed-key "$feed" "$scratch/old.apk" "$scratch/new.apk"
fi

# 3. guest
export ABFM_UPGRADE_TEST=1 ABFM_FEED_DIR="$feed" ABFM_OLD_VERSION="$old_pkg_version-r1" ABFM_OLD_API="$old_api"
run=(scripts/guest/run-guest-tests.sh --no-install "$new" test/guest/package-upgrade.host.sh)
if ((linux_x86)) && command -v qemu-system-x86_64 >/dev/null; then
	exec "${run[@]}"
fi
exec scripts/in-docker.sh -- "${run[@]}"
