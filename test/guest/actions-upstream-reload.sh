#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Why Apply must run `adblock-fast dl` (docs/CONTRACT.md §6.6, §14.2): a list
# change committed to adblock-fast's UCI and picked up through the config
# trigger (reload_config), `reload` or `restart` does NOT rebuild the block
# list in adblock-fast 1.2.4-r4 — start() skips the download when the last
# status was statusSuccess and the output file exists, then stores the new
# config as current. Recorded on the real guest; T15/T17 cover the `dl` job.
. "$ABFM_TESTLIB/sh/testlib.sh"
. "$ABFM_FIXTURES/actions/guest-lib.sh"

OUT=/var/run/adblock-fast/dnsmasq.servers
af_idle() { ! pgrep -f /lib/adblock-fast/cli.uc >/dev/null && [ "$(af_status)" = statusSuccess ]; }

t_ok "real adblock-fast builds the fixture list (dnsmasq.servers)" actions_setup dnsmasq.servers
t_ok "the fixture name is in the output file" grep -qx 'server=/ads.example.com/' "$OUT"
t_eq "and blocked by dnsmasq" NXDOMAIN "$(dns_a ads.example.com)"

uci add_list adblock-fast.config.allowed_domain=ads.example.com
uci commit adblock-fast
m=$(log_mark)
reload_config
t_ok "config.change trigger: adblock-fast settles" abfm_wait_until 120 af_idle
t_ok "reload_config: the output file still blocks the allowed name" grep -qx 'server=/ads.example.com/' "$OUT"
t_eq "reload_config: still NXDOMAIN" NXDOMAIN "$(dns_a ads.example.com)"

$AF reload >/dev/null 2>&1
t_ok "adblock-fast reload: settles" abfm_wait_until 120 af_idle
t_ok "adblock-fast reload: the output file still blocks the allowed name" grep -qx 'server=/ads.example.com/' "$OUT"
t_eq "adblock-fast reload: still NXDOMAIN" NXDOMAIN "$(dns_a ads.example.com)"

$AF restart >/dev/null 2>&1
t_ok "adblock-fast restart: settles" abfm_wait_until 120 af_idle
t_ok "adblock-fast restart: the output file still blocks the allowed name" grep -qx 'server=/ads.example.com/' "$OUT"
t_diag "adblock-fast runs since the commit: $(af_runs "$m"); downloads: $(log_since "$m" | grep -c 'Downloading\|download' )"

$AF dl >/dev/null 2>&1
t_ok "adblock-fast dl: settles" abfm_wait_until 120 af_idle
t_not "adblock-fast dl: the allowed name is gone from the output file" grep -qx 'server=/ads.example.com/' "$OUT"
t_eq "adblock-fast dl: the name resolves" "$UPSTREAM_A" "$(dns_a ads.example.com)"

actions_teardown
t_done
