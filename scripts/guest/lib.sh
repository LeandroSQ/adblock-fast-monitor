# shellcheck shell=bash
# SPDX-License-Identifier: Apache-2.0
# Reusable OpenWrt 25.12.6 QEMU guest API (Linux host or container with
# qemu-system-x86_64). Source it from bash:
#
#   source scripts/guest/lib.sh
#   guest_start                       # fresh copy-on-write overlay of the baseline
#   guest_exec 'uci show system'      # run a guest shell command (stdin forwarded)
#   guest_copy  LOCAL REMOTE          # copy a file into the guest
#   guest_copy_dir LOCAL_DIR REMOTE_DIR
#   guest_fetch REMOTE LOCAL          # copy a file out of the guest
#   guest_reboot                      # reboot and wait until ready again
#   guest_stop                        # kill QEMU + helpers, drop the overlay
#
# Inputs (environment, all optional):
#   GUEST_CACHE        cache dir (default .local-validation/qemu)
#   GUEST_BASELINE     baseline qcow2 (default $GUEST_CACHE/abfm-baseline-25.12.6.qcow2;
#                      built on first use by scripts/guest/prepare-baseline.sh)
#   GUEST_DISK         boot this disk directly instead of an overlay (baseline prep)
#   GUEST_SSH_PORT GUEST_HTTP_PORT GUEST_DNS_PORT
#                      host ports forwarded to guest 22/tcp, 80/tcp, 53/udp on
#                      127.0.0.1; "auto" (default) picks free ports, so
#                      concurrent guests never collide
#   GUEST_MEMORY (MiB, 256)  GUEST_CPUS (2)  GUEST_ACCEL (auto|kvm|tcg)
#   GUEST_BOOT_TIMEOUT seconds (default 120 with KVM, 600 with TCG)
#   GUEST_FEEDS        cache (default: apk feeds via the host pull-through cache
#                      in .local-validation/openwrt-package-mirror), official
#                      (stock downloads.openwrt.org over QEMU NAT) or none
#   GUEST_OFFLINE=1    cache serves cached files only (no upstream fetches)
#   GUEST_KEEP_DISK=1  keep the run overlay after guest_stop
#
# Outputs (exported by guest_start):
#   GUEST_RUN_DIR (serial.log, qemu.log, apk-proxy.log, ssh key, results)
#   GUEST_SSH_KEY GUEST_SSH_PORT GUEST_HTTP_PORT GUEST_DNS_PORT
#   GUEST_HTTP_URL           http://127.0.0.1:$GUEST_HTTP_PORT (LuCI)
#   GUEST_HOST_URL           host server as seen from the guest (http://10.0.2.2:N)
#   GUEST_FIXTURE_URL        $GUEST_HOST_URL/fixtures (test/fixtures, read-only)
#   GUEST_ROOT_PASSWORD      random per run (root, LuCI admin)
#   GUEST_READONLY_USER / GUEST_READONLY_PASSWORD  rpcd login limited to the
#                            luci-app-adblock-fast-monitor read ACL
#   GUEST_ACCEL_USED GUEST_BOOT_SECONDS
#   Legacy aliases for scripts/integration/*: OPENWRT_HOST OPENWRT_SSH_PORT
#   OPENWRT_SSH_KEY OPENWRT_DNS_PORT OPENWRT_LUCI_BASE_URL
#   OPENWRT_PACKAGE_MIRROR_URL FIXTURE_LIST_URL MONITOR_*_LUCI_USERNAME/PASSWORD

GUEST_LIB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUEST_IMAGE_URL='https://downloads.openwrt.org/releases/25.12.6/targets/x86/64/openwrt-25.12.6-x86-64-generic-ext4-combined.img.gz'
GUEST_IMAGE_SHA256='f8538784d0288b4133a99ac2a68443e4922ffde6343e80df56a5882364b9d499'

guest__log() { printf 'guest: %s\n' "$*" >&2; }
guest__die() { guest__log "$*"; return 1; }
guest__sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
guest__free_port() {
	python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}
