#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# docs/CONTRACT.md §4, §11 (P10 exception), §14: a logd restart must not
# silence dnsmasq's query log. procd jails dnsmasq with /dev/log bind-mounted;
# a restarted logd creates a new socket and the jailed dnsmasq keeps writing
# to the dead one (recorded below). With query_logging=1 the init script's
# instance.update trigger restarts dnsmasq once; with query_logging=0 it does
# nothing. Both paths that restart logd are covered: `/etc/init.d/log restart`
# and a System -> Logging save (uci commit system + reload_config).
. "$ABFM_TESTLIB/sh/testlib.sh"

INIT=/etc/init.d/adblock-fast-monitor
MARK=0
CONF_BAK=/tmp/abfm-logd-restart-config.bak
SYS_BAK=/tmp/abfm-logd-restart-system.bak
cp /etc/config/adblock-fast-monitor "$CONF_BAK"
cp /etc/config/system "$SYS_BAK"
restore() {
	cp "$CONF_BAK" /etc/config/adblock-fast-monitor
	cp "$SYS_BAK" /etc/config/system
	rm -f "$CONF_BAK" "$SYS_BAK"
	old=$(host_log)
	reload_config
	# the restored log_size restarts logd (1 s trigger delay): let it, so the
	# dnsmasq restart below leaves the next test a fresh /dev/log
	abfm_wait_until 20 sh -c "[ \"\$(ls -i /dev/log 2>/dev/null | awk '{print \$1}')\" != '$old' ]"
	abfm_wait_until 15 ubus list log
	$INIT restart
	/etc/init.d/dnsmasq restart
}
trap restore EXIT

mark() { MARK=$((MARK + 1)); logger -t abfm-test "mark-$$-$MARK"; }
since_mark() { logread | sed -n "/abfm-test: mark-$$-$MARK\$/,\$p"; }
dnsmasq_starts() { since_mark | grep -c 'dnsmasq\[[0-9]*\]: started, version'; }
# A restarted logd starts with an empty ring, so after one these count
# everything logged since.
starts_all() { logread | grep -c 'dnsmasq\[[0-9]*\]: started, version'; }
dns_ready() { nslookup localhost 127.0.0.1 >/dev/null 2>&1; }
# logged NAME: query once, then 0 when `log read` shows its query line
N=0
logged() {
	N=$((N + 1))
	nslookup "$1-$N.example.test" 127.0.0.1 >/dev/null 2>&1
	ubus call log read '{"lines":200,"stream":false,"oneshot":true}' | grep -q "query\[A\] $1-[0-9]*\.example\.test from 127\.0\.0\.1"
}
# The jailed dnsmasq: procd starts ujail (comm "dnsmasq" too, host root),
# which forks the real dnsmasq inside the jail.
jailed_pid() {
	for p in /proc/[0-9]*; do
		[ "$(cat "$p/comm" 2>/dev/null)" = dnsmasq ] || continue
		pp=$(cut -d' ' -f4 "$p/stat")
		[ "$(cat "/proc/$pp/comm" 2>/dev/null)" = dnsmasq ] && echo "${p#/proc/}"
	done | head -n1
}
jail_log() { ls -i "/proc/$(jailed_pid)/root/dev/log" 2>/dev/null | awk '{print $1}'; }
host_log() { ls -i /dev/log | awk '{print $1}'; }
settle() { sleep 5; abfm_wait_until 30 dns_ready; abfm_wait_until 15 sh -c '! pgrep -f "adblock-fast-monitor/[l]ogging.uc"'; }

reload_config
uci set adblock-fast-monitor.config.query_logging=1
uci commit adblock-fast-monitor
reload_config
abfm_wait_until 30 sh -c 'ls /tmp/dnsmasq*.d/adblock-fast-monitor.conf' >/dev/null
settle
t_ok "query_logging=1: queries reach log read" abfm_wait_until 20 logged before
t_ok "the trigger is registered while query logging is on" sh -c \
	"ubus call service list '{\"name\":\"adblock-fast-monitor\",\"verbose\":true}' | grep -q instance.update"
t_ok "dnsmasq runs jailed" test -n "$(jailed_pid)"
t_eq "dnsmasq's jailed /dev/log is logd's socket" "$(host_log)" "$(jail_log)"

# --- /etc/init.d/log restart ------------------------------------------------
old=$(host_log)
/etc/init.d/log restart
t_ok "logd is back on ubus with a new socket" abfm_wait_until 15 sh -c "ubus list log >/dev/null && [ \"\$(ls -i /dev/log | awk '{print \$1}')\" != '$old' ]"
settle
t_eq "log restart: dnsmasq restarted exactly once (P10 exception)" 1 "$(starts_all)"
t_match "log restart: the restart says why" 'lost /dev/log \(logd restarted\); restarting dnsmasq' \
	"$(logread | grep 'adblock-fast-monitor:')"
t_ok "log restart: queries reach log read again" abfm_wait_until 20 logged after-restart
t_eq "log restart: dnsmasq's jailed /dev/log is the new socket" "$(host_log)" "$(jail_log)"

# --- LuCI System -> Logging save: uci commit system + reload_config ---------
old=$(host_log)
uci set system.@system[0].log_size=96
uci commit system
reload_config
t_ok "System save: logd restarts with a new socket" abfm_wait_until 20 sh -c "[ \"\$(ls -i /dev/log 2>/dev/null | awk '{print \$1}')\" != '$old' ] && ubus list log >/dev/null"
settle
# dnsmasq also reloads on a `system` change (SIGHUP, no new jail), so who
# restarts it when is a race; the outcome is what matters.
t_diag "System save: $(logread | grep -c 'restarting dnsmasq') restart(s) by the package; $(logread | grep 'adblock-fast-monitor:' | tr '\n' ';')"
t_ok "System save: at most one dnsmasq restart by the package" test "$(logread | grep -c 'lost /dev/log')" -le 1
t_ok "System save: queries reach log read again" abfm_wait_until 20 logged after-save
t_eq "System save: dnsmasq's jailed /dev/log is the new socket" "$(host_log)" "$(jail_log)"

# --- nothing else triggers a dnsmasq restart --------------------------------
mark
/etc/init.d/uhttpd restart
settle
t_eq "an unrelated service restart: no dnsmasq restart" 0 "$(dnsmasq_starts)"

# --- query_logging=0: no trigger, no restart --------------------------------
uci set adblock-fast-monitor.config.query_logging=0
uci commit adblock-fast-monitor
reload_config
abfm_wait_until 30 sh -c '! ls /tmp/dnsmasq*.d/adblock-fast-monitor.conf' 2>/dev/null
settle
t_not "query_logging=0: the trigger is not registered" sh -c \
	"ubus call service list '{\"name\":\"adblock-fast-monitor\",\"verbose\":true}' | grep -q instance.update"
/etc/init.d/log restart
abfm_wait_until 15 ubus list log
settle
t_eq "query_logging=0: log restart restarts nothing" 0 "$(starts_all)"
t_not "query_logging=0: the jailed dnsmasq keeps the dead socket (the upstream behaviour)" \
	test "$(host_log)" = "$(jail_log)"
t_done
