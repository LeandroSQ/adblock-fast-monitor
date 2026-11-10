# Guest-side helpers for scripts/perf/run.sh (BusyBox ash on OpenWrt 25.12.6).
# Each perf_* function prints one JSON document on stdout; diagnostics go to
# stderr. Only stock applets are used (no stat, no timeout, no pgrep).

PERF_RESPONDER_PID=/var/run/abfm-perf-responder.pid
PERF_AF_BAK=/tmp/abfm-perf/adblock-fast.config.bak
PERF_SERVERS=/var/run/adblock-fast/dnsmasq.servers

perf_confdirs() { ls -d /tmp/dnsmasq*.d 2>/dev/null; }

# "started, version" lines logged by dnsmasq (one per process start).
perf_starts() { logread 2>/dev/null | grep -c 'dnsmasq\[[0-9]*\]: started, version'; }

# Logs a unique marker; perf_starts_since MARKER counts dnsmasq starts logged
# after it (the logd ring wraps under load, so absolute counts are unusable).
perf_mark() { _m="abfm-perf-mark-$$-$(date +%s)-$1"; logger -t abfm-perf "$_m"; echo "$_m"; }
perf_starts_since() {
	logread 2>/dev/null | awk -v m="$1" 'index($0, m) { n = 0; seen = 1; next }
		seen && /dnsmasq\[[0-9]+\]: started, version/ { n++ } END { print seen ? n : -1 }'
}

# pids of the system dnsmasq (not the perf responder), sorted, space separated
perf_dnsmasq_pids() {
	_r=$(cat "$PERF_RESPONDER_PID" 2>/dev/null)
	for _p in $(pidof dnsmasq); do [ "$_p" = "$_r" ] || echo "$_p"; done | sort -n | tr '\n' ' ' | sed 's/ $//'
}

# package processes: the cmdline names the package; plus `logread -f` readers
perf_pkg_procs() { ps w | grep '[a]dblock-fast-monitor' | grep -v 'lib\.sh' | sed 's/^ *//'; }
perf_logread_procs() { ps w | grep '[l]ogread -f' | sed 's/^ *//'; }

perf_json_str() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n\t' '  ')"; }

perf_state_fields() {
	_pk=$(perf_pkg_procs); _lr=$(perf_logread_procs)
	_obj=false; ubus list adblock-fast-monitor >/dev/null 2>&1 && _obj=true
	_plg=false; ubus list luci.adblock-fast-monitor >/dev/null 2>&1 && _plg=true
	_drop=''
	for _d in $(perf_confdirs); do [ -e "$_d/adblock-fast-monitor.conf" ] && _drop="$_drop $_d/adblock-fast-monitor.conf"; done
	printf '"enabled":%s,"package_procs":%s,"package_proc_count":%d,"logread_procs":%s,"logread_proc_count":%d,' \
		"$(perf_json_str "$(uci -q get adblock-fast-monitor.config.enabled)")" \
		"$(perf_json_str "$_pk")" "$(printf '%s' "$_pk" | grep -c .)" \
		"$(perf_json_str "$_lr")" "$(printf '%s' "$_lr" | grep -c .)"
	printf '"monitor_object":%s,"plugin_object":%s,"dropins":%s,"dnsmasq_pids":%s,"dnsmasq_starts_logged":%d,"uptime":%s' \
		"$_obj" "$_plg" "$(perf_json_str "${_drop# }")" "$(perf_json_str "$(perf_dnsmasq_pids)")" \
		"$(perf_starts)" "$(cut -d' ' -f1 /proc/uptime)"
}

perf_state() { printf '{'; perf_state_fields; printf '}\n'; }

# Waits until the dnsmasq pids and the package process set have been stable
# for 5 s (max 60 s); prints the seconds waited.
perf_settle() {
	_i=0; _stable=0; _last=''
	sleep 2
	while [ $_i -lt 60 ]; do
		_sig="$(perf_dnsmasq_pids)|$(perf_pkg_procs | awk '{print $1}' | tr '\n' ,)|$(perf_logread_procs | awk '{print $1}' | tr '\n' ,)"
		if [ "$_sig" = "$_last" ]; then _stable=$((_stable + 1)); else _stable=0; _last=$_sig; fi
		[ $_stable -ge 5 ] && break
		sleep 1; _i=$((_i + 1))
	done
	echo $((_i + 2))
}

perf_prepare() {
	/etc/init.d/sysntpd stop >/dev/null 2>&1
	[ -s "$PERF_RESPONDER_PID" ] && kill "$(cat "$PERF_RESPONDER_PID")" 2>/dev/null
	dnsmasq --conf-file=/dev/null --port=5300 --listen-address=127.0.0.1 --bind-interfaces \
		--no-resolv --no-hosts --address=/perf.test/192.0.2.1 --local-ttl=300 --cache-size=0 \
		--user=root --group=root --pid-file="$PERF_RESPONDER_PID" --log-facility=/dev/null || return 1
	_dirs=$(perf_confdirs)
	[ -n "$_dirs" ] || { echo 'no dnsmasq confdir' >&2; return 1; }
	for _d in $_dirs; do
		printf 'server=/perf.test/127.0.0.1#5300\nrebind-domain-ok=/perf.test/\nlocal=/perf-block.test/\n' >"$_d/abfm-perf.conf"
	done
	/etc/init.d/dnsmasq restart >/dev/null 2>&1
	_i=0
	until nslookup u-prep.perf.test 127.0.0.1 2>/dev/null | grep -q 192.0.2.1; do
		_i=$((_i + 1)); [ $_i -lt 30 ] || { echo 'dnsmasq does not forward perf.test' >&2; return 1; }
		sleep 1
	done
	printf '{"confdirs":%s,"responder_pid":%s,"ntpd_stopped":true,"ready_after_s":%d}\n' \
		"$(perf_json_str "$_dirs")" "$(cat "$PERF_RESPONDER_PID")" "$_i"
}

perf_install() {
	_mk=$(perf_mark install)
	apk add --allow-untrusted "$1" >&2; _rc=$?
	_s=$(perf_settle)
	printf '{"rc":%d,"dnsmasq_starts_during_install":%d,"settle_s":%d,' "$_rc" "$(perf_starts_since "$_mk")" "$_s"
	perf_state_fields; printf '}\n'
	return $_rc
}

# perf_apply_uci DESCRIPTION UCI_SET_ARGS... : commit + reload_config (what
# LuCI's uci.apply does), then count dnsmasq restarts until things settle.
perf_apply_uci() {
	_what=$1; shift
	_mk=$(perf_mark apply); _pb=$(perf_dnsmasq_pids)
	for _kv in "$@"; do uci set "adblock-fast-monitor.config.$_kv"; done
	_changes=$(uci changes adblock-fast-monitor | grep -c .)
	uci commit adblock-fast-monitor
	reload_config
	if [ -e "$PERF_SELFTEST_FLAG" ]; then
		case "$_what" in enabled=*) perf_selftest_apply enabled "${_what#enabled=}" ;; *) perf_selftest_apply save ;; esac
	fi
	_s=$(perf_settle)
	printf '{"action":%s,"uci_changes":%d,"dnsmasq_restarts":%d,"dnsmasq_pids_before":%s,"settle_s":%d,' \
		"$(perf_json_str "$_what")" "$_changes" "$(perf_starts_since "$_mk")" "$(perf_json_str "$_pb")" "$_s"
	perf_state_fields; printf '}\n'
}

