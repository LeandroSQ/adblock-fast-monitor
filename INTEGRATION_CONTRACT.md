# Integration contract

The package integrates independently implemented collector, read RPC, and
action RPC components. Package and UI code must not infer their internals.

## Installed RPC interfaces

| Executable path | ubus object | Methods | ACL |
| --- | --- | --- | --- |
| `/usr/libexec/rpcd/adblock-fast-monitor` | `adblock-fast-monitor` | `status`, `activity` | read |
| `/usr/libexec/rpcd/adblock-fast-monitor` | `adblock-fast-monitor` | `purge` | write |
| `/usr/libexec/rpcd/adblock-fast-monitor-actions` | `adblock-fast-monitor-actions` | `action`, `job` | write |

`purge` clears monitor activity only; it must not change adblock-fast
configuration or blocklists. It is nevertheless destructive and is write-gated.
A read-only overview session must neither render nor invoke it. State-changing
action/job behavior belongs only to the actions plugin. Both paths must be
executable rpcd handlers at package build time.

The QEMU gate provisions a disposable `monitor-readonly` rpcd principal with
only the `luci-app-adblock-fast-monitor` read group. It verifies `status`
access is allowed and the actions object is denied before running the browser
as that principal.

## UCI and service contract

`/etc/config/adblock-fast-monitor` contains one `config monitor 'config'`
section. It supports `enabled` (`0`/`1`), positive integer `max_events`,
positive integer `poll_interval`, and `own_logqueries` (`0`/`1`).

`owner_value` is intentionally not a UCI option and must never be exposed in
LuCI. The monitoring worker records its dnsmasq logging ownership privately at
`/var/run/adblock-fast-monitor/dnsmasq-logqueries.owner`; only root-controlled
collector lifecycle code may create, read, or remove that record. This is the
expected hand-off name for the monitoring worker.

The procd service starts `/usr/libexec/adblock-fast-monitor-collector`, reloads
on configuration changes, and invokes it with `cleanup` at stop. The config is
an opkg conffile, so upgrade preserves user edits and removal follows opkg's
modified-conffile policy.

## UI boundary

The overview uses only the read plugin. Settings uses LuCI's standard UCI form
API. Any action/job view must call only `adblock-fast-monitor-actions`.
