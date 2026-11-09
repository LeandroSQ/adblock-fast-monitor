#!/usr/bin/env bash
set -euo pipefail

fail() { printf 'OpenWrt QEMU test: %s\n' "$*" >&2; exit 1; }

readonly image_url='https://downloads.openwrt.org/releases/25.12.6/targets/x86/64/openwrt-25.12.6-x86-64-generic-ext4-combined.img.gz'
readonly image_sha256='f8538784d0288b4133a99ac2a68443e4922ffde6343e80df56a5882364b9d499'
readonly cache_root="$PWD/.local-validation/qemu"
readonly mirror_root="$PWD/.local-validation/openwrt-package-mirror"
readonly base_image="$cache_root/openwrt-base.img"
readonly prepared_image="$cache_root/openwrt-prepared.qcow2"
readonly prepared_manifest="$cache_root/openwrt-prepared.manifest"

[[ "$(uname -s)" == Linux ]] || fail 'QEMU integration requires Linux.'
for command in qemu-img qemu-system-x86_64 ssh scp ssh-keygen openssl python3 sha256sum gzip; do
	command -v "$command" >/dev/null || fail "missing host prerequisite: $command"
done
: "${PACKAGE_IPK:?Set PACKAGE_IPK to the built APK.}"
[[ -f "$PACKAGE_IPK" ]] || fail "package not found: $PACKAGE_IPK"
[[ -f "$mirror_root/manifest.env" ]] || fail 'run the host package-mirror preparation first'

mkdir -p "$cache_root/runs"
if [[ ! -f "$base_image" ]]; then
	curl --fail --location --retry 3 --output "$cache_root/openwrt.img.gz" "$image_url"
	printf '%s  %s\n' "$image_sha256" "$cache_root/openwrt.img.gz" | sha256sum --check
	gzip -dc "$cache_root/openwrt.img.gz" >"$base_image"
fi

artifact_sha="$(sha256sum "$PACKAGE_IPK" | awk '{print $1}')"
accel='tcg'
qemu_accel=(-accel tcg,thread=multi)
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
	accel='kvm'
	qemu_accel=(-enable-kvm -cpu host)
fi

list_server_pid=''
mirror_server_pid=''
qemu_pid=''
cleanup() {
	[[ -n "$qemu_pid" ]] && kill "$qemu_pid" 2>/dev/null || true
	[[ -n "$list_server_pid" ]] && kill "$list_server_pid" 2>/dev/null || true
	[[ -n "$mirror_server_pid" ]] && kill "$mirror_server_pid" 2>/dev/null || true
}
trap cleanup EXIT

python3 -m http.server 18080 --bind 127.0.0.1 --directory test/fixtures/lists \
	>"$cache_root/list-server.log" 2>&1 &
list_server_pid=$!
python3 -m http.server 18081 --bind 127.0.0.1 --directory "$mirror_root" \
	>"$cache_root/package-mirror.log" 2>&1 &
mirror_server_pid=$!

launch_guest() {
	local disk="$1" run_dir="$2"
	qemu_pid=''
	qemu-system-x86_64 \
		"${qemu_accel[@]}" -m 512M -display none \
		-chardev socket,id=serial,path="$run_dir/serial.sock",server=on,wait=off -serial chardev:serial \
		-drive "file=$disk,format=qcow2,if=virtio" \
		-netdev user,id=net0,hostfwd=tcp::2222-:22,hostfwd=tcp::8080-:80,hostfwd=udp::5353-:53 \
		-device virtio-net-pci,netdev=net0 >"$run_dir/serial.log" 2>&1 &
	qemu_pid=$!

	local key="$run_dir/id_ed25519" root_password readonly_password
	ssh-keygen -q -t ed25519 -N '' -f "$key"
	root_password="$(openssl rand -hex 18)"
	readonly_password="$(openssl rand -hex 18)"
	python3 scripts/integration/provision-openwrt-serial.py "$run_dir/serial.sock" \
		"$key.pub" "$root_password" "$readonly_password"
	for _ in $(seq 1 90); do
		if ssh -i "$key" -o BatchMode=yes -o ConnectTimeout=2 -o StrictHostKeyChecking=accept-new \
			-p 2222 root@127.0.0.1 true 2>/dev/null; then
			export OPENWRT_HOST=127.0.0.1 OPENWRT_SSH_PORT=2222 OPENWRT_SSH_KEY="$key"
			export OPENWRT_LUCI_BASE_URL=http://127.0.0.1:8080
			export MONITOR_WRITE_LUCI_USERNAME=root MONITOR_WRITE_LUCI_PASSWORD="$root_password"
			export MONITOR_READONLY_LUCI_USERNAME=monitor-readonly MONITOR_READONLY_LUCI_PASSWORD="$readonly_password"
			export OPENWRT_RUNTIME_TEST="$PWD/scripts/integration/runtime-dns-lifecycle.sh"
			export FIXTURE_LIST_URL=http://10.0.2.2:18080 QEMU_ACCELERATION="$accel"
			export OPENWRT_PACKAGE_MIRROR_URL=http://10.0.2.2:18081
			export OPENWRT_STAGE_ARTIFACTS="$run_dir/stages"
			return 0
		fi
		sleep 2
	done
	tail -n 100 "$run_dir/serial.log" >&2 || true
	return 1
}

