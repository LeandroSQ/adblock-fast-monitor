---
applyTo: "root/www/**"
---

# LuCI JavaScript views

Adds to [AGENTS.md](../../AGENTS.md); contract: `docs/CONTRACT.md` §8–§9.

- Client-side LuCI only: `'use strict';` then `'require view'`, `form`,
  `rpc`, `uci`, `ui`, `poll`, `dom`; `view.extend({ load, render })`,
  `rpc.declare` for ubus calls, `form.Map` for settings, `ui.showModal` /
  `ui.addNotification` for dialogs and errors. Use stock LuCI CSS classes
  (`cbi-*`, `table`, `btn cbi-button-*`); no frameworks or extra CSS.
- Build DOM with `E()` and text children. Never put domains, log data, RPC
  errors or other dynamic values into `innerHTML` or HTML strings.
- Wrap every user-visible string in `_()`; after changing strings regenerate
  `po/templates/adblock-fast-monitor.pot` with LuCI's `build/i18n-scan.pl`.
- Write controls only when `L.hasViewPermission()` is true; the ACL
  (`root/usr/share/rpcd/acl.d/luci-app-adblock-fast-monitor.json`) is the
  real guard.
- Poll with `poll.add` only while `document.visibilityState` is visible;
  remove the handlers when hidden (P0).
- Staging is client-side; one `apply` per batch (§8.4).
- Read DNS activity only with core `log read` and `lines` in 16–900, never
  `0` or omitted (§8.1); never `log write` or `/ubus/subscribe`. Parsing and
  classification live in the pure `querylog.js` (§8.2–8.3).
- Keep logic that can be pure in
  `root/www/luci-static/resources/adblock-fast-monitor/model.js` and test it
  in `test/unit/` by executing the real file (`test/unit/ui-model.test.mjs`).
  Rendered behaviour is tested with Playwright in `test/browser/` against the
  guest (`npm run verify:guest -- --browser PKG.apk`).
- `npm run check:static` compiles every view as a function body, like LuCI.
