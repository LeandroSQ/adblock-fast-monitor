#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# T06/T08 (docs/CONTRACT.md D1, D2, §4, §5, P1, P10) on the real guest: the
# init script runs no process in any state, and only reconciles the
# query-logging drop-ins; dnsmasq restarts exactly once when the drop-in set
# changes and never otherwise. Every "no restart" check first damages the
# drop-in, so the rewrite proves the reconcile ran. Also the hand-over with
# dhcp `logqueries` (luci-app-adblock-fast's toggle) through the
# instance.update trigger alone. Runs inside the guest after the APK is
# installed.
# shellcheck source=test/lib/sh/testlib.sh
. "$ABFM_TESTLIB/sh/testlib.sh"

INIT=/etc/init.d/adblock-fast-monitor
SECTION=$(uci -q -X show dhcp | sed -n 's/^dhcp\.\([^.=]*\)=dnsmasq$/\1/p' | head -n1)
DROPIN=/tmp/dnsmasq.$SECTION.d/adblock-fast-monitor.conf
CONTENT='log-queries=extra log-async=25'
LOGGING_LOCK=/var/lock/adblock-fast-monitor.logging.lock
MARK=0

# Leave the configs byte-identical for later tests.
CONF_BAK=/tmp/abfm-lifecycle-config.bak
DHCP_BAK=/tmp/abfm-lifecycle-dhcp.bak
cp /etc/config/adblock-fast-monitor "$CONF_BAK"
cp /etc/config/dhcp "$DHCP_BAK"
trap 'cp "$CONF_BAK" /etc/config/adblock-fast-monitor; cp "$DHCP_BAK" /etc/config/dhcp; rm -f "$CONF_BAK" "$DHCP_BAK"' EXIT

