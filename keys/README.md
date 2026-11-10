# Package signing keys

This directory holds the **public** halves of the keys that sign the apk feed
and the release packages. Private keys are never committed.

| File | Status |
| --- | --- |
| `adblock-fast-monitor.pem` | **not created yet** — the maintainer generates it offline (below) |

Until `adblock-fast-monitor.pem` exists, `release.yml` fails at the signing
step on purpose; CI builds stay unsigned developer builds.

## Generate the key (maintainer, offline, once)

ECDSA P-256 in PEM, the same format OpenWrt's own `private-key.pem` uses:

```sh
openssl ecparam -name prime256v1 -genkey -noout -out afm-2026.key.pem   # keep OUT of the repo
openssl pkey -in afm-2026.key.pem -pubout -out keys/adblock-fast-monitor.pem
openssl pkey -pubin -in keys/adblock-fast-monitor.pem -outform DER | sha256sum   # fingerprint
gh secret set APK_SIGNING_KEY --env release < afm-2026.key.pem
```

Commit `keys/adblock-fast-monitor.pem` and record the fingerprint below. Keep
an offline backup of the private key (password manager). Never reuse the SDK's
auto-generated `private-key.pem`.

Fingerprint (SHA-256 of the DER public key): _to be filled in with the key_.

## How the key is used

- `release.yml` job `sign` (environment `release`, secret `APK_SIGNING_KEY`)
  runs `scripts/release/sign-feed.sh`: `apk adbsign` on each package,
  `apk mkndx --sign-key` for `packages.adb`, then a mandatory
  `apk verify --keys-dir keys/` of everything it publishes. It refuses a key
  whose public half is not in this directory.
- Routers trust it through LuCI → System → Administration → Repository Public
  Keys (saved as `/etc/apk/keys/adblock-fast-monitor.pem`). The package lists
  that file in `/lib/upgrade/keep.d/` so sysupgrade keeps it.

## Rotation

1. Generate the new key as above and commit it as a second file, e.g.
   `keys/adblock-fast-monitor-2027.pem`.
2. For an overlap period sign with both keys (`apk adbsign --allow-untrusted
   --sign-key new.pem` on the already signed index and packages adds a second
   signature; apk accepts either).
3. Tell users to add the new key on the Repository Public Keys page.
4. Drop the old signature and delete the old public key here.

Routers that never added the new key see `UNTRUSTED signature` on
`apk update` once the old signature is gone.

## Compromise

apk has no revocation. Rotate immediately, publish an advisory, and tell users
to delete the old key on the Repository Public Keys page.
