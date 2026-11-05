# Domain rule action RPC requirements

`/usr/libexec/rpcd/adblock-fast-monitor-actions` is the only mutable domain-rule
object. The monitoring object (`adblock-fast-monitor`) exposes read-only
`status` and `activity`; its destructive retained-activity `purge` method is
separately ACL write-gated.

## RPC contract

| Object/method | Request | Result |
| --- | --- | --- |
| `adblock-fast-monitor-actions.action` | `{ "action": "allow\|unallow\|block\|unblock", "domain": "lowercase.fqdn", "confirm_rebuild": boolean }` | `{ accepted, state, action, domain }` |
| `adblock-fast-monitor-actions.job` | `{}` | `{ state, result, action, domain, current_rule, persisted, rebuild, active_dns, message }` |

`block`, `unallow`, and `unblock` require exactly `confirm_rebuild: true`.
The UI must show and receive acknowledgement of the disruption warning before
it sends that field: these operations change UCI and invoke the supported
`/etc/init.d/adblock-fast dl` lifecycle action, which can require WAN access
and restart DNS. The worker independently rejects a direct invocation without
that confirmation, so `dl` is never silently queued or run. `allow` exclusively
calls the supported `/etc/init.d/adblock-fast allow DOMAIN` lifecycle action.

The immediate `action` reply only means that one bounded asynchronous job was
accepted. Read `job` for its terminal outcome. The worker stores that outcome
as trusted, fixed-key `key=value` data at `/tmp/adblock-fast-monitor/job`.
Terminal `degraded` with `persisted-active-unknown` is intentional: this
adblock-fast version cannot prove a rule's effect on cached responses, CNAME
chains, or IPv6 resolution. It must not be presented as DNS success.
If `dl` fails, the terminal result is `rebuild-failed-active-unverified`;
the worker does not make a further restart attempt, leaving any prior active
blocking for upstream to preserve, and explicitly reports that its resulting
active DNS state cannot be verified.
Job state is intentionally volatile under `/tmp`; after reboot, `job` can only
report a new/unknown operation and never claims that a pre-reboot DNS state was
verified.

Domains must be lowercase FQDNs with no wildcard, path, whitespace, quote, or
unsafe broad syntax. A complete public-suffix data file is mandatory at
`/usr/share/publicsuffix/public_suffix_list.dat`; without it, the worker rejects
every mutable operation rather than risk a public-suffix action. Existing
allow/block conflicts are rejected, and already-correct state is idempotent.

## Required ACL change

The lifecycle/ACL owner must add this exact object permission; do not grant
these methods through `adblock-fast-monitor`:

```json
"read": {
  "ubus": {
    "adblock-fast-monitor-actions": [ "job" ]
  }
},
"write": {
  "ubus": {
    "adblock-fast-monitor-actions": [ "action" ]
  }
}
```

An unauthorised ubus caller must be denied by rpcd before the adapter starts a
job. The package lifecycle owner must also install the action RPC executable.
