#!/usr/bin/env bash
# T22 in one command: the end-user install path through LuCI only (no
# --allow-untrusted) on a fresh guest that does not have the package:
#
#   scripts/release/verify-luci-install.sh PACKAGE.apk
#
# A feed is signed with a throwaway ECDSA key by scripts/release/sign-feed.sh
# (the same script release.yml uses) and served like GitHub Pages; then
# test/browser/install-luci.spec.mjs adds the key on "Repository Public Keys",
# installs with "Upload Package…", removes, and installs again from the feed.
#
# On Linux x86_64 the guest test signs the feed itself (key under the run
# directory, deleted right after signing). Elsewhere (e.g. macOS) the feed is
# signed first in a linux/amd64 container whose key lives only inside that
# container, then the guest runs in a native container. PACKAGE.apk must be
# inside the worktree or .local-validation. Results: the printed guest run dir.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
apk="${1:?usage: scripts/release/verify-luci-install.sh PACKAGE.apk}"
[[ -f "$apk" ]] || { echo "not found: $apk" >&2; exit 2; }
test_file=test/guest/package-luci-install.host.sh
export ABFM_INSTALL_TEST=1

if [[ "$(uname -s)-$(uname -m)" == Linux-x86_64 ]]; then
	unset ABFM_FEED_DIR
	if command -v qemu-system-x86_64 >/dev/null; then
		exec scripts/guest/run-guest-tests.sh --no-install "$apk" "$test_file"
	fi
	exec scripts/in-docker.sh -- scripts/guest/run-guest-tests.sh --no-install "$apk" "$test_file"
fi

feed=.ci-work/luci-install-feed
rm -rf "$feed"
mkdir -p .ci-work
scripts/in-docker.sh --platform linux/amd64 -- bash -c '
	set -euo pipefail
	(umask 077 && mkdir -p /root/feed-key && openssl ecparam -name prime256v1 -genkey -noout -out /root/feed-key/key.pem)
	mkdir -p /root/feed-keys
	openssl pkey -in /root/feed-key/key.pem -pubout -out /root/feed-keys/adblock-fast-monitor.pem
	scripts/release/sign-feed.sh --key /root/feed-key/key.pem --keys-dir /root/feed-keys --out "$1" "$2"
	rm -rf /root/feed-key' _ "$feed" "$apk"
ABFM_FEED_DIR="$feed" scripts/in-docker.sh -- scripts/guest/run-guest-tests.sh --no-install "$apk" "$test_file"
