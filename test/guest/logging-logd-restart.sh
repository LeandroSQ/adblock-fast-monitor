#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# docs/CONTRACT.md §4, §11 (P10 exception), §14: a logd restart must not
# silence dnsmasq's query log. procd jails dnsmasq with /dev/log bind-mounted;
# a restarted logd creates a new socket and the jailed dnsmasq keeps writing
# to the dead one (recorded below). With query_logging=1 the init script's
# instance.update trigger restarts dnsmasq once; with query_logging=0 it does
# nothing. Both paths that restart logd are covered: `/etc/init.d/log restart`
# and a System -> Logging save (uci commit system + reload_config). T07: a
# foreign jailed dnsmasq (not the procd service) that stays stale forever
# never makes the trigger restart dnsmasq again (no restart loop). T06: one
# trigger firing costs one process.
# shellcheck source=test/lib/sh/testlib.sh
. "$ABFM_TESTLIB/sh/testlib.sh"

INIT=/etc/init.d/adblock-fast-monitor
LOGGING_LOCK=/var/lock/adblock-fast-monitor.logging.lock
FOREIGN_PID=/tmp/abfm-foreign-ujail.pid
MARK=0
CONF_BAK=/tmp/abfm-logd-restart-config.bak
SYS_BAK=/tmp/abfm-logd-restart-system.bak
cp /etc/config/adblock-fast-monitor "$CONF_BAK"
cp /etc/config/system "$SYS_BAK"
restore() {
	[ -s "$FOREIGN_PID" ] && kill "$(cat "$FOREIGN_PID")" 2>/dev/null
	rm -f "$FOREIGN_PID"
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
	abfm_wait_until 30 dns_ready
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
# The jailed dnsmasq of the procd service: its instance pid is ujail (comm
# "dnsmasq" too, host root), which forks the real dnsmasq inside the jail.
jailed_pid() {
	ip=$(ubus call service list '{"name":"dnsmasq"}' | jsonfilter -e '@.dnsmasq.instances[*].pid' | head -n1)
	for p in /proc/[0-9]*; do
		[ "$(cat "$p/comm" 2>/dev/null)" = dnsmasq ] && [ "$(cut -d' ' -f4 "$p/stat")" = "$ip" ] && echo "${p#/proc/}"
	done | head -n1
}
jail_log() { abfm_stat %i "/proc/$(jailed_pid)/root/dev/log" 2>/dev/null; }
host_log() { abfm_stat %i /dev/log; }
fresh() { [ -n "$(jail_log)" ] && [ "$(jail_log)" = "$(host_log)" ]; }
reconciled() { flock "$LOGGING_LOCK" true && abfm_wait_until 30 dns_ready; }
dropin() { for _f in /tmp/dnsmasq*.d/adblock-fast-monitor.conf; do [ -e "$_f" ] && echo "$_f" && break; done; }
dropin_ok() { [ "$(cat "$(dropin)" 2>/dev/null)" = "$(printf 'log-queries=extra\nlog-async=25')" ]; }
# trigger_ran: restart an unrelated service with the drop-in damaged; the
# trigger's reconcile rewrites it. Prints trigger-forks.uc's JSON.
trigger_ran() { ucode "$ABFM_FIXTURES/logging/trigger-forks.uc" measure "$(dropin)" 60; }
foreign_pid() {
	for p in /proc/[0-9]*; do
		[ "$(cat "$p/comm" 2>/dev/null)" = dnsmasq ] && [ "$(cut -d' ' -f4 "$p/stat")" = "$(cat "$FOREIGN_PID" 2>/dev/null)" ] && echo "${p#/proc/}"
	done | head -n1
}
foreign_log() { abfm_stat %i "/proc/$(foreign_pid)/root/dev/log" 2>/dev/null; }
foreign_up() { [ -n "$(foreign_log)" ]; }

reload_config
uci set adblock-fast-monitor.config.query_logging=1
uci commit adblock-fast-monitor
reload_config
t_ok "query_logging=1: drop-in written" abfm_wait_until 30 dropin_ok
reconciled
t_ok "query_logging=1: queries reach log read" abfm_wait_until 20 logged before
t_ok "the trigger is registered while query logging is on" sh -c \
	"ubus call service list '{\"name\":\"adblock-fast-monitor\",\"verbose\":true}' | grep -q instance.update"
t_ok "dnsmasq runs jailed" test -n "$(jailed_pid)"
t_eq "dnsmasq's jailed /dev/log is logd's socket" "$(host_log)" "$(jail_log)"

# --- /etc/init.d/log restart ------------------------------------------------
old=$(host_log)
/etc/init.d/log restart
t_ok "logd is back on ubus with a new socket" abfm_wait_until 15 sh -c "ubus list log >/dev/null && [ \"\$(ls -i /dev/log | awk '{print \$1}')\" != '$old' ]"
t_ok "log restart: the trigger restarts dnsmasq onto the new socket" abfm_wait_until 60 fresh
reconciled
t_eq "log restart: dnsmasq restarted exactly once (P10 exception)" 1 "$(starts_all)"
t_match "log restart: the restart says why" 'lost /dev/log \(logd restarted\); restarting dnsmasq' \
	"$(logread | grep 'adblock-fast-monitor:')"
t_ok "log restart: queries reach log read again" abfm_wait_until 20 logged after-restart

# --- LuCI System -> Logging save: uci commit system + reload_config ---------
old=$(host_log)
uci set system.@system[0].log_size=96
uci commit system
reload_config
t_ok "System save: logd restarts with a new socket" abfm_wait_until 20 sh -c "[ \"\$(ls -i /dev/log 2>/dev/null | awk '{print \$1}')\" != '$old' ] && ubus list log >/dev/null"
t_ok "System save: dnsmasq ends up on the new socket" abfm_wait_until 60 fresh
reconciled
# dnsmasq also reloads on a `system` change (SIGHUP, no new jail), so who
# restarts it when is a race; the outcome is what matters.
t_diag "System save: $(logread | grep -c 'restarting dnsmasq') restart(s) by the package; $(logread | grep 'adblock-fast-monitor:' | tr '\n' ';')"
t_ok "System save: at most one dnsmasq restart by the package" test "$(logread | grep -c 'lost /dev/log')" -le 1
t_ok "System save: queries reach log read again" abfm_wait_until 20 logged after-save

# --- an unrelated service restart: the trigger runs, restarts nothing -------
mark
r=$(trigger_ran)
t_eq "unrelated restart: the trigger's reconcile ran (damaged drop-in rewritten)" true "$(echo "$r" | jsonfilter -e @.rewritten)"
reconciled
t_eq "unrelated restart: no dnsmasq restart" 0 "$(dnsmasq_starts)"
forks_on=$(echo "$r" | jsonfilter -e @.forks)
window=$(echo "$r" | jsonfilter -e @.ms)

# --- T07: a foreign jailed dnsmasq that stays stale causes no restart loop --
# Not part of the procd dnsmasq service, so a restart of the service can't
# give it the new socket: the old code saw it stale forever.
(ujail -n abfm-foreign -l -r /etc/passwd -r /etc/group -- /usr/sbin/dnsmasq -k --port=5399 \
	--listen-address=127.0.0.1 --bind-interfaces --conf-file=/dev/null --no-resolv --no-hosts \
	--pid-file= --user=root </dev/null >/dev/null 2>&1 & echo $! >"$FOREIGN_PID")
t_ok "a foreign jailed dnsmasq runs" abfm_wait_until 15 foreign_up
old=$(host_log)
/etc/init.d/log restart
t_ok "foreign: logd back with a new socket" abfm_wait_until 15 sh -c "ubus list log >/dev/null && [ \"\$(ls -i /dev/log | awk '{print \$1}')\" != '$old' ]"
t_ok "foreign: the service dnsmasq is restarted onto the new socket" abfm_wait_until 60 fresh
reconciled
t_eq "foreign: exactly one dnsmasq restart" 1 "$(starts_all)"
t_ok "foreign: the foreign dnsmasq still has the dead socket" test -n "$(foreign_log)" -a "$(foreign_log)" != "$(host_log)"
for i in 1 2; do
	r=$(trigger_ran)
	t_eq "foreign: trigger firing $i ran" true "$(echo "$r" | jsonfilter -e @.rewritten)"
done
reconciled
t_eq "foreign: further triggers restart nothing (no loop)" 1 "$(starts_all)"
t_eq "foreign: no stale restart was attempted for it" 1 "$(logread | grep -c 'lost /dev/log')"
kill "$(cat "$FOREIGN_PID")" 2>/dev/null
rm -f "$FOREIGN_PID"

# --- query_logging=0: no trigger, no restart --------------------------------
uci set adblock-fast-monitor.config.query_logging=0
uci commit adblock-fast-monitor
reload_config
t_ok "query_logging=0: drop-in removed" abfm_wait_until 30 sh -c '! ls /tmp/dnsmasq*.d/adblock-fast-monitor.conf'
reconciled
t_not "query_logging=0: the trigger is not registered" sh -c \
	"ubus call service list '{\"name\":\"adblock-fast-monitor\",\"verbose\":true}' | grep -q instance.update"
/etc/init.d/log restart
abfm_wait_until 15 ubus list log
abfm_wait_until 30 dns_ready
t_eq "query_logging=0: log restart restarts nothing" 0 "$(starts_all)"
# T06: the same uhttpd restart and window without the trigger; the difference
# is what one firing costs (it was ~5-8 processes through the init script).
r=$(ucode "$ABFM_FIXTURES/logging/trigger-forks.uc" control "$window")
forks_off=$(echo "$r" | jsonfilter -e @.forks)
t_diag "uhttpd restart + ${window} ms: $forks_on processes with the trigger, $forks_off without"
t_ok "one trigger firing creates at most 2 processes (logging.uc itself, plus noise)" test $((forks_on - forks_off)) -le 2
t_not "query_logging=0: the jailed dnsmasq keeps the dead socket (the upstream behaviour)" fresh
t_done
