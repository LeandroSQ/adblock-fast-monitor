# Runtime test requirements

The GitHub-hosted QEMU gate executes real OpenWrt, dnsmasq, adblock-fast, and
the packaged monitor. The monitoring and actions implementations must satisfy
these observable requirements; this document does not prescribe their source
structure.

## Monitoring collector

* With `enabled=0`, the service must report disabled without a resident
  collector process.
* With `enabled=1`, it must start a resident collector and expose a bounded
  `status` and `activity` response through `adblock-fast-monitor`.
* The private dnsmasq ownership record is
  `/var/run/adblock-fast-monitor/dnsmasq-logqueries.owner`; no UCI value may
  contain that ownership marker.

## Action RPC

* `adblock-fast-monitor-actions.action` must accept a valid test domain action
  and return a bounded job identifier/state.
* `adblock-fast-monitor-actions.job` must report a terminal result for that
  job. The runtime gate calls these methods using `ubus` and fails rather than
  substituting a fixture response.

## Required QEMU assertions

The in-repository runtime script checks package lifecycle, real dnsmasq
resolution against local fixture lists, monitor RPC availability, action/job
responses, and collector resource metrics. If an implementation cannot
support one of these checks, change the production interface together with this
contract and the QEMU gate; do not skip or mock the assertion.