stop_guest() {
	kill "$qemu_pid"
	wait "$qemu_pid" 2>/dev/null || true
	qemu_pid=''
}

prime_package_mirror() {
	local urls="$cache_root/required-package-urls.txt"
	local upstream='https://downloads.openwrt.org'
	local stock_repositories="$cache_root/stock-apk-repositories.txt"
	ssh -i "$OPENWRT_SSH_KEY" -p "$OPENWRT_SSH_PORT" -o BatchMode=yes \
		-o StrictHostKeyChecking=accept-new root@"$OPENWRT_HOST" \
		'for f in /etc/apk/repositories /etc/apk/repositories.d/*; do [ -f "$f" ] && { printf "### %s\n" "$f"; cat "$f"; }; done' \
		>"$stock_repositories"
	sed "s#^$OPENWRT_PACKAGE_MIRROR_URL#$upstream#" "$stock_repositories" |
		grep -E "^$upstream/" | sort -u >"$cache_root/stock-apk-urls.txt"
	[[ -s "$cache_root/stock-apk-urls.txt" ]] || fail 'stock guest exposes no official APK repository URLs'
	sed "s#^$upstream#$OPENWRT_PACKAGE_MIRROR_URL#" "$stock_repositories" |
		ssh -i "$OPENWRT_SSH_KEY" -p "$OPENWRT_SSH_PORT" -o BatchMode=yes \
			-o StrictHostKeyChecking=accept-new root@"$OPENWRT_HOST" \
			'cat > /etc/apk/repositories.d/distfeeds.list'
	if [[ -f "$mirror_root/required-packages.sha256" ]] &&
		(cd "$mirror_root" && sha256sum -c required-packages.sha256 --status); then
		return 0
	fi
	while IFS= read -r url; do
		local relative="${url#"$upstream"/}"
		mkdir -p "$mirror_root/$(dirname "$relative")"
		curl --fail --location --retry 3 --output "$mirror_root/$relative" "$url"
	done <"$cache_root/stock-apk-urls.txt"
	local log_start
	log_start="$(wc -l <"$cache_root/package-mirror.log")"
	set +e
	ssh -i "$OPENWRT_SSH_KEY" -p "$OPENWRT_SSH_PORT" -o BatchMode=yes \
		-o StrictHostKeyChecking=accept-new root@"$OPENWRT_HOST" \
		'apk update; apk fetch --recursive --url luci-ssl luci-app-package-manager adblock-fast >/tmp/required-package-urls'
	local fetch_exit=$?
	set -e
	[[ "$fetch_exit" -ne 0 ]] || fail 'dependency discovery unexpectedly downloaded from the private mirror'
	tail -n "+$((log_start + 1))" "$cache_root/package-mirror.log" |
		sed -n 's|.*"GET /\([^? ]*\.apk\) HTTP.*|\1|p' | sort -u |
		sed "s#^#$upstream/#" >"$urls.filtered"
	[[ -s "$urls.filtered" ]] || fail 'guest APK solver produced no official dependency URLs'
	while IFS= read -r url; do
		local relative="${url#"$upstream"/}"
		mkdir -p "$mirror_root/$(dirname "$relative")"
		curl --fail --location --retry 3 --output "$mirror_root/$relative" "$url"
	done <"$urls.filtered"
	(
		cd "$mirror_root"
		find releases -type f \( -name '*.apk' -o -name packages.adb \) -print0 |
			sort -z | xargs -0 sha256sum >required-packages.sha256
	)
	(cd "$mirror_root" && sha256sum -c required-packages.sha256 --status) ||
		fail 'private mirror dependency cache checksum validation failed'
}

