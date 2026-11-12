# Package signing keys

This directory holds the **public** halves of the keys that sign the apk feed
and the release packages. Private keys are never committed: `.gitignore`
rejects `*.key`, `*.key.pem` and `*private*.pem`, and CI runs gitleaks over
the whole history. Report a suspected key leak privately as described in
[SECURITY.md](../SECURITY.md).

| File | Status |
| --- | --- |
| `adblock-fast-monitor.pem` | **not created yet** — the maintainer generates it offline (below) |

Until `adblock-fast-monitor.pem` exists, `release.yml` fails in its first
step on purpose; CI builds stay unsigned developer builds.

## Generate the key (maintainer, offline, once)

ECDSA P-256 in PEM, the same format OpenWrt's own `private-key.pem` uses.
The private key lives only in `~/.afm-keys` (mode 0700, created in a
subshell with `umask 077`), never inside a checkout. The commands work on macOS and Linux
(`openssl dgst` instead of `sha256sum`):

```sh
(umask 077 && mkdir -p ~/.afm-keys &&
  openssl ecparam -name prime256v1 -genkey -noout -out ~/.afm-keys/afm-2026.key.pem)
openssl pkey -in ~/.afm-keys/afm-2026.key.pem -pubout -out keys/adblock-fast-monitor.pem
openssl pkey -pubin -in keys/adblock-fast-monitor.pem -outform DER | openssl dgst -sha256   # fingerprint
gh secret set APK_SIGNING_KEY --env release < ~/.afm-keys/afm-2026.key.pem
```

Commit `keys/adblock-fast-monitor.pem` and record the fingerprint below. Keep
an offline backup of `~/.afm-keys/afm-2026.key.pem` (password manager), then
`ls -la ~/.afm-keys` should show `drwx------` and `-rw-------`. Never reuse
the SDK's auto-generated `private-key.pem`.

Fingerprint (SHA-256 of the DER public key): _to be filled in with the key_.

## Repository settings and release flow

The one-time repository settings (the `release` environment that holds
`APK_SIGNING_KEY`, Pages, rulesets) and the release steps are in
[`docs/releasing.md`](../docs/releasing.md).

## How the key is used

- `release.yml` job `sign` (environment `release`, secret `APK_SIGNING_KEY`)
  runs `scripts/release/sign-feed.sh`: `apk adbsign` on each package,
  `apk mkndx --sign-key` for `packages.adb`, then a mandatory
  `apk verify --keys-dir keys/` of everything it publishes. It refuses a key
  whose public half is not in this directory. It signs only the APK whose
  sha256 the `build` job reported, downloaded by artifact id.
- Routers trust it through LuCI → System → Administration → Repository Public
  Keys (saved as `/etc/apk/keys/adblock-fast-monitor.pem`). The package lists
  that file in `/lib/upgrade/keep.d/` so sysupgrade keeps it.

## Rotation

1. Generate the new key as above (e.g. `~/.afm-keys/afm-2027.key.pem`) and
   commit its public half as a second file, e.g.
   `keys/adblock-fast-monitor-2027.pem`.
2. For an overlap period sign with both keys (`apk adbsign --allow-untrusted
   --sign-key new.pem` on the already signed index and packages adds a second
   signature; apk accepts either).
3. Tell users to add the new key on the Repository Public Keys page.
4. Drop the old signature, delete the old public key here, and replace the
   `APK_SIGNING_KEY` secret.

Routers that never added the new key see `UNTRUSTED signature` on
`apk update` once the old signature is gone.

## Compromise

apk has no revocation. Rotate immediately, delete the old `APK_SIGNING_KEY`
secret, publish an advisory (see [SECURITY.md](../SECURITY.md)), and tell
users to delete the old key on the Repository Public Keys page.