guest__port() { # name default_for_auto
	local value="${!1:-auto}"
	if [[ "$value" == auto ]]; then guest__free_port; else printf '%s\n' "$value"; fi
}

guest_require_host() {
	local missing=()
	for command in qemu-img qemu-system-x86_64 ssh ssh-keygen openssl python3 curl sha256sum gzip; do
		command -v "$command" >/dev/null || missing+=("$command")
	done
	((${#missing[@]} == 0)) || guest__die "missing host prerequisites: ${missing[*]}"
}

# Downloads and verifies the stock image once; never rewrites an existing one.
guest_base_image() {
	local cache="${GUEST_CACHE:-$GUEST_LIB_ROOT/.local-validation/qemu}"
	local raw="$cache/openwrt-base.img"
	if [[ ! -f "$raw" ]]; then
		mkdir -p "$cache"
		if [[ ! -f "$cache/openwrt.img.gz" ]]; then
			curl --fail --location --retry 3 --output "$cache/openwrt.img.gz.partial" "$GUEST_IMAGE_URL"
			mv "$cache/openwrt.img.gz.partial" "$cache/openwrt.img.gz"
		fi
		printf '%s  %s\n' "$GUEST_IMAGE_SHA256" "$cache/openwrt.img.gz" | sha256sum --check --status ||
			guest__die "checksum mismatch: $cache/openwrt.img.gz" || return 1
		# gzip exits 2 on the image's trailing padding warning; the data is complete.
		gzip -dc "$cache/openwrt.img.gz" >"$raw.partial" || [[ $? -eq 2 ]]
		mv "$raw.partial" "$raw"
	fi
	printf '%s\n' "$raw"
}

guest__ssh_opts() {
	GUEST__SSH=(ssh -i "$GUEST_SSH_KEY" -p "$GUEST_SSH_PORT" -o BatchMode=yes -o ConnectTimeout=5
		-o StrictHostKeyChecking=no -o UserKnownHostsFile="$GUEST_RUN_DIR/known_hosts"
		-o LogLevel=ERROR -o ServerAliveInterval=15 root@127.0.0.1)
}

# guest_exec COMMAND... : runs the words joined by spaces in the guest's ash.
guest_exec() {
	guest__ssh_opts
	"${GUEST__SSH[@]}" "$*"
}

guest_copy() {
	guest__ssh_opts
	"${GUEST__SSH[@]}" "mkdir -p \"\$(dirname $(guest__sq "$2"))\" && cat > $(guest__sq "$2")" <"$1"
}

guest_copy_dir() {
	guest__ssh_opts
	tar -C "$1" -cf - . | "${GUEST__SSH[@]}" "mkdir -p $(guest__sq "$2") && tar -C $(guest__sq "$2") -xf -"
}

guest_fetch() {
	guest__ssh_opts
	"${GUEST__SSH[@]}" "cat $(guest__sq "$1")" >"$2"
}

# In-guest readiness: LAN has an IPv4 address, dnsmasq runs, dropbear and (if
# installed) uhttpd listen. Polls once a second; no fixed delays.
# shellcheck disable=SC2016 # expanded by the guest shell
GUEST_READY_CHECK='( i=0; until ifstatus lan 2>/dev/null | jsonfilter -e "@[\"ipv4-address\"][0].address" | grep -q "^10[.]0[.]2[.]" && pidof dnsmasq >/dev/null && netstat -ltn 2>/dev/null | grep -q ":22 " && { [ ! -x /etc/init.d/uhttpd ] || ! /etc/init.d/uhttpd enabled || netstat -ltn 2>/dev/null | grep -q ":80 "; }; do i=$((i+1)); [ $i -lt 180 ] || exit 1; sleep 1; done )'

# QEMU's pid lives in $GUEST_RUN_DIR/qemu.pid: guest_reboot may start a new
# QEMU from a test's own shell, and guest_stop in the runner must find it.
guest__qemu_pid() { cat "$GUEST_RUN_DIR/qemu.pid" 2>/dev/null || echo "${GUEST_QEMU_PID:-}"; }
guest__qemu_alive() { # PID: running, not a zombie
	local pid="$1" state
	[[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null || return 1
	state="$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)"
	[[ "$state" != Z ]]
}

# Starts QEMU on the run's disk, ports and serial log (appended across
# restarts) and records its pid.
guest__launch_qemu() {
	local accel
	read -r -a accel <<<"$GUEST__ACCEL_ARGS"
	rm -f "$GUEST_RUN_DIR/serial.sock"
	qemu-system-x86_64 "${accel[@]}" -smp "${GUEST_CPUS:-2}" -m "${GUEST_MEMORY:-256}" \
		-display none -nic none \
		-chardev "socket,id=serial0,path=$GUEST_RUN_DIR/serial.sock,server=on,wait=off,logfile=$GUEST_RUN_DIR/serial.log,logappend=on" \
		-serial chardev:serial0 \
		-drive "file=$GUEST__DISK,format=qcow2,if=virtio" \
		-netdev "user,id=lan,hostfwd=tcp:127.0.0.1:$GUEST_SSH_PORT-:22,hostfwd=tcp:127.0.0.1:$GUEST_HTTP_PORT-:80,hostfwd=udp:127.0.0.1:$GUEST_DNS_PORT-:53" \
		-device virtio-net-pci,netdev=lan >>"$GUEST_RUN_DIR/qemu.log" 2>&1 &
	GUEST_QEMU_PID=$!
	echo "$GUEST_QEMU_PID" >"$GUEST_RUN_DIR/qemu.pid"
}

guest__wait_ssh() {
	local deadline=$(($(date +%s) + ${1:-120}))
	until guest_exec true 2>/dev/null; do
		(($(date +%s) < deadline)) || return 1
		guest__qemu_alive "$(guest__qemu_pid)" || { guest__log 'QEMU exited'; return 1; }
		sleep 1
	done
	guest_exec "$GUEST_READY_CHECK"
}

guest_start() {
	guest_require_host || return 1
	local cache="${GUEST_CACHE:-$GUEST_LIB_ROOT/.local-validation/qemu}"
	local baseline="${GUEST_BASELINE:-$cache/abfm-baseline-25.12.6.qcow2}"
	local started
	started=$(date +%s)

	GUEST_RUN_DIR="${GUEST_RUN_DIR:-$cache/runs/$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM}"
	mkdir -p "$GUEST_RUN_DIR"
	local disk="${GUEST_DISK:-}"
	if [[ -z "$disk" ]]; then
		if [[ ! -f "$baseline" ]]; then
			guest__log "baseline missing; preparing $baseline"
			GUEST_BASELINE="$baseline" "$GUEST_LIB_ROOT/scripts/guest/prepare-baseline.sh" || return 1
		fi
		# The baseline's backing file (stock raw image) is not cached in CI; recreate it.
		guest_base_image >/dev/null || return 1
		disk="$GUEST_RUN_DIR/disk.qcow2"
		qemu-img create -q -f qcow2 -F qcow2 -b "$(cd "$(dirname "$baseline")" && pwd)/$(basename "$baseline")" "$disk"
	fi
	GUEST__DISK_OWNED=$([[ -z "${GUEST_DISK:-}" ]] && echo 1 || echo 0)
	GUEST__DISK="$disk"

	GUEST_SSH_KEY="$GUEST_RUN_DIR/id_ed25519"
	rm -f "$GUEST_SSH_KEY" "$GUEST_SSH_KEY.pub" "$GUEST_RUN_DIR/known_hosts"
	ssh-keygen -q -t ed25519 -N '' -C abfm-guest -f "$GUEST_SSH_KEY"
	GUEST_ROOT_PASSWORD="$(openssl rand -hex 16)"
	GUEST_READONLY_USER=monitor-readonly
	GUEST_READONLY_PASSWORD="$(openssl rand -hex 16)"

	rm -f "$GUEST_RUN_DIR/proxy.port"
	# shellcheck disable=SC2046 # expands to no argument unless offline
	python3 "$GUEST_LIB_ROOT/scripts/guest/apk-cache-proxy.py" --port 0 \
		--cache "${GUEST_PACKAGE_CACHE:-$GUEST_LIB_ROOT/.local-validation/openwrt-package-mirror}" \
		--fixtures "$GUEST_LIB_ROOT/test/fixtures" --ready-file "$GUEST_RUN_DIR/proxy.port" \
		$([[ "${GUEST_OFFLINE:-0}" == 1 ]] && echo --offline) >"$GUEST_RUN_DIR/apk-proxy.log" 2>&1 &
	GUEST_PROXY_PID=$!
	local i
	for ((i = 0; i < 100; i++)); do [[ -s "$GUEST_RUN_DIR/proxy.port" ]] && break; sleep 0.1; done
	[[ -s "$GUEST_RUN_DIR/proxy.port" ]] || guest__die 'package cache proxy did not start' || return 1
	GUEST_HOST_URL="http://10.0.2.2:$(cat "$GUEST_RUN_DIR/proxy.port")"

	# shellcheck disable=SC2054 # the comma is part of the QEMU option value
	local accel=(-accel tcg,thread=multi -cpu max)
	GUEST_ACCEL_USED=tcg
	if [[ "${GUEST_ACCEL:-auto}" != tcg && -r /dev/kvm && -w /dev/kvm ]]; then
		accel=(-enable-kvm -cpu host)
		GUEST_ACCEL_USED=kvm
	elif [[ "${GUEST_ACCEL:-auto}" == kvm ]]; then
		guest__die 'GUEST_ACCEL=kvm but /dev/kvm is not usable' || return 1
	fi
	local boot_timeout="${GUEST_BOOT_TIMEOUT:-$([[ $GUEST_ACCEL_USED == kvm ]] && echo 120 || echo 600)}"

	GUEST__ACCEL_ARGS="${accel[*]}"
	# "auto" ports are probed free and then handed to QEMU, so a concurrent
	# guest can take one in between; QEMU then exits at once ("Could not set
	# up host forwarding rule"). Pick new ports and launch again (3 tries).
	local attempt
	for attempt in 1 2 3; do
		GUEST_SSH_PORT="$(guest__port GUEST_SSH_PORT)"
		GUEST_HTTP_PORT="$(guest__port GUEST_HTTP_PORT)"
		GUEST_DNS_PORT="$(guest__port GUEST_DNS_PORT)"
		rm -f "$GUEST_RUN_DIR/serial.log"
		: >"$GUEST_RUN_DIR/qemu.log"
		guest__launch_qemu
		for ((i = 0; i < 200; i++)); do
			[[ -s "$GUEST_RUN_DIR/serial.log" ]] && break
			guest__qemu_alive "$GUEST_QEMU_PID" || break
			sleep 0.1
		done
		guest__qemu_alive "$GUEST_QEMU_PID" && break
		grep -qi 'forward' "$GUEST_RUN_DIR/qemu.log" ||
			{ cat "$GUEST_RUN_DIR/qemu.log" >&2; guest_stop; return 1; }
		guest__log "host port taken (attempt $attempt): $(tr '\n' ' ' <"$GUEST_RUN_DIR/qemu.log")"
		((attempt < 3)) || { guest_stop; return 1; }
	done

	local root_hash readonly_hash feeds
	# crypt(3) hashes use only [./0-9A-Za-z$], so they are safe inside single quotes.
	root_hash="$(openssl passwd -6 "$GUEST_ROOT_PASSWORD")"
	readonly_hash="$(openssl passwd -6 "$GUEST_READONLY_PASSWORD")"
	case "${GUEST_FEEDS:-cache}" in
		cache) feeds="sed -i -E 's#(https?://downloads[.]openwrt[.]org|http://10[.]0[.]2[.]2:[0-9]+)#$GUEST_HOST_URL#' /etc/apk/repositories.d/distfeeds.list" ;;
		official | none) feeds=true ;;
		*) guest__die "unknown GUEST_FEEDS=${GUEST_FEEDS}" || return 1 ;;
	esac
	# The setup commits rpcd (and maybe network) and applies them itself; the
	# last step records that like reload_config would, without its events, so
	# a test's own reload_config never replays the harness's changes.
	python3 "$GUEST_LIB_ROOT/scripts/guest/serial-console.py" "$GUEST_RUN_DIR/serial.sock" "$boot_timeout" <<-EOF || { tail -n 40 "$GUEST_RUN_DIR/serial.log" >&2; guest_stop; return 1; }
		ubus -t "$boot_timeout" wait_for network.interface.lan session uci service
		sed -i 's|^root:[^:]*:|root:$root_hash:|' /etc/shadow
		mkdir -p /etc/dropbear && chmod 700 /etc/dropbear && printf '%s\n' '$(cat "$GUEST_SSH_KEY.pub")' >/etc/dropbear/authorized_keys && chmod 600 /etc/dropbear/authorized_keys
		grep -q '^$GUEST_READONLY_USER:' /etc/passwd || { echo '$GUEST_READONLY_USER:x:1001:65534:monitor read-only:/var:/bin/false' >>/etc/passwd; echo '$GUEST_READONLY_USER:x:0:0:99999:7:::' >>/etc/shadow; }
		sed -i 's|^$GUEST_READONLY_USER:[^:]*:|$GUEST_READONLY_USER:$readonly_hash:|' /etc/shadow
		uci -q get rpcd.monitor_readonly >/dev/null || { uci set rpcd.monitor_readonly=login; uci set rpcd.monitor_readonly.username='$GUEST_READONLY_USER'; uci set rpcd.monitor_readonly.password='\$p\$$GUEST_READONLY_USER'; uci add_list rpcd.monitor_readonly.read='luci-app-adblock-fast-monitor'; uci add_list rpcd.monitor_readonly.read='luci-base'; uci add_list rpcd.monitor_readonly.read='unauthenticated'; uci commit rpcd; /etc/init.d/rpcd reload; }
		$feeds
		[ "\$(uci -q get network.lan.proto)" = dhcp ] || { uci set network.lan.proto=dhcp; uci delete network.lan.ipaddr; uci delete network.lan.netmask; uci commit network; /etc/init.d/network reload; }
		[ ! -f /var/run/config.md5 ] || { rm -rf /var/run/config.check; mkdir -p /var/run/config.check; for c in /etc/config/*; do uci show \${c##*/} >/var/run/config.check/\${c##*/}; done; md5sum /var/run/config.check/* >/var/run/config.md5; rm -rf /var/run/config.check; }
		$GUEST_READY_CHECK
	EOF
	guest__wait_ssh "$boot_timeout" || { guest__log 'guest SSH did not become ready'; guest_stop; return 1; }
	GUEST_BOOT_SECONDS=$(($(date +%s) - started))

	GUEST_HTTP_URL="http://127.0.0.1:$GUEST_HTTP_PORT"
	GUEST_FIXTURE_URL="$GUEST_HOST_URL/fixtures"
	export GUEST_RUN_DIR GUEST_SSH_KEY GUEST_SSH_PORT GUEST_HTTP_PORT GUEST_DNS_PORT GUEST_HTTP_URL \
		GUEST_HOST_URL GUEST_FIXTURE_URL GUEST_ROOT_PASSWORD GUEST_READONLY_USER GUEST_READONLY_PASSWORD \
		GUEST_ACCEL_USED GUEST_BOOT_SECONDS GUEST_QEMU_PID GUEST_PROXY_PID GUEST__DISK GUEST__ACCEL_ARGS
	export OPENWRT_HOST=127.0.0.1 OPENWRT_SSH_PORT="$GUEST_SSH_PORT" OPENWRT_SSH_KEY="$GUEST_SSH_KEY" \
		OPENWRT_DNS_PORT="$GUEST_DNS_PORT" OPENWRT_LUCI_BASE_URL="$GUEST_HTTP_URL" \
		OPENWRT_PACKAGE_MIRROR_URL="$GUEST_HOST_URL" FIXTURE_LIST_URL="$GUEST_FIXTURE_URL/lists" \
		MONITOR_WRITE_LUCI_USERNAME=root MONITOR_WRITE_LUCI_PASSWORD="$GUEST_ROOT_PASSWORD" \
		MONITOR_READONLY_LUCI_USERNAME="$GUEST_READONLY_USER" MONITOR_READONLY_LUCI_PASSWORD="$GUEST_READONLY_PASSWORD"
	export -f guest_exec guest_copy guest_copy_dir guest_fetch guest__ssh_opts guest__sq
	guest__log "ready in ${GUEST_BOOT_SECONDS}s ($GUEST_ACCEL_USED): ssh 127.0.0.1:$GUEST_SSH_PORT http $GUEST_HTTP_URL dns 127.0.0.1:$GUEST_DNS_PORT/udp run $GUEST_RUN_DIR"
}

# Reboots the guest and waits until it is ready again. A power cycle, not a
# warm reset: under TCG (notably on arm64 hosts) a warm reset can stall for
# minutes between GRUB's "Booting `OpenWrt'" and the kernel, while a cold
# start of the same disk takes ~25 s. For the guest this is a reboot
# (tmpfs gone, init scripts run in START order).
guest_reboot() {
	local timeout="${GUEST_BOOT_TIMEOUT:-$([[ $GUEST_ACCEL_USED == kvm ]] && echo 120 || echo 600)}"
	local marks pid i
	pid="$(guest__qemu_pid)"
	guest_exec 'sync; poweroff' || true
	for ((i = 0; i < 120; i++)); do guest__qemu_alive "$pid" || break; sleep 1; done
	if guest__qemu_alive "$pid"; then
		guest__log 'guest did not power off; killing QEMU'
		kill "$pid" 2>/dev/null || true
		for ((i = 0; i < 20; i++)); do guest__qemu_alive "$pid" || break; sleep 1; done
	fi
	marks=$(grep -c 'Please press Enter to activate this console' "$GUEST_RUN_DIR/serial.log" || true)
	guest__launch_qemu
	local deadline=$(($(date +%s) + timeout))
	until (($(grep -c 'Please press Enter to activate this console' "$GUEST_RUN_DIR/serial.log" || true) > marks)); do
		(($(date +%s) < deadline)) || guest__die 'guest did not come back after reboot' || return 1
		guest__qemu_alive "$GUEST_QEMU_PID" || guest__die 'QEMU exited during reboot' || return 1
		sleep 1
	done
	guest__wait_ssh "$timeout"
}

guest_stop() {
	local pid p i
	pid="$(guest__qemu_pid)"
	for p in $pid ${GUEST_QEMU_PID:-}; do
		kill "$p" 2>/dev/null || true
		wait "$p" 2>/dev/null || true
		for ((i = 0; i < 20; i++)); do guest__qemu_alive "$p" || break; sleep 0.5; done
	done
	GUEST_QEMU_PID=''
	rm -f "${GUEST_RUN_DIR:-/nonexistent}/qemu.pid"
	if [[ -n "${GUEST_PROXY_PID:-}" ]]; then
		kill "$GUEST_PROXY_PID" 2>/dev/null || true
		wait "$GUEST_PROXY_PID" 2>/dev/null || true
		GUEST_PROXY_PID=''
	fi
	if [[ "${GUEST__DISK_OWNED:-0}" == 1 && "${GUEST_KEEP_DISK:-0}" != 1 ]]; then
		rm -f "$GUEST__DISK"
	fi
	rm -f "${GUEST_RUN_DIR:-/nonexistent}/serial.sock"
}
