#!/usr/bin/env bash
# Builds the signed apk feed and the static site that GitHub Pages serves.
#
#   scripts/release/sign-feed.sh --key PRIVATE.pem --out SITE \
#       [--keys-dir DIR] [--previous DIR] [--base-url URL] NEW.apk...
#
#   --key       ECDSA P-256 private key (PEM). Never written anywhere else.
#   --keys-dir  trusted public keys (default: keys/ in this repo). The key's
#               public half must be one of them, and every published file must
#               verify against this directory alone.
#   --previous  directory with already signed .apk files of earlier releases to
#               keep in the feed (they are re-verified, not re-signed).
#   --base-url  public URL of SITE (default the project's GitHub Pages URL);
#               only used for the instructions in index.html.
#
# Output (SITE):
#   apk/<name>-<version>.apk   adbsign-ed packages (LuCI "Upload Package…" works)
#   apk/packages.adb           index signed with --key (apk feed)
#   apk/SHA256SUMS
#   keys/*.pem                 the trusted public keys
#   index.html                 install instructions
#
# Note: `apk adbsign` prints an error but exits 0 for some failures, so the
# script always ends with `apk verify` against --keys-dir and fails if any
# file does not verify.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
log() { printf 'sign-feed: %s\n' "$*" >&2; }
die() { log "$*"; exit 1; }

key='' out='' keys_dir="$root/keys" previous='' base_url='https://leandrosq.github.io/adblock-fast-monitor'
while (($#)); do
	case "$1" in
		--key) key="$2"; shift 2 ;;
		--out) out="$2"; shift 2 ;;
		--keys-dir) keys_dir="$2"; shift 2 ;;
		--previous) previous="$2"; shift 2 ;;
		--base-url) base_url="${2%/}"; shift 2 ;;
		-h | --help) sed -n '2,26p' "$0"; exit 0 ;;
		--) shift; break ;;
		-*) die "unknown option: $1" ;;
		*) break ;;
	esac
done
(($#)) || die 'no .apk given'
[[ -f "$key" ]] || die "private key not found: $key"
[[ -n "$out" ]] || die '--out is required'
keys_dir="$(cd "$keys_dir" && pwd)"
shopt -s nullglob
pubkeys=("$keys_dir"/*.pem)
shopt -u nullglob
((${#pubkeys[@]})) || die "no trusted public key (*.pem) in $keys_dir; see keys/README.md"

APK="$(APK_TOOL="${APK_TOOL:-}" "$root/scripts/release/apk-tool.sh")"
export OPENSSL_CONF=/dev/null

# The signing key must belong to a committed public key; otherwise fail here
# with a clear message instead of publishing a feed nobody trusts.
pub="$(openssl pkey -in "$key" -pubout 2>/dev/null)" || die "cannot read private key $key"
[[ "$(openssl pkey -in "$key" -noout -text 2>/dev/null | sed -n 's/^ASN1 OID: //p')" == prime256v1 ]] ||
	die 'the signing key must be ECDSA P-256 (prime256v1), as OpenWrt uses'
match=''
for p in "${pubkeys[@]}"; do
	[[ "$(openssl pkey -pubin -in "$p" -pubout 2>/dev/null)" == "$pub" ]] && match="$p"
done
[[ -n "$match" ]] || die "the signing key's public half is not in $keys_dir"
log "signing with the key of $(basename "$match")"

rm -rf "$out"
mkdir -p "$out/apk" "$out/keys"
feed="$(cd "$out/apk" && pwd)"

field() { "$APK" adbdump "$2" | sed -n "s/^  $1: //p" | head -n 1; }
new=()
for src in "$@"; do
	[[ -f "$src" ]] || die "not found: $src"
	name="$(field name "$src")"
	version="$(field version "$src")"
	[[ -n "$name" && -n "$version" ]] || die "not an apk v3 package: $src"
	dst="$feed/$name-$version.apk"
	[[ ! -e "$dst" ]] || die "duplicate package $name-$version"
	cp "$src" "$dst"
	"$APK" adbsign --allow-untrusted --reset-signatures --sign-key "$key" "$dst"
	new+=("$dst")
done
if [[ -n "$previous" ]]; then
	for src in "$previous"/*.apk; do
		[[ -f "$src" ]] || continue
		name="$(field name "$src")"
		version="$(field version "$src")"
		dst="$feed/$name-$version.apk"
		[[ -e "$dst" ]] && { log "skipping previous $name-$version (rebuilt)"; continue; }
		cp "$src" "$dst"
	done
fi

(cd "$feed" && "$APK" mkndx --allow-untrusted --sign-key "$key" --output packages.adb ./*.apk)

# Mandatory: everything published must verify against the trusted keys only.
(cd "$feed" && "$APK" verify --keys-dir "$keys_dir" ./*.apk packages.adb) ||
	die "apk verify failed against $keys_dir"

(cd "$feed" && sha256sum ./*.apk packages.adb | sed 's#  \./#  #' >SHA256SUMS)
cp "${pubkeys[@]}" "$out/keys/"

fingerprints=''
for p in "${pubkeys[@]}"; do
	fp="$(openssl pkey -pubin -in "$p" -outform DER | sha256sum | cut -d' ' -f1)"
	fingerprints+="<li><code>keys/$(basename "$p")</code> SHA-256 (DER): <code>$fp</code></li>"
done
packages=''
while read -r sum file; do
	packages+="<li><a href=\"apk/$file\"><code>$file</code></a> <small>SHA-256 <code>$sum</code></small></li>"
done < <(grep '\.apk$' "$feed/SHA256SUMS" | LC_ALL=C sort -k2 -r)
latest="$(field version "${new[0]}")"
sed -e "s#@BASE_URL@#$base_url#g" -e "s#@KEY_NAME@#$(basename "$match")#g" -e "s#@VERSION@#$latest#g" \
	-e "s#@FINGERPRINTS@#$fingerprints#g" -e "s#@PACKAGES@#$packages#g" \
	"$root/scripts/release/site/index.html" >"$out/index.html"
touch "$out/.nojekyll"
log "feed ready: $out ($(grep -c '\.apk$' "$feed/SHA256SUMS") package(s))"