if [[ "${USE_RETAINED_PREPARED_BASELINE:-0}" != 1 ]] &&
	{ [[ ! -f "$prepared_image" ]] || ! grep -qx "artifact_sha256=$artifact_sha" "$prepared_manifest" 2>/dev/null; }; then
	rm -f "$prepared_image" "$prepared_manifest"
	qemu-img create -f qcow2 -F raw -b "$base_image" "$prepared_image" >/dev/null
	prepare_run="$cache_root/runs/prepare-$(date +%Y%m%dT%H%M%S)"
	mkdir -p "$prepare_run"
	launch_guest "$prepared_image" "$prepare_run" || fail 'baseline guest did not become SSH-ready'
	prime_package_mirror
	PREPARE_INSTALLED_BASELINE=1 scripts/integration/package-lifecycle.sh
	stop_guest
	printf 'artifact_sha256=%s\n' "$artifact_sha" >"$prepared_manifest"
fi
if [[ "${USE_RETAINED_PREPARED_BASELINE:-0}" == 1 ]]; then
	[[ -f "$prepared_image" ]] || fail 'retained prepared baseline is missing'
fi

run_dir="$cache_root/runs/lifecycle-$(date +%Y%m%dT%H%M%S)"
run_image="$run_dir/overlay.qcow2"
mkdir -p "$run_dir"
qemu-img create -f qcow2 -F qcow2 -b "$prepared_image" "$run_image" >/dev/null
launch_guest "$run_image" "$run_dir" || fail 'lifecycle guest did not become SSH-ready'
prime_package_mirror
if [[ "${STOCK_STAT_DIAGNOSTIC:-0}" == 1 ]]; then
	ssh -i "$OPENWRT_SSH_KEY" -p "$OPENWRT_SSH_PORT" -o BatchMode=yes \
		-o StrictHostKeyChecking=accept-new root@"$OPENWRT_HOST" '
			set +e
			echo "command -v stat:"; command -v stat; echo "exit=$?"
			echo "busybox:"; busybox | head -n 1; echo "exit=${PIPESTATUS:-$?}"
			echo "stat --help:"; stat --help; echo "exit=$?"
			echo "stat -c stdout/stderr/exit:"
			stat -c "%u" /var/run/adblock-fast-monitor >/tmp/abfm-stat.stdout 2>/tmp/abfm-stat.stderr
			rc=$?
			printf "stdout=<"; cat /tmp/abfm-stat.stdout; printf ">\n"
			printf "stderr=<"; cat /tmp/abfm-stat.stderr; printf ">\n"
			printf "exit=%s\n" "$rc"
			echo "/usr/bin/stat:"; ls -l /usr/bin/stat 2>&1; /usr/bin/stat -c "%u" /var/run/adblock-fast-monitor; echo "exit=$?"
		'
	exit 0
