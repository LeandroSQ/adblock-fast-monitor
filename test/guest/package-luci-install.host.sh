#!/usr/bin/env bash
# T22 (§2 install): the end-user path through LuCI only, without
# --allow-untrusted, on a guest that does NOT have the package yet:
#
#   ABFM_INSTALL_TEST=1 scripts/guest/run-guest-tests.sh --no-install \
#       PACKAGE.apk test/guest/package-luci-install.host.sh
#
# 1. Builds a feed signed with a throwaway ECDSA key exactly like release.yml
#    (scripts/release/sign-feed.sh; the private key is deleted right after
#    signing), or uses a prebuilt one from ABFM_FEED_DIR (needed when the host
#    is not Linux x86_64; the public key must be ABFM_FEED_DIR/keys/*.pem).
# 2. Serves it like GitHub Pages (CORS) on a host port; the guest sees it at
#    $GUEST_HOST_URL's host (10.0.2.2).
# 3. Runs test/browser/install-luci.spec.mjs: unsigned upload refused, key
#    added on "Repository Public Keys" by URL, signed "Upload Package…"
#    install, objects/ACL without an rpcd restart, removal through LuCI and its
#    cleanup, then install from the feed via "Configure apk".
#
# Without ABFM_INSTALL_TEST=1 it is skipped (it needs a --no-install guest).
# ABFM_ALLOW_MISSING_BACKEND=1 is passed through (see package-files.host.sh).
set -u
. test/lib/sh/testlib.sh
pkg=luci-app-adblock-fast-monitor

if [[ "${ABFM_INSTALL_TEST:-0}" != 1 ]]; then
	t_skip 'T22 LuCI install from a signed feed' 'needs ABFM_INSTALL_TEST=1 and a --no-install guest'
	t_done
fi
if guest_exec "apk info -e $pkg" >/dev/null 2>&1; then
	t__result 1 'the guest does not have the package yet' 'run with run-guest-tests.sh --no-install'
	t_done
fi

work="$GUEST_RUN_DIR/feed"
server=''
cleanup() {
	[[ -z "$server" ]] || kill "$server" 2>/dev/null
	rm -rf "$work/secret"
}
trap cleanup EXIT
site="${ABFM_FEED_DIR:-}"
if [[ -z "$site" ]]; then
	rm -rf "$work"
	mkdir -p "$work/keys"
	(umask 077 && mkdir "$work/secret" && openssl ecparam -name prime256v1 -genkey -noout -out "$work/secret/key.pem")
	openssl pkey -in "$work/secret/key.pem" -pubout -out "$work/keys/adblock-fast-monitor.pem"
	t_ok 'feed signed with a throwaway key by scripts/release/sign-feed.sh' \
		scripts/release/sign-feed.sh --key "$work/secret/key.pem" --keys-dir "$work/keys" --out "$work/site" "$PACKAGE_APK"
	rm -rf "$work/secret"
	site="$work/site"
fi
site="$(cd "$site" && pwd)"
signed="$(find "$site/apk" -name "$pkg-*.apk" | LC_ALL=C sort | tail -n 1)"
key="$(find "$site/keys" -name '*.pem' | head -n 1)"
t_ok 'the feed has a signed package, packages.adb and a public key' test -s "$signed" -a -s "$site/apk/packages.adb" -a -s "$key"

mkdir -p "$work"
rm -f "$work/port"
python3 scripts/release/serve-site.py --dir "$site" --ready-file "$work/port" 2>"$work/serve-site.log" &
server=$!
for _ in $(seq 50); do [[ -s "$work/port" ]] && break; sleep 0.1; done
port="$(cat "$work/port" 2>/dev/null)"
t_match 'feed server is listening' '^[0-9]+$' "$port"
guest_host="${GUEST_HOST_URL%:*}"

[[ -x node_modules/.bin/playwright ]] || npm ci --no-audit --no-fund >/dev/null
npx playwright install --with-deps chromium >/dev/null 2>&1 || npx playwright install chromium >/dev/null

if MONITOR_BASE_URL="$GUEST_HTTP_URL" ABFM_INSTALL_TEST=1 \
	ABFM_KEY_URL="http://127.0.0.1:$port/keys/$(basename "$key")" ABFM_KEY_FILE="$key" \
	ABFM_FEED_URL="$guest_host:$port/apk/packages.adb" \
	ABFM_SIGNED_APK="$signed" ABFM_UNSIGNED_APK="$PACKAGE_APK" \
	npx playwright test --config test/browser/playwright.config.mjs --reporter=list install-luci; then
	t__result 0 'LuCI install/remove/feed flow (test/browser/install-luci.spec.mjs)'
else
	t__result 1 'LuCI install/remove/feed flow (test/browser/install-luci.spec.mjs)' "feed server log: $work/serve-site.log"
fi
t_done