# Package processes: anything running a packaged executable. A logging.uc
# reconcile is transient (it runs only while it reconciles, §1).
pkg_procs() {
	for p in /proc/[0-9]*; do
		c=$(tr '\0' ' ' <"$p/cmdline" 2>/dev/null) || continue
		case "$c" in
		*adblock-fast-monitor/logging.uc*) ;;
		*/usr/libexec/adblock-fast-monitor/*) echo "${p#/proc/} $c" ;;
		esac
	done
}
no_procs() { [ -z "$(pkg_procs)" ]; }
instances() { ubus call service list '{"name":"adblock-fast-monitor"}' 2>/dev/null | jsonfilter -e '@["adblock-fast-monitor"].instances' 2>/dev/null; }
dnsmasq_pid() { ubus call service list '{"name":"dnsmasq"}' 2>/dev/null | jsonfilter -e '@.dnsmasq.instances[*].pid' | head -n1; }
mark() { MARK=$((MARK + 1)); logger -t abfm-test "mark-$$-$MARK"; }
since_mark() { logread | sed -n "/abfm-test: mark-$$-$MARK\$/,\$p"; }
dnsmasq_starts() { since_mark | grep -c 'dnsmasq\[[0-9]*\]: started, version'; }
our_restarts() { since_mark | grep -c 'adblock-fast-monitor: query-logging drop-ins changed; restarting dnsmasq'; }
starts_at_least() { [ "$(dnsmasq_starts)" -ge "$1" ]; }
dns_ready() { nslookup localhost 127.0.0.1 >/dev/null 2>&1; }
dropin_ok() { [ "$(tr '\n' ' ' <"$DROPIN" 2>/dev/null | sed 's/ $//')" = "$CONTENT" ]; }
damage() { echo 'garbage' >"$DROPIN"; }
set_opt() { uci set "adblock-fast-monitor.config.$1=$2"; uci commit adblock-fast-monitor; }
# A running reconcile holds the logging lock; once it is free and dnsmasq
# answers, every restart it made has logged its "started" line.
reconciled() { flock "$LOGGING_LOCK" true && abfm_wait_until 30 dns_ready; }
assert_no_procs() { t_ok "$1: no package process" no_procs; t_eq "$1: procd has no instance" "" "$(instances)"; }

reload_config
dhcp_before=$(md5sum /etc/config/dhcp)

# --- default: query_logging=0 ----------------------------------------------
t_eq "default config has query logging off" 0 "$(uci -q get adblock-fast-monitor.config.query_logging)"
t_ok "the init script is enabled at START=18 (before dnsmasq's 19)" test -x /etc/rc.d/S18adblock-fast-monitor
$INIT start
reconciled
assert_no_procs "query_logging=0"
t_ok "query_logging=0: no drop-in" test ! -e "$DROPIN"
t_ok "procd keeps the service for its reload trigger" sh -c "ubus call service list '{\"name\":\"adblock-fast-monitor\",\"verbose\":true}' | grep -q config.change"
t_not "query_logging=0: no instance.update trigger" sh -c "ubus call service list '{\"name\":\"adblock-fast-monitor\",\"verbose\":true}' | grep -q instance.update"

# --- enable through the reload trigger (the LuCI Save & Apply path) ---------
pid0=$(dnsmasq_pid)
mark
set_opt query_logging 1
reload_config
t_ok "enable: drop-in written" abfm_wait_until 30 dropin_ok
reconciled
t_ok "enable: dnsmasq restarted" abfm_wait_until 20 starts_at_least 1
t_eq "enable: dnsmasq restarted exactly once" 1 "$(dnsmasq_starts)"
t_eq "enable: by the init script, once" 1 "$(our_restarts)"
t_eq "enable: drop-in mode" "644" "$(abfm_stat %a "$DROPIN")"
t_ok "enable: dnsmasq pid changed" test "$pid0" != "$(dnsmasq_pid)"
assert_no_procs "query_logging=1"
# the instance.update trigger as procd holds it: [event, [[action...]], delay]
trig=$(ubus call service list '{"name":"adblock-fast-monitor","verbose":true}' |
	ucode -e 'for (let t in json(require("fs").stdin.read("all"))["adblock-fast-monitor"].triggers) if (t[0] == "instance.update") print(join(" ", t[1][0]), " ", t[2], "\n");')
t_eq "enable: the instance.update trigger runs logging.uc directly, debounced 3 s" \
	"run_script /usr/libexec/adblock-fast-monitor/logging.uc reconcile 3000" "$trig"
t_ok "enable: dnsmasq logs queries to logd (log read sees them)" sh -c \
	"nslookup lifecycle.example.test 127.0.0.1 >/dev/null 2>&1; ubus call log read '{\"lines\":64,\"stream\":false,\"oneshot\":true}' | grep -q 'query\[A\] lifecycle.example.test from 127.0.0.1'"

# --- a save that does not change the drop-in set never restarts dnsmasq -----
# The drop-in is damaged first: its rewrite proves the reconcile ran.
pid1=$(dnsmasq_pid)
damage
mark
set_opt query_logging on
reload_config
t_ok "settings-only save: the reconcile ran (damaged drop-in rewritten)" abfm_wait_until 30 dropin_ok
reconciled
t_eq "settings-only save: dnsmasq not restarted" 0 "$(dnsmasq_starts)"
t_eq "settings-only save: dnsmasq pid unchanged" "$pid1" "$(dnsmasq_pid)"
assert_no_procs "settings-only save"
set_opt query_logging 1
reload_config
t_ok "settings-only save back to 1: reconciled" abfm_wait_until 30 dropin_ok

# --- restart keeps the drop-ins --------------------------------------------
damage
mark
$INIT restart
reconciled
t_ok "restart: drop-in rewritten" dropin_ok
t_eq "restart: dnsmasq not restarted" 0 "$(dnsmasq_starts)"
assert_no_procs "restart"

# --- reload (what the config trigger runs) with nothing changed -------------
damage
mark
$INIT reload
reconciled
t_ok "reload with the same config: drop-in rewritten" dropin_ok
t_eq "reload with the same config: dnsmasq not restarted" 0 "$(dnsmasq_starts)"

# --- stop removes the drop-ins, restarts dnsmasq once -----------------------
mark
$INIT stop
reconciled
t_ok "stop: drop-in removed" test ! -e "$DROPIN"
t_ok "stop: dnsmasq restarted" abfm_wait_until 20 starts_at_least 1
t_eq "stop: dnsmasq restarted once" 1 "$(dnsmasq_starts)"
assert_no_procs "stopped"
mark
$INIT start
reconciled
t_ok "start again: drop-in back" dropin_ok
t_ok "start again: dnsmasq restarted" abfm_wait_until 20 starts_at_least 1
t_eq "start again: dnsmasq restarted once" 1 "$(dnsmasq_starts)"

t_eq "/etc/config/dhcp is byte-identical" "$dhcp_before" "$(md5sum /etc/config/dhcp)"

# --- hand-over with dhcp logqueries through the trigger alone --------------
# luci-app-adblock-fast's logging toggle sets dhcp logqueries and restarts
# dnsmasq; procd's instance.update makes our reconcile drop our drop-in (one
# more restart), and bring it back when logqueries is cleared (§4, §14.14).
mark
uci set dhcp.@dnsmasq[0].logqueries=1
uci commit dhcp
/etc/init.d/dnsmasq restart
t_ok "dhcp logqueries=1: our drop-in is removed by the trigger" abfm_wait_until 30 test ! -e "$DROPIN"
reconciled
t_ok "dhcp logqueries=1: at most 2 dnsmasq restarts (theirs + ours)" test "$(dnsmasq_starts)" -le 2
t_ok "dhcp logqueries=1: queries still reach log read" sh -c \
	"nslookup handover1.example.test 127.0.0.1 >/dev/null 2>&1; ubus call log read '{\"lines\":64,\"stream\":false,\"oneshot\":true}' | grep -q 'query\[A\] handover1.example.test from 127.0.0.1'"
t_eq "dhcp logqueries=1: info reports uci_logqueries" true \
	"$(ubus call luci.adblock-fast-monitor info | jsonfilter -e '@.dnsmasq.instances[0].uci_logqueries')"
mark
cp "$DHCP_BAK" /etc/config/dhcp
/etc/init.d/dnsmasq restart
t_ok "dhcp logqueries removed: our drop-in is back through the trigger" abfm_wait_until 30 dropin_ok
reconciled
t_ok "dhcp logqueries removed: at most 2 dnsmasq restarts" test "$(dnsmasq_starts)" -le 2
t_ok "dhcp logqueries removed: queries reach log read" sh -c \
	"nslookup handover2.example.test 127.0.0.1 >/dev/null 2>&1; ubus call log read '{\"lines\":64,\"stream\":false,\"oneshot\":true}' | grep -q 'query\[A\] handover2.example.test from 127.0.0.1'"

# --- logging.uc status ------------------------------------------------------
st=$(/usr/libexec/adblock-fast-monitor/logging.uc status)
t_eq "logging.uc status: section" "$SECTION" "$(printf '%s' "$st" | jsonfilter -e '@.instances[0].section')"
t_eq "logging.uc status: dropin" true "$(printf '%s' "$st" | jsonfilter -e '@.instances[0].dropin')"
t_eq "logging.uc status: running" true "$(printf '%s' "$st" | jsonfilter -e '@.instances[0].running')"
/usr/libexec/adblock-fast-monitor/logging.uc enable >/dev/null 2>&1
t_eq "logging.uc: an unknown mode is a usage error" 2 "$?"

# --- disable through the reload trigger -------------------------------------
mark
set_opt query_logging 0
reload_config
t_ok "disable: drop-in removed" abfm_wait_until 20 test ! -e "$DROPIN"
reconciled
t_ok "disable: dnsmasq restarted" abfm_wait_until 20 starts_at_least 1
t_eq "disable: dnsmasq restarted once" 1 "$(dnsmasq_starts)"
t_not "disable: the instance.update trigger is gone" sh -c "ubus call service list '{\"name\":\"adblock-fast-monitor\",\"verbose\":true}' | grep -q instance.update"
assert_no_procs "disabled again"
cp "$CONF_BAK" /etc/config/adblock-fast-monitor
reload_config
t_done