fi
if [[ "${STOCK_UCODE_PROBE:-0}" == 1 ]]; then
	ssh -i "$OPENWRT_SSH_KEY" -p "$OPENWRT_SSH_PORT" -o BatchMode=yes \
		-o StrictHostKeyChecking=accept-new root@"$OPENWRT_HOST" '
			run_probe() {
				label="$1"; shift
				printf "=== %s ===\n" "$label"
				"$@" >/tmp/abfm-probe.stdout 2>/tmp/abfm-probe.stderr
				rc=$?
				printf "stdout:\n"; cat /tmp/abfm-probe.stdout
				printf "stderr:\n"; cat /tmp/abfm-probe.stderr
				printf "exit=%s\n" "$rc"
			}
			run_probe "command -v ucode" sh -c "command -v ucode"
			run_probe "ucode -v" ucode -v
			run_probe "ucode fs exports" ucode -e "let fs = require(\"fs\"); for (let name in fs) print(name);"
			run_probe "rm -rf probe" rm -rf /tmp/abfm-ucode-probe
			run_probe "mkdir probe" mkdir -p /tmp/abfm-ucode-probe
			run_probe "touch probe file" touch /tmp/abfm-ucode-probe/file
			run_probe "chmod probe file" chmod 0644 /tmp/abfm-ucode-probe/file
			run_probe "link probe file" ln -s file /tmp/abfm-ucode-probe/link
			run_probe "ucode stat and lstat" ucode -e "let fs = require(\"fs\"); for (let path in [\"/var/run/adblock-fast-monitor\", \"/tmp/abfm-ucode-probe/file\", \"/tmp/abfm-ucode-probe/link\"]) { print(\"PATH=\" + path); for (let method in [\"stat\", \"lstat\"]) { print(\"METHOD=\" + method + \" VALUE=\" + fs[method]); let value = fs[method] ? fs[method](path) : null; if (value) for (let key in value) print(key + \"=\" + value[key]); } }"
		'
	exit 0
fi
if [[ "${PACKAGE_METADATA_DIAGNOSTIC:-0}" == 1 ]]; then
	scp -O -i "$OPENWRT_SSH_KEY" -P "$OPENWRT_SSH_PORT" -o BatchMode=yes \
		-o StrictHostKeyChecking=accept-new "$PACKAGE_IPK" \
		root@"$OPENWRT_HOST":/tmp/abfm-package.apk
	scp -O -i "$OPENWRT_SSH_KEY" -P "$OPENWRT_SSH_PORT" -o BatchMode=yes \
		-o StrictHostKeyChecking=accept-new root/test/monitoring-stock-ucode-regression.sh \
		root@"$OPENWRT_HOST":/tmp/monitoring-stock-ucode-regression.sh
	ssh -i "$OPENWRT_SSH_KEY" -p "$OPENWRT_SSH_PORT" -o BatchMode=yes \
		-o StrictHostKeyChecking=accept-new root@"$OPENWRT_HOST" '
			apk del luci-app-adblock-fast-monitor >/dev/null 2>&1 || :
			apk add --allow-untrusted /tmp/abfm-package.apk || apk info -e luci-app-adblock-fast-monitor
			run_probe() {
				label="$1"; shift
				printf "=== %s ===\n" "$label"
				"$@" >/tmp/abfm-probe.stdout 2>/tmp/abfm-probe.stderr
				rc=$?
				printf "stdout:\n"; cat /tmp/abfm-probe.stdout
				printf "stderr:\n"; cat /tmp/abfm-probe.stderr
				printf "exit=%s\n" "$rc"
			}
			run_probe "apk info -L" apk info -L luci-app-adblock-fast-monitor
			run_probe "metadata ls" ls -l /usr/libexec/adblock-fast-monitor-metadata.uc
			run_probe "metadata executable" test -x /usr/libexec/adblock-fast-monitor-metadata.uc
			run_probe "metadata usage" /usr/bin/ucode /usr/libexec/adblock-fast-monitor-metadata.uc
			run_probe "metadata directory" /usr/bin/ucode /usr/libexec/adblock-fast-monitor-metadata.uc /tmp dir 448
			run_probe "ucode argv layout" /usr/bin/ucode -e "print(\"ARGV length=\" + length(ARGV)); for (let i = 0; i < length(ARGV); i++) print(\"ARGV[\" + i + \"]=\" + ARGV[i]);" -- sentinel /tmp/adblock-fast-monitor-ucode-regression dir 448
			cat >/tmp/argv-direct.uc <<'\''EOF'\''
