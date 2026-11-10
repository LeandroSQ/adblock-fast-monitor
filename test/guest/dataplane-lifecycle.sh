#!/bin/sh
# T06, T07, T08 (docs/CONTRACT.md D1, D2, §4.1, §5, P1, P10) on the real
# guest: process inventory, respawn, orphans, query-logging drop-ins and
# dnsmasq restarts. Runs inside the guest after the APK is installed.
. "$ABFM_TESTLIB/sh/testlib.sh"

INIT=/etc/init.d/adblock-fast-monitor
OBJ=adblock-fast-monitor
SECTION=$(uci -q -X show dhcp | sed -n 's/^dhcp\.\([^.=]*\)=dnsmasq$/\1/p' | head -n1)
DROPIN=/tmp/dnsmasq.$SECTION.d/adblock-fast-monitor.conf
MARK=0

monitord_pids() { pgrep -f '^/usr/bin/ucode /usr/libexec/adblock-fast-monitor/monitord.uc' | sort; }
logread_pids() { pgrep -f '^/sbin/logread -f -e \^dnsmasq' | sort; }
count() { [ -z "$1" ] && echo 0 || printf '%s\n' "$1" | wc -l | tr -d ' '; }
object_present() { ubus list "$OBJ" >/dev/null 2>&1; }
service_pid() { ubus call service list "{\"name\":\"$OBJ\"}" 2>/dev/null | jsonfilter -e '@[*].instances.instance1.pid'; }
service_exit() { ubus call service list "{\"name\":\"$OBJ\"}" 2>/dev/null | jsonfilter -e '@[*].instances.instance1.exit_code'; }
dnsmasq_pid() { ubus call service list '{"name":"dnsmasq"}' 2>/dev/null | jsonfilter -e '@.dnsmasq.instances[*].pid' | head -n1; }
running_one() { [ "$(count "$(monitord_pids)")" = 1 ] && [ "$(count "$(logread_pids)")" = 1 ] && object_present; }
none_running() { [ -z "$(monitord_pids)" ] && [ -z "$(logread_pids)" ] && ! object_present; }
mark() { MARK=$((MARK + 1)); logger -t abfm-test "mark-$$-$MARK"; }
since_mark() { logread | sed -n "/abfm-test: mark-$$-$MARK\$/,\$p"; }
dnsmasq_starts() { since_mark | grep -c 'dnsmasq\[[0-9]*\]: started, version'; }
monitor_restarts() { since_mark | grep -c 'adblock-fast-monitor: query-logging drop-ins changed; restarting dnsmasq'; }
# Settles: dnsmasq answers and no restart is in flight.
dns_ready() { nslookup localhost 127.0.0.1 >/dev/null 2>&1; }
set_opt() { uci set "adblock-fast-monitor.config.$1=$2"; uci commit adblock-fast-monitor; }

# Flush config changes made before this test so reload_config below only
# reports this test's own edits.
reload_config
sleep 3
abfm_wait_until 30 dns_ready
dhcp_before=$(md5sum /etc/config/dhcp)

# --- T06: disabled by default: nothing runs --------------------------------
t_eq "default config is disabled" 0 "$(uci -q get adblock-fast-monitor.config.enabled)"
$INIT start
t_ok "enabled=0: no daemon, no logread, no object" none_running
t_ok "enabled=0: no drop-in" test ! -e "$DROPIN"
t_eq "enabled=0: procd has no instance" "" "$(service_pid)"

# --- T06/T08: enable through the reload trigger (the LuCI path) -------------
abfm_wait_until 30 dns_ready
pid0=$(dnsmasq_pid)
mark
set_opt enabled 1
reload_config
t_ok "enable: exactly one daemon, one logread and the object" abfm_wait_until 30 running_one
t_ok "enable: drop-in written" test -f "$DROPIN"
t_eq "enable: drop-in content" "log-queries=extra" "$(cat "$DROPIN")"
t_eq "enable: drop-in mode" "644" "$(abfm_stat %a "$DROPIN")"
abfm_wait_until 30 dns_ready
t_eq "enable: dnsmasq restarted exactly once" 1 "$(dnsmasq_starts)"
t_eq "enable: by the monitor, once" 1 "$(monitor_restarts)"
t_ok "enable: dnsmasq pid changed" test "$pid0" != "$(dnsmasq_pid)"
d=$(monitord_pids)
t_eq "logread is the daemon's child" "$d" "$(cat /proc/"$(logread_pids)"/stat | cut -d' ' -f4)"
t_eq "daemon is exec'd by procd (no shell parent)" 1 "$(cut -d' ' -f4 /proc/"$d"/stat)"
t_eq "status reports the daemon pid" "$d" "$(ubus call $OBJ status | jsonfilter -e '@.daemon.pid')"
t_eq "status: running" running "$(ubus call $OBJ status | jsonfilter -e '@.state')"

