# Feature-to-test traceability

| Runtime capability expected under `root/` | Required evidence | Harness / CI gate | Status before runtime exists |
| --- | --- | --- | --- |
| Blocklist parsing and domain normalization | Production unit tests with malformed, allowlisted, and IDN cases | `npm run test:unit`; `root/test/unit/` | Adapter absent |
| DNS policy applied by real dnsmasq | QEMU loads a host-served deterministic list, verifies an actual forwarded DNS response, and calls monitor/action ubus methods | `npm run test:qemu`; `scripts/integration/runtime-dns-lifecycle.sh` | Mandatory GitHub-hosted QEMU gate |
| adblock-fast refresh/reload result | Contract test for exit status, structured status, and rollback | `npm run test:contract`; `root/test/contract/` | Adapter absent |
| RPC backend request/error contracts | Schema-backed contract tests, including unauthorized and invalid input | `npm run test:contract`; `root/test/contract/` | Adapter absent |
| LuCI/browser workflows | Playwright coverage for the real LuCI landmark, health state, filters, and timeline without rendering destructive purge control | `npm run test:browser:required`; `test/browser/` | Requires a real LuCI/QEMU URL |
| OpenWrt package install and service lifecycle | Verified SDK APK metadata/dependencies, direct install, UCI reload, uninstall, real LuCI Software upload/install, and final removal | `npm run test:qemu`; `scripts/integration/package-lifecycle.sh` | Mandatory GitHub-hosted QEMU gate |
| Resource limits and regression budget | Isolated QEMU measured P0 result with collector process-tree CPU/RSS and 20-query DNS p95/throughput | `npm run test:qemu`; `scripts/integration/measure-performance.mjs` | Host only: proposed baseline skip |

## Rules for runtime contributors

1. Add the production tests and adapters listed above with the feature they
   cover; do not remove a gate merely because an environment is unavailable.
2. Keep test blocklists local and deterministic. Their contents must be small,
   versioned, and referenced by fixture name—not downloaded at test time.
3. Make adapter setup idempotent and emit diagnostics before failing.
4. Update this matrix when introducing a user-visible capability or a new
   external interface.
5. Never relabel a proposed baseline as measured. A measured P0 result requires
   an isolated OpenWrt adapter, timestamp, environment description, and the
   deterministic local list workload.