print("length=" + length(ARGV));
for (let i = 0; i < length(ARGV); i++) print("ARGV[" + i + "]=" + ARGV[i]);
for (let i = 0; i <= 4; i++) print("number[" + i + "]=" + (+ARGV[i]));
let path = ARGV[1]; let expected_type = ARGV[2]; let expected_mode = +ARGV[3];
print("guard=" + (!path || !expected_type || !expected_mode));
EOF
			run_probe "direct script argv" /usr/bin/ucode /tmp/argv-direct.uc /tmp/adblock-fast-monitor-ucode-regression dir 448
			cp /usr/libexec/adblock-fast-monitor-metadata.uc /tmp/abfm-metadata-instrumented.uc
			sed -i '\''/if (!path/ i\
print("instrument path=" + path + " type=" + expected_type + " mode=" + expected_mode + " guard=" + (!path || !expected_type || !expected_mode));\
'\'' /tmp/abfm-metadata-instrumented.uc
			run_probe "instrumented metadata helper" /usr/bin/ucode /tmp/abfm-metadata-instrumented.uc /tmp/adblock-fast-monitor-ucode-regression dir 448
			run_probe "metadata exact argv invocation" sh -c "/usr/bin/ucode /usr/libexec/adblock-fast-monitor-metadata.uc /tmp/adblock-fast-monitor-ucode-regression dir 448 >/tmp/abfm-helper.out 2>/tmp/abfm-helper.err; rc=\$?; printf \"rc=%s\\nstdout:\\n\" \"\$rc\"; cat /tmp/abfm-helper.out; printf \"stderr:\\n\"; cat /tmp/abfm-helper.err"
			run_probe "stock regression trace" sh -x /tmp/monitoring-stock-ucode-regression.sh
		'
	exit 0
fi
if [[ "${STOCK_METADATA_LSTAT_DIAGNOSTIC:-0}" == 1 ]]; then
	scp -O -i "$OPENWRT_SSH_KEY" -P "$OPENWRT_SSH_PORT" -o BatchMode=yes \
		-o StrictHostKeyChecking=accept-new "$PACKAGE_IPK" \
		root@"$OPENWRT_HOST":/tmp/abfm-package.apk
	ssh -i "$OPENWRT_SSH_KEY" -p "$OPENWRT_SSH_PORT" -o BatchMode=yes \
		-o StrictHostKeyChecking=accept-new root@"$OPENWRT_HOST" '
			set -eu
			apk del luci-app-adblock-fast-monitor >/dev/null 2>&1 || :
			apk add --allow-untrusted /tmp/abfm-package.apk || apk info -e luci-app-adblock-fast-monitor
			base=/tmp/adblock-fast-monitor-ucode-regression
			helper=/usr/libexec/adblock-fast-monitor-metadata.uc
			rm -rf "$base"
			printf "=== absent path ===\n"
			set +e
			/usr/bin/ucode "$helper" "$base" dir 448 >/tmp/abfm-helper.stdout 2>/tmp/abfm-helper.stderr
			rc=$?
			set -e
			printf "command=/usr/bin/ucode %s %s dir 448\n" "$helper" "$base"
			printf "stdout:\n"; cat /tmp/abfm-helper.stdout
			printf "stderr:\n"; cat /tmp/abfm-helper.stderr
			printf "rc=%s\n" "$rc"
			mkdir -m 0700 "$base"
			printf "=== created path ===\n"
			ls -ld "$base"
			cp "$helper" /tmp/abfm-metadata-lstat-instrumented.uc
			sed -i "/metadata = fs.lstat(path);/a\\
print(\"lstat-value=\" + metadata);\\
if (metadata) for (let key in metadata) print(\"lstat.\" + key + \"=\" + metadata[key]);" \
				/tmp/abfm-metadata-lstat-instrumented.uc
			sed -i "/catch (error) {/a\\
print(\"lstat-error=\" + error);" /tmp/abfm-metadata-lstat-instrumented.uc
			rm -rf "$base"
			printf "=== instrumented absent path ===\n"
			set +e
			/usr/bin/ucode /tmp/abfm-metadata-lstat-instrumented.uc "$base" dir 448 \
				>/tmp/abfm-absent.stdout 2>/tmp/abfm-absent.stderr
			rc=$?
			set -e
			printf "stdout:\n"; cat /tmp/abfm-absent.stdout
			printf "stderr:\n"; cat /tmp/abfm-absent.stderr
			printf "rc=%s\n" "$rc"
			mkdir -m 0700 "$base"
			set +e
			/usr/bin/ucode /tmp/abfm-metadata-lstat-instrumented.uc "$base" dir 448 \
				>/tmp/abfm-instrumented.stdout 2>/tmp/abfm-instrumented.stderr
			rc=$?
			set -e
			printf "command=/usr/bin/ucode /tmp/abfm-metadata-lstat-instrumented.uc %s dir 448\n" "$base"
			printf "stdout:\n"; cat /tmp/abfm-instrumented.stdout
			printf "stderr:\n"; cat /tmp/abfm-instrumented.stderr
			printf "rc=%s\n" "$rc"
			touch "$base/file"
			chmod 0600 "$base/file"
			ln -s file "$base/link"
			printf "=== regular and symlink state ===\n"
			ls -ld "$base/file" "$base/link"
			for path in "$base/file" "$base/link"; do
				printf "=== instrumented path=%s expected=file mode=384 ===\n" "$path"
				set +e
				/usr/bin/ucode /tmp/abfm-metadata-lstat-instrumented.uc "$path" file 384 \
					>/tmp/abfm-compare.stdout 2>/tmp/abfm-compare.stderr
				rc=$?
				set -e
				printf "stdout:\n"; cat /tmp/abfm-compare.stdout
				printf "stderr:\n"; cat /tmp/abfm-compare.stderr
				printf "rc=%s\n" "$rc"
			done
		'
	exit 0
fi
if [[ "${STOCK_RING_DIAGNOSTIC:-0}" == 1 ]]; then
	scp -O -i "$OPENWRT_SSH_KEY" -P "$OPENWRT_SSH_PORT" -o BatchMode=yes \
		-o StrictHostKeyChecking=accept-new "$PACKAGE_IPK" root@"$OPENWRT_HOST":/tmp/abfm-package.apk
	ssh -i "$OPENWRT_SSH_KEY" -p "$OPENWRT_SSH_PORT" -o BatchMode=yes \
		-o StrictHostKeyChecking=accept-new root@"$OPENWRT_HOST" '
			set -eu
			apk del luci-app-adblock-fast-monitor >/dev/null 2>&1 || :
			apk add --allow-untrusted /tmp/abfm-package.apk || apk info -e luci-app-adblock-fast-monitor
			base=/tmp/abfm-ring-direct
			rm -rf "$base"; mkdir -m 0700 "$base"
			: >"$base/activity.tsv"; printf "state=running\nlost=0\ngeneration=0\n" >"$base/status"
			printf "0\n" >"$base/generation"; : >"$base/monitor.lock"
			chmod 0600 "$base/activity.tsv" "$base/status" "$base/generation" "$base/monitor.lock"
			echo "command=/usr/bin/ucode /usr/libexec/adblock-fast-monitor-ring.uc $base 32"
			/usr/bin/ucode /usr/libexec/adblock-fast-monitor-ring.uc "$base" 32 >/tmp/abfm-ring.stdout 2>/tmp/abfm-ring.stderr &
			pid=$!; echo "pid=$pid"; ps w | grep "[ ]$pid " || :; sleep 1
			logger -t dnsmasq "reply stock-ring-diagnostic.example.test is 192.0.2.1"
			uci set dhcp.@dnsmasq[0].logqueries="1"
			uci add_list dhcp.@dnsmasq[0].address="/abfm-ring.test/192.0.2.1"
			uci commit dhcp; /etc/init.d/dnsmasq restart; sleep 2
			echo "dnsmasq-status:"; /etc/init.d/dnsmasq status || :
			echo "dnsmasq-process:"; ps w | grep "[d]nsmasq" || :
			echo "dnsmasq-uci:"; uci show dhcp | grep -E "dnsmasq|logqueries|address|interface|listen|port|bind" || :
			echo "dnsmasq-generated-config:"; cat /var/etc/dnsmasq.conf.* 2>/dev/null || :
			echo "dnsmasq-ubus:"; ubus call service list "{\"name\":\"dnsmasq\"}" || :
			echo "logd-ubus:"; ubus call service list "{\"name\":\"log\"}" || :
			echo "listeners:"; netstat -ln 2>/dev/null || ss -ln 2>/dev/null || :
			nslookup abfm-ring.test 127.0.0.1 >/tmp/abfm-nslookup.stdout 2>/tmp/abfm-nslookup.stderr || :
			echo "nslookup stdout:"; cat /tmp/abfm-nslookup.stdout
			echo "nslookup stderr:"; cat /tmp/abfm-nslookup.stderr
			echo "raw-logread:"; /sbin/logread | grep -E "stock-ring-diagnostic|abfm-ring.test|dnsmasq" || :
			for poll in 1 2 3 4 5; do
				echo "poll=$poll"; ls -l "$base"/*; cat "$base/activity.tsv" "$base/status" "$base/generation"; sleep 1
			done
			if kill -0 "$pid" 2>/dev/null; then
				echo "process=alive"; kill "$pid"; wait "$pid" || :
			else
				set +e; wait "$pid"; rc=$?; set -e; printf "rc=%s\n" "$rc"
			fi
			echo "stdout:"; cat /tmp/abfm-ring.stdout
			echo "stderr:"; cat /tmp/abfm-ring.stderr
			echo "logread:"; logread -e adblock-fast-monitor || :
			probe() {
				label="$1"; shift
				echo "=== $label ==="
				"$@" >/tmp/abfm-ring-probe.stdout 2>/tmp/abfm-ring-probe.stderr
				rc=$?
				echo "stdout:"; cat /tmp/abfm-ring-probe.stdout
				echo "stderr:"; cat /tmp/abfm-ring-probe.stderr
				echo "rc=$rc"
			}
			set +e
			probe "ucode version" /usr/bin/ucode -v
			probe "ucode package" apk info ucode
			probe "fs exports" /usr/bin/ucode -e "let fs = require(\"fs\"); for (let name in fs) print(name);"
			probe "uloop availability" /usr/bin/ucode -e "let uloop = require(\"uloop\"); for (let name in uloop) print(name);"
			probe "ubus availability" /usr/bin/ucode -e "let ubus = require(\"ubus\"); for (let name in ubus) print(name);"
			probe "logread binary" sh -c "command -v logread; /sbin/logread | tail -n 5"
			set -e
		'
	exit 0
fi
if [[ "${STOCK_RUNTIME_CONTRACT_DIAGNOSTIC:-0}" == 1 ]]; then
	ssh -i "$OPENWRT_SSH_KEY" -p "$OPENWRT_SSH_PORT" -o BatchMode=yes \
		-o StrictHostKeyChecking=accept-new root@"$OPENWRT_HOST" '
			set +e
			echo "=== dnsmasq service filtered ==="; ubus call service list "{\"name\":\"dnsmasq\"}"; echo "rc=$?"
			echo "=== service list unfiltered ==="; ubus call service list; echo "rc=$?"
			echo "=== ubus service APIs ==="; ubus list service; ubus -v list service; echo "rc=$?"
			cat >/tmp/uloop-contract.uc <<'\''EOF'\''
let uloop = require("uloop");
for (let key in uloop) print("export=" + key + " type=" + type(uloop[key]));
EOF
			echo "=== uloop task probe ==="
			/usr/bin/ucode /tmp/uloop-contract.uc >/tmp/uloop.stdout 2>/tmp/uloop.stderr
			rc=$?; echo "stdout:"; cat /tmp/uloop.stdout; echo "stderr:"; cat /tmp/uloop.stderr; echo "rc=$rc"
			cat >/tmp/uloop-handle.uc <<'\''EOF'\''
let fs = require("fs"), uloop = require("uloop");
let stream = fs.popen("/sbin/logread -f", "r");
print("stream=" + stream + " type=" + type(stream));
let fired = false;
uloop.timer(1500, function() { fired = true; print("timer-fired"); uloop.end(); });
try {
	let h = uloop.handle(stream, uloop.ULOOP_READ, function(fd, flags) {
		print("callback fd=" + fd + " flags=" + flags);
		let line = stream.read("line"); print("line=" + line);
		uloop.end();
	});
	print("handle=" + h);
} catch (e) { print("handle-error=" + e); }
uloop.run();
print("done fired=" + fired);
EOF
			logger -t abfm-uloop-contract "owned-stream-line"
			echo "=== uloop handle probe ==="
			/usr/bin/ucode /tmp/uloop-handle.uc >/tmp/uloop-handle.stdout 2>/tmp/uloop-handle.stderr
			rc=$?; echo "stdout:"; cat /tmp/uloop-handle.stdout; echo "stderr:"; cat /tmp/uloop-handle.stderr; echo "rc=$rc"
		'
	exit 0
fi

scripts/integration/package-lifecycle.sh
PERFORMANCE_REQUIRE_MEASURED=1 npm run test:performance