# Self-test (scripts/perf/run.sh with ABFM_PERF_SELFTEST=1): emulate the
# contract's enable/disable/save with the stand-in daemon and a real
# log-queries drop-in, so the daemon-side measurements run on real processes.
PERF_SELFTEST_FLAG=/tmp/abfm-perf/selftest
perf_selftest_stop() {
	for _p in $(ps w | grep '[a]dblock-fast-monitor-standin' | awk '{print $1}'); do
		for _c in $(grep -l "^PPid:[[:space:]]*$_p\$" /proc/[0-9]*/status 2>/dev/null | cut -d/ -f3); do kill "$_c"; done
		kill "$_p"
	done
}
perf_selftest_start() {
	setsid ucode /tmp/abfm-perf/adblock-fast-monitor-standin.uc </dev/null >/dev/null 2>&1 &
}
perf_selftest_apply() { # enabled|save value
	_changed=0
	for _d in $(perf_confdirs); do
		if [ "$1" = enabled ] && [ "$2" = 1 ]; then
			[ -e "$_d/adblock-fast-monitor.conf" ] || { printf 'log-queries=extra\n' >"$_d/adblock-fast-monitor.conf"; _changed=1; }
		elif [ "$1" = enabled ]; then
			[ -e "$_d/adblock-fast-monitor.conf" ] && { rm -f "$_d/adblock-fast-monitor.conf"; _changed=1; }
		fi
	done
	perf_selftest_stop
	[ $_changed = 1 ] && /etc/init.d/dnsmasq restart >/dev/null 2>&1
	[ "$(uci -q get adblock-fast-monitor.config.enabled)" = 1 ] && perf_selftest_start
}

perf_set() {
	# v0 packages also need own_logqueries to log; v1 has no such option.
	_extra=''
	[ -n "$(uci -q get adblock-fast-monitor.config.own_logqueries)" ] && _extra="own_logqueries=$1"
	perf_apply_uci "enabled=$1" "enabled=$1" $_extra
}

perf_save() { perf_apply_uci "$1=$2" "$1=$2"; }

perf_boot_report() {
	printf '{"boot":true,"dnsmasq_starts_since_boot":%d,' "$(perf_starts)"
	perf_state_fields; printf '}\n'
}

perf_rules_fixture() {
	case "$1" in
	setup)
		cp /etc/config/adblock-fast "$PERF_AF_BAK"
		_existed=false
		[ -e "$PERF_SERVERS" ] && { _existed=true; mv "$PERF_SERVERS" "$PERF_SERVERS.abfm-perf-bak"; }
		mkdir -p "${PERF_SERVERS%/*}"
		awk 'BEGIN { for (i = 0; i < 100000; i++) printf "server=/perf-list-%06d.example/\n", i }' >"$PERF_SERVERS"
		printf '{"fixture":"setup","dns":%s,"output_file":"%s","lines":%d,"bytes":%d,"existed":%s}\n' \
			"$(perf_json_str "$(uci -q get adblock-fast.config.dns)")" "$PERF_SERVERS" \
			"$(wc -l <"$PERF_SERVERS")" "$(wc -c <"$PERF_SERVERS")" "$_existed"
		;;
	teardown)
		rm -f "$PERF_SERVERS"
		[ -e "$PERF_SERVERS.abfm-perf-bak" ] && mv "$PERF_SERVERS.abfm-perf-bak" "$PERF_SERVERS"
		[ -e "$PERF_AF_BAK" ] && cp "$PERF_AF_BAK" /etc/config/adblock-fast
		printf '{"fixture":"teardown"}\n'
		;;
	esac
}

perf_wait_job() {
	_i=0
	while [ $_i -lt "$1" ]; do
		_j=$(ubus call luci.adblock-fast-monitor job '{}' 2>&1)
		echo "$_j" | grep -Eq '"state": "(applied|partial|failed|interrupted)"' && break
		sleep 1; _i=$((_i + 1))
	done
	printf '{"waited_s":%d,"last":%s}\n' "$_i" "$(perf_json_str "$_j")"
}
