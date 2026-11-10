# Shared setup for test/guest/actions-*.sh (sourced inside the guest after
# testlib.sh). It points real adblock-fast at the deterministic fixture list
# served by the host ($ABFM_FIXTURE_URL/actions/block.txt) and gives dnsmasq a
# local fake upstream on 127.0.0.1:5353 that answers every *.example.com name
# with a public-looking address, so "allowed" answers never need the internet.
# Everything it changes is restored by actions_teardown (backups survive a
# reboot under /root).

AF=/etc/init.d/adblock-fast
BK=/root/abfm-actions-backup
FX=$ABFM_FIXTURES/actions
JOB_FILE=/var/run/adblock-fast-monitor/job.json
LOCK_FILE=/var/lock/adblock-fast-monitor.lock
UPSTREAM_A=93.184.215.14

call() {
	_a=${2:-}
	[ -n "$_a" ] || _a='{}'
	ubus call luci.adblock-fast-monitor "$1" "$_a"
}
jget() { jsonfilter -s "$1" -e "$2"; }
err_code() { jsonfilter -s "$1" -e '@.error.code'; }
job_json() { call job; }

# dns_a NAME -> first A answer from 127.0.0.1, or NXDOMAIN / NOANSWER
dns_a() {
	_o=$(nslookup -type=a "$1" 127.0.0.1 2>&1)
	case "$_o" in
	*NXDOMAIN*) echo NXDOMAIN ;;
	*) printf '%s\n' "$_o" | awk '/^Name:/{n=1} n && /^Address:/{print $2; f=1; exit} END{if(!f) print "NOANSWER"}' ;;
	esac
}

# log_mark -> marker id; log_since MARK -> syslog lines after the marker
# (fails if the ring buffer already dropped the marker).
log_mark() {
	_m="abfm-mark-$$-$(date +%s)-$RANDOM"
	logger -t abfm-test "$_m"
	echo "$_m"
}
log_since() {
	logread | grep -qF "abfm-test: $1" || { echo 'MARK-LOST'; return 1; }
	logread | sed -n "/abfm-test: $1\$/,\$p"
}
dnsmasq_starts() { log_since "$1" | grep -c 'dnsmasq\[[0-9]*\]: started, version'; }
af_runs() { log_since "$1" | grep -o '\[INIT\] \(Starting\|Force-reloading\) adblock-fast' | wc -l; }

# hold_lock SECONDS & : holds the job lock in one process (no forked child).
hold_lock() { exec ucode -e 'let f = require("fs").open(ARGV[0], "a"); f.lock("x"); sleep(+ARGV[1] * 1000);' "$LOCK_FILE" "$1"; }
af_status() { ubus call service list '{"name":"adblock-fast"}' | jsonfilter -e '@["adblock-fast"].data.status'; }
uci_has() { uci -q get "adblock-fast.config.$1" | tr ' ' '\n' | grep -qxF "$2"; }

# watch REQUEST [TIMEOUT] -> {"apply","apply_ms","states","job"} (see watch.uc)
watch() { ucode "$FX/watch.uc" "$1" "${2:-600}"; }

wait_job_terminal() {
	_i=0
	while [ $_i -lt "${1:-600}" ]; do
		_s=$(job_json | jsonfilter -e '@.job.state')
		case "$_s" in applied|partial|failed|'') job_json; return 0 ;; esac
		sleep 1
		_i=$((_i + 1))
	done
	return 1
}

lock_free() { flock -n "$LOCK_FILE" true; }

start_fake_upstream() {
	[ -f /tmp/abfm-fake-upstream.pid ] && kill -0 "$(cat /tmp/abfm-fake-upstream.pid)" 2>/dev/null && return 0
	dnsmasq --port=5353 --listen-address=127.0.0.1 --bind-interfaces --no-resolv --no-hosts \
		--conf-file=/dev/null --pid-file=/tmp/abfm-fake-upstream.pid \
		--address=/example.com/$UPSTREAM_A --address=/example.com/2606:2800:21f:cb07:6820:80da:af6b:8b2c
}

# Rebuilds the fixture block-list with real adblock-fast.
#   actions_setup [DNS_MODE]
actions_setup() {
	mkdir -p "$BK"
	[ -f "$BK/dhcp" ] || cp /etc/config/dhcp "$BK/dhcp"
	if [ ! -f "$BK/adblock-fast" ]; then
		cp /etc/config/adblock-fast "$BK/adblock-fast"
		if $AF enabled; then echo 1 >"$BK/af-enabled"; else echo 0 >"$BK/af-enabled"; fi
	fi
	if ! apk info -e ucode-mod-resolv >/dev/null 2>&1; then
		t_diag 'ucode-mod-resolv is not pulled in by the package (WU4 Makefile); installing it for the job'
		apk add -q ucode-mod-resolv >/dev/null 2>&1
	fi
	if ! ubus list luci.adblock-fast-monitor >/dev/null 2>&1; then
		t_diag 'rpcd did not load the plugin at install (postinst rpcd reload is WU4); reloading rpcd'
		/etc/init.d/rpcd reload
		ubus -t 15 wait_for luci.adblock-fast-monitor
	fi
	start_fake_upstream
	if ! uci -q get dhcp.@dnsmasq[0].server | grep -qF '127.0.0.1#5353'; then
		uci set dhcp.@dnsmasq[0].noresolv=1
		uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5353'
		uci commit dhcp
	fi
	while uci -q delete adblock-fast.@file_url[0]; do :; done
	uci -q delete adblock-fast.config.allowed_domain
	uci -q delete adblock-fast.config.blocked_domain
	uci -q delete adblock-fast.config.dnsmasq_config_file_url
	uci set adblock-fast.fixture=file_url
	uci set adblock-fast.fixture.name='abfm actions fixture'
	uci set adblock-fast.fixture.url="$ABFM_FIXTURE_URL/actions/block.txt"
	uci set adblock-fast.fixture.action=block
	uci set adblock-fast.fixture.enabled=1
	uci set adblock-fast.config.enabled=1
	uci set adblock-fast.config.dns="${1:-dnsmasq.servers}"
	uci set adblock-fast.config.heartbeat_domain=heartbeat.example.com
	uci set adblock-fast.config.config_update_enabled=0
	uci commit adblock-fast
	rm -f /tmp/.uci/adblock-fast
	/etc/init.d/dnsmasq restart
	$AF enable
	$AF dl >/dev/null 2>&1
	rm -f "$JOB_FILE"
	[ "$(af_status)" = statusSuccess ]
}

actions_teardown() {
	[ -d "$BK" ] || return 0
	cp "$BK/adblock-fast" /etc/config/adblock-fast
	cp "$BK/dhcp" /etc/config/dhcp
	rm -f /tmp/.uci/adblock-fast "$JOB_FILE"
	if [ "$(cat "$BK/af-enabled")" = 1 ]; then
		$AF restart >/dev/null 2>&1
	else
		$AF stop >/dev/null 2>&1
		$AF disable
		cp "$BK/dhcp" /etc/config/dhcp
	fi
	[ -f /tmp/abfm-fake-upstream.pid ] && kill "$(cat /tmp/abfm-fake-upstream.pid)" 2>/dev/null
	rm -f /tmp/abfm-fake-upstream.pid
	/etc/init.d/dnsmasq restart
	rm -rf "$BK"
}
