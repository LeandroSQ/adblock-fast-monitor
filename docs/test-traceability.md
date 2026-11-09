# Feature-to-test evidence ledger

This ledger records executed evidence, not intended coverage. Local validation
uses an OpenWrt 25.12.6 x86_64 QEMU guest and a host-served private package
mirror. GitHub Actions workflow files are present in the working tree but have
not been run remotely.

| Vertical | Implemented | Executed evidence | Current result / remaining gate |
| --- | --- | --- | --- |
| Package surface and dependencies | Out-of-tree `luci-app-adblock-fast-monitor` package, runtime dependencies, UCI config, init script, ACLs, menu, and LuCI assets | Official 25.12.6 SDK builds; installed earlier APKs in a stock x86_64 guest | **Partial.** Fresh dependency-corrected artifact is building; its complete install/lifecycle run has not passed. |
| DNS readiness and logging ownership | Opt-in `logqueries=1` ownership and shared A-record readiness helper | Stock BusyBox `nslookup -type=A`; guest resolved `abfm-ring.test` to `192.0.2.1`; generated dnsmasq config contained `log-queries=extra` | **Passed for prerequisite only.** Ownership restore and failure lifecycle remain unverified in a final artifact. |
| Resident log subscription | Resident reader, bounded ring, atomic snapshots, nonblocking lock contract | Long-lived `logread -f` saw a marker plus authentic dnsmasq extra records with serial/client envelope | **Failed publication gate.** Earlier `fs.popen()` line and chunk reader variants blocked despite stream evidence. Current explicit `io.pipe()` + `uloop.process()` reader is unvalidated in stock guest. |
| Activity classification | Local-config, known explicit block, upstream reply/cache/NXDOMAIN, and CNAME-ambiguous branches | Static classification/resource/metadata contracts pass; temporary diagnostic earlier reached first local-config and explicit-block publication before the idle flush defect | **Pending production proof.** Final artifact must assert all rows, strict serial/client correlation, unpaired rejection, IPv6 framing, restart reuse, malicious input rejection, and one-query counting. |
| Downloaded-list attribution | Bounded classifier and inventory helper outside DNS ingest path | Static classifier contracts pass | **Not integrated or runtime-proven.** No classification result from active downloaded output is exposed to production activity yet. |
| Locking and purge generation | ucode file-handle nonblocking locks and generation checks | Temporary stock diagnostic confirmed file-handle lock acquisition and initial snapshot publication; static contracts pass | **Pending cross-process proof.** Shell RPC purge/action, reader, and classifier must contend on the same inode without blocking ingestion or resurrecting purged state. |
| LuCI dashboard and accessibility | Native LuCI overview/settings pages, model, polling, filter/cursor controls, and user states | Host-side model and package-surface contracts pass | **Pending browser proof.** No real LuCI Software upload/install or Playwright browser workflow has passed on a final artifact. |
| Domain actions | Server-side validation, protected-domain rules, actions RPC, and UI controls | Unit/contract tests pass | **Pending runtime proof.** Need actual add/remove, rebuild success/failure, active DNS uncertainty, CNAME/AAAA, reboot persistence, and concurrency validation. |
| Install, upgrade, removal | Lifecycle scripts and private mirror harness | Earlier APK installed in stock guest | **Pending final lifecycle.** Fresh immutable artifact must pass direct install, LuCI Software upload flow, upgrade, removal, and cleanup. |
| P0 resources | Measurement harness and proposed budget checks | Static resource contracts pass | **Unmeasured.** No valid RSS, idle/saturation CPU, loss, or DNS p95 measurement exists. Proposed thresholds are not results. |

## Executed artifacts and limits

- Earlier diagnostic APKs are retained under `.local-validation/artifacts/`;
  they predate the current reader implementation and cannot validate it.
- The current immutable artifact is
  `.local-validation/artifacts/20261106T210245Z/package.apk`; validation was
  still running when this ledger was updated.
- The working tree is uncommitted relative to `41f1613`. No local change in
  this ledger or the implementation has been pushed, and no remote GitHub
  Actions run has been requested or performed.

## Evidence rules

1. Do not mark a vertical passed from static contracts alone when its required
   behavior is guest- or browser-observable.
2. Do not relabel a proposed resource budget as measured without the workload,
   timestamp, environment, and raw result.
3. Keep test DNS fixtures deterministic and local; `8.8.8.8` may only be a
   response emitted by the isolated fixture, never an upstream test target.
4. Update this ledger after a final installed-artifact gate passes or fails.
