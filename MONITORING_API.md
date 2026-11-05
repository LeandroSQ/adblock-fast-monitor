# Monitoring RPC requirements

The monitor reads only collector-owned bounded artifacts below
`/tmp/adblock-fast-monitor`:

- `activity.tsv`: oldest-first retained decisions. The reader reverses only this
  bounded file in memory before returning a page.
- `status`: `key=value` state summary with `state`, `started`, `allowed`,
  `blocked`, `unknown`, `lost`, and `capacity`; `job` is optional.

The collector owns this root-owned `0700` directory. Activity and status are
atomic `0600` snapshots written only after bounded resident-ring batches under
`monitor.lock`; RPC rejects insecure state rather than publishing it. The
collector never needs a per-decision filesystem operation or subprocess.

The collector must write strict `allowed`, `blocked`, or `unknown` decisions
and increment `lost` whenever retention trims entries. It may append an
optional fifth `current_rule` field when that state is already known; the read
RPC reports `unknown` rather than rescanning active rules.

The separate `adblock-fast-monitor` RPC object exposes:

- `status` → `{state, started, counters:{allowed,blocked,unknown,lost}, capacity, job?}`
- `activity({cursor,limit,search,filter})` → newest-first
  `{events:[{timestamp,decision,domain,reason,current_rule}], next_cursor?, retained, lost}`.
  `cursor` is an opaque decimal match offset; `limit` is clamped to 1–100.
- `purge` → `{state:"applied"}`. This clears retained activity but does not
  invoke service actions. It increments `lost` by the deliberately discarded
  retained records. It is ACL write-gated and unavailable to the read-only

`own_logqueries` remains the only configuration input for monitor-managed
dnsmasq logging. Its ownership/previous-value record is deliberately kept in
the protected runtime directory, not UCI. Any CI/config-schema change must
preserve that boolean without exposing the ownership record as user-editable. It is ACL write-gated and unavailable to the read-only
  dashboard.

No action method belongs to this object. The dashboard calculates coverage as
`(allowed + blocked) / (allowed + blocked + unknown)` and surfaces `lost`
separately rather than claiming dropped records are covered.
