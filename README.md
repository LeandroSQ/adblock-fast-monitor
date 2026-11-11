# luci-app-adblock-fast-monitor

A LuCI app for OpenWrt 25.12 that shows what
[adblock-fast](https://github.com/openwrt/packages/tree/master/net/adblock-fast)
does with your DNS queries and lets you allow or block a name in a click. It
is a separate package that depends on adblock-fast; it contains no
adblock-fast code and never patches it.

> **Status:** not released yet. The signed feed below goes live with the
> first release; until then only [developer builds](#developer-builds-unsigned)
> exist. Changes: [`CHANGELOG.md`](CHANGELOG.md).

## Features

- **Recent queries** (Services → Adblock Fast Monitor): the last few hundred
  DNS queries with time, name, type, answer and whether adblock-fast blocked
  or allowed them, and why (list, cache, upstream, local name, hosts file…).
  The page refreshes while it is visible and stops when the tab is hidden.
- **Allow / Block** on each row. Changes are staged in the browser and
  applied together with one **Apply**, which writes adblock-fast's
  `allowed_domain`/`blocked_domain`, runs one adblock-fast rebuild and checks
  the result with real DNS lookups.
- **Blocked %** over the shown rows (with their count and time span) and
  counters since the page was opened.
- **No resident process.** The page reads the system log in your browser,
  like LuCI's System Log page does. On the router the package only turns on
  dnsmasq's query logging (a runtime drop-in; `/etc/config/dhcp` is never
  edited) and runs a short job while an Apply is in progress.

## Privacy and access

- **Admins only.** The dashboard needs read access to the **whole system
  log** (`log read`: kernel, authentication and DHCP messages and every DNS
  client address), the same access as luci-app-adblock-fast and System →
  System Log. Grant `luci-app-adblock-fast-monitor` only to logins that may
  read the system log.
- **What is logged.** With query logging on, dnsmasq writes every DNS query,
  with the client's address, to the system log. logd keeps it in RAM by
  default; if logd also writes to a file (`log_file`) or a remote host
  (`log_ip`), the queries go there too, and the page warns about it.
- **What the package keeps.** Nothing about clients on the router. The page
  keeps its rows in browser memory; staged changes (domain names only) stay
  in the browser's local storage until applied or cancelled. The client
  column and the router's own queries are hidden by default.

## Install

Requires OpenWrt 25.12 (apk) and adblock-fast. The package also pulls
`luci-base` and the `ucode-mod-io` and `ucode-mod-resolv` modules from the
official feeds.

### From the signed feed (LuCI only)

Releases are signed and published as an apk feed on GitHub Pages:
<https://leandrosq.github.io/adblock-fast-monitor/>. Once per router:

1. **Check the key.** On a computer, download the key and compare its
   fingerprint with the one in [`keys/README.md`](keys/README.md):

   ```sh
   curl -fsSLO https://leandrosq.github.io/adblock-fast-monitor/keys/adblock-fast-monitor.pem
   openssl pkey -pubin -in adblock-fast-monitor.pem -outform DER | openssl dgst -sha256
   ```

2. **System → Administration → Repository Public Keys**: paste
   `https://leandrosq.github.io/adblock-fast-monitor/keys/adblock-fast-monitor.pem`
   and click **Add key**.
3. **System → Software → Configure apk**: add
   `https://leandrosq.github.io/adblock-fast-monitor/apk/packages.adb` to
   `customfeeds.list` and **Save**.
4. **Update lists…**, filter for `luci-app-adblock-fast-monitor`,
   **Install…**.
5. Open **Services → Adblock Fast Monitor → Settings**, tick **Log DNS
   queries** and **Save & Apply** (skip this if dnsmasq already logs
   queries, for example through luci-app-adblock-fast; the page tells you).

Updates appear under **System → Software → Updates**. Without the feed, add
the key (steps 1–2), download the signed `.apk` from a GitHub release and use
**Upload Package…**. LuCI refuses unsigned packages. The key file is kept
across sysupgrade; apk keeps `customfeeds.list`.

Translations install as `luci-i18n-adblock-fast-monitor-<lang>`.

### Developer builds (unsigned)

Build with Docker (`scripts/in-docker.sh --platform linux/amd64 -- scripts/build-package.sh`,
which packages the committed `HEAD` and refuses uncommitted changes unless
`ABFM_BUILD_FROM=worktree`; see [`docs/testing.md`](docs/testing.md)) or
download the
`luci-app-adblock-fast-monitor-unsigned-dev` artifact of a CI run on `main`
(pull requests do not publish one). Install over SSH:

```sh
scp -O luci-app-adblock-fast-monitor-*.apk root@router:/tmp/
ssh root@router 'apk add --allow-untrusted /tmp/luci-app-adblock-fast-monitor-*.apk'
```

## Limitations

- **Short history.** Queries share logd's ring buffer (System → System →
  Logging → *System log buffer size*, 128 KiB by default: a few hundred
  queries) with every other service. The page shows the span it covers and
  how many entries it missed; on a busy network some are always missed.
- **dnsmasq only.** In adblock-fast's `ipset`/`nftset` modes blocking happens
  in the firewall, so the log cannot show it. smartdns and unbound are not
  supported.
- **Rules are adblock-fast's.** Allow and Block edit adblock-fast's own
  allowed and blocked domain lists; a rebuild takes as long as adblock-fast
  needs to download and process its lists.

The full list with reasons is in [`docs/CONTRACT.md`](docs/CONTRACT.md) §14.

## Troubleshooting

| The page says | Do this |
| --- | --- |
| DNS query logging is off | Settings → tick **Log DNS queries** → Save & Apply. |
| dnsmasq writes its log to a file | Clear dnsmasq's log facility (`logfacility` in `/etc/config/dhcp`, Network → DHCP and DNS); queries must reach the system log. |
| The system log was restarted and dnsmasq has logged nothing since | Restart dnsmasq (System → Startup → dnsmasq → Restart). |
| Log entries missed / short time span | Raise *System log buffer size* (System → System → Logging). |
| Apply refused: uncommitted changes | Run `uci changes adblock-fast` over SSH, then `uci commit adblock-fast` or `uci revert adblock-fast`. |
| Everything shows as allowed | adblock-fast runs in `ipset`/`nftset` mode (see Limitations). |
| Upload Package… fails with `UNTRUSTED signature` | Add the key first (Install, steps 1–2). |

## Uninstall

System → Software → Installed → `luci-app-adblock-fast-monitor` →
**Remove…** (or `apk del luci-app-adblock-fast-monitor`). Removal deletes the
query-logging drop-in and restarts dnsmasq once if it was active; `/etc/config/adblock-fast-monitor`
may remain. Rules you applied stay in adblock-fast's configuration; manage
them in luci-app-adblock-fast. To drop the feed, remove its line from
`customfeeds.list` and the key from Repository Public Keys.

## Contributing

Start with [`CONTRIBUTING.md`](CONTRIBUTING.md) and [`AGENTS.md`](AGENTS.md)
(rules for humans and coding agents). The interface is frozen in
[`docs/CONTRACT.md`](docs/CONTRACT.md); all docs are listed in
[`docs/README.md`](docs/README.md).

## Security

Report vulnerabilities privately as described in [`SECURITY.md`](SECURITY.md).

## License

Copyright 2026 Leandro Quaresma and contributors. Licensed under the
[Apache License 2.0](LICENSE).

This is an independent project, not affiliated with or endorsed by OpenWrt
or the adblock-fast authors. It contains no adblock-fast code; adblock-fast
is a separate package under its own license.
