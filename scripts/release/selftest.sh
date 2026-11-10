#!/usr/bin/env bash
# Executed test of the release signing pipeline (scripts/release/sign-feed.sh)
# with throwaway ECDSA P-256 keys. Linux x86_64 (SDK host apk).
#
#   scripts/release/selftest.sh WORKDIR PACKAGE.apk
#
# WORKDIR must not exist or be empty; it is deleted at the end (keys included).
# Prints TAP-style lines; exits non-zero on any failure.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="${1:?usage: selftest.sh WORKDIR PACKAGE.apk}"
pkg="${2:?usage: selftest.sh WORKDIR PACKAGE.apk}"
[[ ! -e "$work" ]] || [[ -z "$(ls -A "$work")" ]] || { echo "WORKDIR not empty: $work" >&2; exit 2; }
mkdir -p "$work"
work="$(cd "$work" && pwd)"
trap 'rm -rf "$work"' EXIT
APK="$("$root/scripts/release/apk-tool.sh")" || exit 1
export APK_TOOL="$APK" OPENSSL_CONF=/dev/null
fail=0
ok() { echo "ok - $1"; }
nok() { echo "not ok - $1"; fail=1; }
t() { local name="$1"; shift; if "$@" >"$work/last.log" 2>&1; then ok "$name"; else nok "$name"; sed 's/^/#   /' "$work/last.log"; fi; }
not() { ! "$@"; }

(
	umask 077
	mkdir -p "$work/secret" "$work/keys" "$work/other-keys"
	for k in a b; do openssl ecparam -name prime256v1 -genkey -noout -out "$work/secret/$k.pem"; done
	openssl pkey -in "$work/secret/a.pem" -pubout -out "$work/keys/adblock-fast-monitor.pem"
	openssl pkey -in "$work/secret/b.pem" -pubout -out "$work/other-keys/b.pem"
	openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$work/secret/rsa.pem" 2>/dev/null
)
site="$work/site"
sign() { "$root/scripts/release/sign-feed.sh" --keys-dir "$work/keys" --base-url https://example.invalid/feed "$@"; }
name="$("$APK" adbdump "$pkg" | sed -n 's/^  name: //p' | head -n1)"
version="$("$APK" adbdump "$pkg" | sed -n 's/^  version: //p' | head -n1)"
file="$name-$version.apk"

t 'sign-feed builds a feed with the committed-key pair' sign --key "$work/secret/a.pem" --out "$site" "$pkg"
t 'feed has the package, signed index, SHA256SUMS, key and index.html' \
	test -s "$site/apk/$file" -a -s "$site/apk/packages.adb" -a -s "$site/apk/SHA256SUMS" \
	-a -s "$site/keys/adblock-fast-monitor.pem" -a -s "$site/index.html"
t 'SHA256SUMS matches the published files' bash -c "cd '$site/apk' && sha256sum -c --quiet SHA256SUMS"
t 'package and index verify against the trusted key' "$APK" verify --keys-dir "$work/keys" "$site/apk/$file" "$site/apk/packages.adb"
t 'package and index do not verify against another key' not "$APK" verify --keys-dir "$work/other-keys" "$site/apk/$file"
t 'the unsigned SDK package does not verify' not "$APK" verify --keys-dir "$work/keys" "$pkg"
t 'index.html carries the feed and key URLs' bash -c "grep -q 'https://example.invalid/feed/apk/packages.adb' '$site/index.html' &&
	grep -q 'https://example.invalid/feed/keys/adblock-fast-monitor.pem' '$site/index.html' && ! grep -q '@[A-Z_]*@' '$site/index.html'"

newroot() {
	rm -rf "$1"; mkdir -p "$1/etc/apk/keys"
	"$APK" --root "$1" --initdb --no-cache --arch x86_64 --repositories-file /dev/null add >/dev/null
}
r="$work/root-trusted"; newroot "$r"; cp "$work/keys/adblock-fast-monitor.pem" "$r/etc/apk/keys/"
apkr() { "$APK" --root "$1" --no-cache --arch x86_64 --repositories-file /dev/null --repository "$site/apk/packages.adb" "${@:2}"; }
t 'a root that trusts the key lists the package from the feed' bash -c \
	"$(declare -f apkr); APK='$APK' site='$site'; apkr '$r' search -x '$name' | grep -qx '$name-$version'"
r2="$work/root-untrusted"; newroot "$r2"
t 'a root without the key rejects the index' bash -c \
	"$(declare -f apkr); APK='$APK' site='$site'; out=\$(apkr '$r2' search -x '$name' 2>&1); echo \"\$out\"; ! grep -qx '$name-$version' <<<\"\$out\" && grep -q 'UNTRUSTED' <<<\"\$out\""

t 'signing with a key whose public half is not committed fails' not sign --key "$work/secret/b.pem" --out "$work/site-b" "$pkg"
t 'a non-P-256 key is refused' not sign --key "$work/secret/rsa.pem" --out "$work/site-rsa" "$pkg"
mkdir -p "$work/empty-keys"
t 'no committed public key at all fails' not "$root/scripts/release/sign-feed.sh" --keys-dir "$work/empty-keys" \
	--key "$work/secret/a.pem" --out "$work/site-none" "$pkg"

mkdir -p "$work/prev-bad" "$work/prev-files/usr/share/doc"
echo old >"$work/prev-files/usr/share/doc/old"
"$APK" mkpkg --info "name:$name" --info version:0.0.1-r1 --info arch:noarch --info description:old \
	--files "$work/prev-files" --output "$work/prev-bad/$name-0.0.1-r1.apk" >/dev/null
"$APK" adbsign --allow-untrusted --sign-key "$work/secret/b.pem" "$work/prev-bad/$name-0.0.1-r1.apk" >/dev/null 2>&1
t 'a previous package signed by another key makes the mandatory verify fail' \
	not sign --key "$work/secret/a.pem" --out "$work/site-prev" --previous "$work/prev-bad" "$pkg"

cp "$site/apk/$file" "$work/tampered.apk"
size=$(stat -c %s "$work/tampered.apk")
printf 'X' | dd of="$work/tampered.apk" bs=1 seek=$((size - 20)) conv=notrunc status=none
t 'a tampered signed package fails apk verify' not "$APK" verify --keys-dir "$work/keys" "$work/tampered.apk"

exit "$fail"
