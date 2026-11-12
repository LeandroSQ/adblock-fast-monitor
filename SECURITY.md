# Security policy

## Reporting a vulnerability

Report vulnerabilities privately through GitHub:
<https://github.com/LeandroSQ/adblock-fast-monitor/security/advisories/new>.
Please do not open a public issue. Include the package version, the
OpenWrt version and the steps to reproduce. Expect an answer within 14
days; a fix is released as described in
[`docs/releasing.md`](docs/releasing.md) and credited in the advisory unless
you ask otherwise.

## Supported versions

Only the latest release receives fixes.

## Scope

In scope:

- this package's files: the LuCI views, the rpcd plugin and its ACL, the
  apply job, the init script and the query-logging drop-in;
- rendering of untrusted data (domain names, DNS answers and client
  addresses come from the network);
- the release pipeline, the signed apk feed and the signing key handling
  ([`keys/README.md`](keys/README.md)).

Out of scope, report upstream instead:

- adblock-fast itself and its block lists
  ([openwrt/packages](https://github.com/openwrt/packages/tree/master/net/adblock-fast));
- LuCI, rpcd, logd, dnsmasq and other OpenWrt components
  ([OpenWrt security](https://openwrt.org/docs/guide-developer/security)).

By design, anyone granted this app's read ACL can read the whole system log
(see [README → Privacy: admins only](README.md#privacy-admins-only)); that is
documented behaviour, not a vulnerability.