# --- T08: a settings-only save restarts the daemon, not dnsmasq ------------
pid1=$(dnsmasq_pid)
mark
set_opt recent_size 100
reload_config
t_ok "settings save: daemon restarted" abfm_wait_until 30 sh -c "[ -n \"\$(pgrep -f '^/usr/bin/ucode /usr/libexec/adblock-fast-monitor/monitord.uc')\" ] && [ \"\$(pgrep -f '^/usr/bin/ucode /usr/libexec/adblock-fast-monitor/monitord.uc')\" != '$d' ]"
t_ok "settings save: one daemon, one logread" abfm_wait_until 15 running_one
t_eq "settings save: new limit applied" 100 "$(ubus call $OBJ status | jsonfilter -e '@.limits.recent_size')"
t_eq "settings save: dnsmasq not restarted" 0 "$(dnsmasq_starts)"
t_eq "settings save: dnsmasq pid unchanged" "$pid1" "$(dnsmasq_pid)"
t_eq "old daemon's logread is gone" 1 "$(count "$(logread_pids)")"

# --- T07: killing logread makes the daemon exit != 0; procd respawns -------
d=$(monitord_pids)
l=$(logread_pids)
mark
kill "$l"
t_ok "daemon exits after logread dies" abfm_wait_until 10 sh -c "! kill -0 $d 2>/dev/null"
t_eq "exit code is non-zero (1)" 1 "$(service_exit)"
t_ok "procd respawns the daemon" abfm_wait_until 20 running_one
t_ok "respawned daemon is new" test "$d" != "$(monitord_pids)"
t_match "daemon logged why it stopped" "stopping: logread (output closed|exited)" "$(since_mark | grep monitord)"
t_eq "respawn did not restart dnsmasq" 0 "$(dnsmasq_starts)"

# --- T07: restart leaves no orphan and keeps the drop-ins ------------------
d=$(monitord_pids)
l=$(logread_pids)
mark
$INIT restart
t_ok "restart: exactly one daemon and one logread" abfm_wait_until 20 running_one
t_ok "restart: old logread gone" sh -c "! kill -0 $l 2>/dev/null"
t_ok "restart: old daemon gone" sh -c "! kill -0 $d 2>/dev/null"
t_eq "restart: dnsmasq not restarted" 0 "$(dnsmasq_starts)"
t_ok "restart: drop-in still present" test -f "$DROPIN"

# --- T07/T08: stop removes everything, restarts dnsmasq once ---------------
abfm_wait_until 30 dns_ready
l=$(logread_pids)
mark
$INIT stop
t_ok "stop: no daemon, no logread, no object" abfm_wait_until 15 none_running
t_ok "stop: old logread not orphaned" sh -c "! kill -0 $l 2>/dev/null"
t_ok "stop: drop-in removed" test ! -e "$DROPIN"
abfm_wait_until 30 dns_ready
t_eq "stop: dnsmasq restarted once" 1 "$(dnsmasq_starts)"

# --- manage_logging=0: the daemon runs, no drop-in, dnsmasq untouched ------
set_opt manage_logging 0
mark
$INIT start
t_ok "manage_logging=0: daemon runs" abfm_wait_until 20 running_one
t_ok "manage_logging=0: no drop-in" test ! -e "$DROPIN"
t_eq "manage_logging=0: dnsmasq not restarted" 0 "$(dnsmasq_starts)"
set_opt manage_logging 1
mark
reload_config
t_ok "manage_logging=1 again: drop-in written" abfm_wait_until 20 test -f "$DROPIN"
abfm_wait_until 30 dns_ready
t_eq "drop-in set changed: dnsmasq restarted once" 1 "$(dnsmasq_starts)"

# --- dnsmasq_instance naming a non-existent instance -> no drop-in ----------
mark
uci add_list adblock-fast-monitor.config.dnsmasq_instance=nonexistent
uci commit adblock-fast-monitor
reload_config
t_ok "instance filter: drop-in removed" abfm_wait_until 20 test ! -e "$DROPIN"
uci delete adblock-fast-monitor.config.dnsmasq_instance
uci commit adblock-fast-monitor
reload_config
t_ok "instance filter cleared: drop-in back" abfm_wait_until 20 test -f "$DROPIN"
abfm_wait_until 30 dns_ready
t_eq "two set changes: two dnsmasq restarts" 2 "$(dnsmasq_starts)"

# --- logging.uc status ------------------------------------------------------
st=$(/usr/libexec/adblock-fast-monitor/logging.uc status)
t_eq "logging.uc status: section" "$SECTION" "$(printf '%s' "$st" | jsonfilter -e '@.instances[0].section')"
t_eq "logging.uc status: dropin" true "$(printf '%s' "$st" | jsonfilter -e '@.instances[0].dropin')"
t_eq "logging.uc status: running" true "$(printf '%s' "$st" | jsonfilter -e '@.instances[0].running')"

# --- T06: disable through the reload trigger -------------------------------
abfm_wait_until 30 dns_ready
mark
set_opt enabled 0
reload_config
t_ok "disable: no daemon, no logread, no object" abfm_wait_until 20 none_running
t_ok "disable: drop-in removed" test ! -e "$DROPIN"
abfm_wait_until 30 dns_ready
t_eq "disable: dnsmasq restarted once" 1 "$(dnsmasq_starts)"
t_eq "disable: procd has no instance" "" "$(service_pid)"

uci -q delete adblock-fast-monitor.config.recent_size
uci commit adblock-fast-monitor
t_eq "/etc/config/dhcp is byte-identical" "$dhcp_before" "$(md5sum /etc/config/dhcp)"
t_done
