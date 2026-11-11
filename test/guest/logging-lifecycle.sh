#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# T06/T08 (docs/CONTRACT.md D1, D2, §4, §5, P1, P10) on the real guest: the
# init script runs no process in any state, and only reconciles the
# query-logging drop-ins; dnsmasq restarts exactly once when the drop-in set
# changes and never otherwise. Runs inside the guest after the APK is installed.
. "$ABFM_TESTLIB/sh/testlib.sh"

INIT=/etc/init.d/adblock-fast-monitor
SECTION=$(uci -q -X show dhcp | sed -n 's/^dhcp\.\([^.=]*\)=dnsmasq$/\1/p' | head -n1)
DROPIN=/tmp/dnsmasq.$SECTION.d/adblock-fast-monitor.conf
MARK=0

# Leave the config byte-identical for later tests (package §3 checks).
CONF_BAK=/tmp/abfm-lifecycle-config.bak
cp /etc/config/adblock-fast-monitor "$CONF_BAK"
trap 'cp "$CONF_BAK" /etc/config/adblock-fast-monitor; rm -f "$CONF_BAK"' EXIT

# Package processes: anything running a packaged file, plus any logread follower.
pkg_procs() {
	for p in /proc/[0-9]*; do
		c=$(tr '\0' ' ' <"$p/cmdline" 2>/dev/null) || continue
		case "$c" in
		*adblock-fast-monitor/logging.uc*) ;; # transient, only while a reconcile runs
		*/usr/libexec/adblock-fast-monitor/*|*monitord*|*"logread -f"*) echo "${p#/proc/} $c" ;;
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
dns_ready() { nslookup localhost 127.0.0.1 >/dev/null 2>&1; }
set_opt() { uci set "adblock-fast-monitor.config.$1=$2"; uci commit adblock-fast-monitor; }
# Waits for a reconcile to finish (procd runs triggers asynchronously).
settle() { sleep 2; abfm_wait_until 30 dns_ready; abfm_wait_until 10 sh -c '! pgrep -f "adblock-fast-monitor/[l]ogging.uc"'; }
assert_no_procs() { t_ok "$1: no package process" no_procs; t_eq "$1: procd has no instance" "" "$(instances)"; }

# Flush config changes made before this test so reload_config below only
# reports this test's own edits.
reload_config
settle
dhcp_before=$(md5sum /etc/config/dhcp)

# --- default: query_logging=0 ----------------------------------------------
t_eq "default config has query logging off" 0 "$(uci -q get adblock-fast-monitor.config.query_logging)"
t_ok "the init script is enabled at START=18 (before dnsmasq's 19)" test -x /etc/rc.d/S18adblock-fast-monitor
$INIT start
settle
assert_no_procs "query_logging=0"
t_ok "query_logging=0: no drop-in" test ! -e "$DROPIN"
t_ok "procd keeps the service for its reload trigger" sh -c "ubus call service list '{\"name\":\"adblock-fast-monitor\",\"verbose\":true}' | grep -q config.change"

# --- enable through the reload trigger (the LuCI Save & Apply path) ---------
pid0=$(dnsmasq_pid)
mark
set_opt query_logging 1
reload_config
t_ok "enable: drop-in written" abfm_wait_until 30 test -f "$DROPIN"
settle
t_eq "enable: drop-in content" "log-queries=extra log-async=25" "$(tr '\n' ' ' <"$DROPIN" | sed 's/ $//')"
t_eq "enable: drop-in mode" "644" "$(abfm_stat %a "$DROPIN")"
t_eq "enable: dnsmasq restarted exactly once" 1 "$(dnsmasq_starts)"
t_eq "enable: by the init script, once" 1 "$(our_restarts)"
t_ok "enable: dnsmasq pid changed" test "$pid0" != "$(dnsmasq_pid)"
assert_no_procs "query_logging=1"
t_ok "enable: dnsmasq logs queries to logd (log read sees them)" sh -c \
	"nslookup lifecycle.example.test 127.0.0.1 >/dev/null 2>&1; ubus call log read '{\"lines\":64,\"stream\":false,\"oneshot\":true}' | grep -q 'query\[A\] lifecycle.example.test from 127.0.0.1'"

# --- a save that does not change the drop-in set never restarts dnsmasq -----
pid1=$(dnsmasq_pid)
mark
set_opt poll_interval 7
reload_config
settle
t_eq "settings-only save: dnsmasq not restarted" 0 "$(dnsmasq_starts)"
t_eq "settings-only save: dnsmasq pid unchanged" "$pid1" "$(dnsmasq_pid)"
assert_no_procs "settings-only save"
uci -q delete adblock-fast-monitor.config.poll_interval
uci commit adblock-fast-monitor
reload_config
settle

# --- restart keeps the drop-ins --------------------------------------------
mark
$INIT restart
settle
t_eq "restart: dnsmasq not restarted" 0 "$(dnsmasq_starts)"
t_ok "restart: drop-in still present" test -f "$DROPIN"
assert_no_procs "restart"

# --- reload (what the trigger runs) with nothing changed --------------------
mark
$INIT reload
settle
t_eq "reload with the same config: dnsmasq not restarted" 0 "$(dnsmasq_starts)"

# --- stop removes the drop-ins, restarts dnsmasq once -----------------------
mark
$INIT stop
settle
t_ok "stop: drop-in removed" test ! -e "$DROPIN"
t_eq "stop: dnsmasq restarted once" 1 "$(dnsmasq_starts)"
assert_no_procs "stopped"
mark
$INIT start
settle
t_ok "start again: drop-in back" test -f "$DROPIN"
t_eq "start again: dnsmasq restarted once" 1 "$(dnsmasq_starts)"

# --- dnsmasq_instance naming a non-existent instance -> no drop-in ----------
mark
uci -q delete adblock-fast-monitor.config.dnsmasq_instance
uci add_list adblock-fast-monitor.config.dnsmasq_instance=nonexistent
uci commit adblock-fast-monitor
reload_config
t_ok "instance filter: drop-in removed" abfm_wait_until 20 test ! -e "$DROPIN"
settle
uci delete adblock-fast-monitor.config.dnsmasq_instance
uci add_list adblock-fast-monitor.config.dnsmasq_instance='*'
uci commit adblock-fast-monitor
reload_config
t_ok "instance filter back to *: drop-in back" abfm_wait_until 20 test -f "$DROPIN"
settle
t_eq "two set changes: two dnsmasq restarts" 2 "$(dnsmasq_starts)"

t_eq "/etc/config/dhcp is byte-identical" "$dhcp_before" "$(md5sum /etc/config/dhcp)"

# --- an instance already logging through dhcp logqueries gets no drop-in ----
cp /etc/config/dhcp /tmp/abfm-lifecycle-dhcp.bak
uci set dhcp.@dnsmasq[0].logqueries=1
uci commit dhcp
mark
$INIT reload
settle
t_ok "dhcp logqueries=1: no drop-in of ours" test ! -e "$DROPIN"
cp /tmp/abfm-lifecycle-dhcp.bak /etc/config/dhcp
rm -f /tmp/abfm-lifecycle-dhcp.bak
$INIT reload
settle
t_ok "dhcp logqueries removed: drop-in back" test -f "$DROPIN"

# --- logging.uc status ------------------------------------------------------
st=$(/usr/libexec/adblock-fast-monitor/logging.uc status)
t_eq "logging.uc status: section" "$SECTION" "$(printf '%s' "$st" | jsonfilter -e '@.instances[0].section')"
t_eq "logging.uc status: dropin" true "$(printf '%s' "$st" | jsonfilter -e '@.instances[0].dropin')"
t_eq "logging.uc status: running" true "$(printf '%s' "$st" | jsonfilter -e '@.instances[0].running')"

# --- disable through the reload trigger -------------------------------------
mark
set_opt query_logging 0
reload_config
t_ok "disable: drop-in removed" abfm_wait_until 20 test ! -e "$DROPIN"
settle
t_eq "disable: dnsmasq restarted once" 1 "$(dnsmasq_starts)"
assert_no_procs "disabled again"
t_done
