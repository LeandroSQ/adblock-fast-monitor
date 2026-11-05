#!/usr/bin/env bash
set -euo pipefail

fail() { printf 'OpenWrt QEMU test: %s\n' "$*" >&2; exit 1; }

readonly OPENWRT_IMAGE_URL='https://downloads.openwrt.org/releases/25.12.6/targets/x86/64/openwrt-25.12.6-x86-64-generic-ext4-combined.img.gz'
readonly OPENWRT_IMAGE_SHA256='f8538784d0288b4133a99ac2a68443e4922ffde6343e80df56a5882364b9d499'

[[ "$(uname -s)" == Linux ]] || fail 'QEMU integration requires Linux.'
for command in qemu-system-x86_64 guestfish ssh scp ssh-keygen openssl python3 dig curl gzip; do
	command -v "$command" >/dev/null || fail "missing host prerequisite: $command"
done
: "${PACKAGE_IPK:?Set PACKAGE_IPK to the built APK.}"
[[ -f "$PACKAGE_IPK" ]] || fail "package not found: $PACKAGE_IPK"

workdir=.ci-work/qemu
rm -rf "$workdir"
mkdir -p "$workdir"
curl --fail --location --retry 3 --output "$workdir/openwrt.img.gz" "$OPENWRT_IMAGE_URL"
printf '%s  %s\n' "$OPENWRT_IMAGE_SHA256" "$workdir/openwrt.img.gz" | sha256sum --check
gzip -dc "$workdir/openwrt.img.gz" > "$workdir/openwrt.img"

ssh-keygen -q -t ed25519 -N '' -f "$workdir/id_ed25519"
root_password="$(openssl rand -hex 18)"
root_hash="$(openssl passwd -6 "$root_password")"
readonly_password="$(openssl rand -hex 18)"
readonly_hash="$(openssl passwd -6 "$readonly_password")"
guestfish --ro --format=raw -a "$workdir/openwrt.img" <<<'run
list-filesystems' > "$workdir/filesystems"
root_device="$(awk '$2 == "ext4" { sub(/:$/, "", $1); print $1; exit }' "$workdir/filesystems")"
[[ -n "$root_device" ]] || fail 'could not find the ext4 root filesystem in the verified image'

guestfish --ro --format=raw -a "$workdir/openwrt.img" <<EOF
run
mount $root_device /
download /etc/shadow $workdir/shadow
EOF
python3 - "$workdir/shadow" "$root_hash" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
lines = path.read_text().splitlines()
lines = [f"root:{sys.argv[2]}:0:0:99999:7:::" if line.startswith("root:") else line for line in lines]
path.write_text("\n".join(lines) + "\n")
PY
guestfish --ro --format=raw -a "$workdir/openwrt.img" <<EOF
run
mount $root_device /
download /etc/passwd $workdir/passwd
download /etc/group $workdir/group
download /etc/config/rpcd $workdir/rpcd
EOF
python3 - "$workdir/passwd" "$workdir/group" "$workdir/shadow" "$workdir/rpcd" "$readonly_hash" <<'PY'
from pathlib import Path
import sys
passwd, group, shadow, rpcd, password_hash = map(Path, sys.argv[1:5])
if not any(line.startswith('monitor-readonly:') for line in passwd.read_text().splitlines()):
    passwd.write_text(passwd.read_text().rstrip() + '\nmonitor-readonly:x:1001:65534:QEMU read-only test principal:/var/empty:/bin/false\n')
    shadow.write_text(shadow.read_text().rstrip() + f'\nmonitor-readonly:{sys.argv[5]}:0:0:99999:7:::\n')
if not any(line.startswith('nogroup:') for line in group.read_text().splitlines()):
    group.write_text(group.read_text().rstrip() + '\nnogroup:x:65534:\n')
rpcd.write_text(rpcd.read_text().rstrip() + '''

config login 'monitor_readonly_qemu'
\toption username 'monitor-readonly'
\toption password '$p$monitor-readonly'
\tlist read 'luci-app-adblock-fast-monitor'
''')
PY
cat > "$workdir/network" <<'EOF'
config interface 'loopback'
	option device 'lo'
	option proto 'static'
	option ipaddr '127.0.0.1'
	option netmask '255.0.0.0'

config device
	option name 'br-lan'
	option type 'bridge'
	list ports 'eth0'

config interface 'lan'
	option device 'br-lan'
	option proto 'dhcp'
EOF
guestfish --rw --format=raw -a "$workdir/openwrt.img" <<EOF
run
mount $root_device /
mkdir-p /etc/dropbear
upload $workdir/id_ed25519.pub /etc/dropbear/authorized_keys
chmod 0600 /etc/dropbear/authorized_keys
upload $workdir/shadow /etc/shadow
upload $workdir/passwd /etc/passwd
upload $workdir/group /etc/group
upload $workdir/rpcd /etc/config/rpcd
upload $workdir/network /etc/config/network
EOF

accel='tcg'
qemu_accel=(-accel tcg,thread=multi)
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
	accel='kvm'
	qemu_accel=(-enable-kvm -cpu host)
fi

python3 -m http.server 18080 --bind 0.0.0.0 --directory test/fixtures/lists >"$workdir/list-server.log" 2>&1 &
list_server_pid=$!
qemu-system-x86_64 \
	"${qemu_accel[@]}" -m 512M -nographic \
	-drive "file=$workdir/openwrt.img,format=raw,if=virtio" \
	-netdev user,id=net0,hostfwd=tcp::2222-:22,hostfwd=tcp::8080-:80,hostfwd=udp::5353-:53 \
	-device virtio-net-pci,netdev=net0 >"$workdir/serial.log" 2>&1 &
qemu_pid=$!
trap 'kill "$qemu_pid" "$list_server_pid" 2>/dev/null || true' EXIT

for _ in $(seq 1 90); do
	if ssh -i "$workdir/id_ed25519" -o BatchMode=yes -o ConnectTimeout=2 -o StrictHostKeyChecking=accept-new -p 2222 root@127.0.0.1 true 2>/dev/null; then
		export OPENWRT_HOST=127.0.0.1 OPENWRT_SSH_PORT=2222 OPENWRT_SSH_KEY="$PWD/$workdir/id_ed25519"
		export OPENWRT_LUCI_BASE_URL=http://127.0.0.1:8080
		export MONITOR_WRITE_LUCI_USERNAME=root MONITOR_WRITE_LUCI_PASSWORD="$root_password"
		export MONITOR_READONLY_LUCI_USERNAME=monitor-readonly MONITOR_READONLY_LUCI_PASSWORD="$readonly_password"
		export OPENWRT_RUNTIME_TEST="$PWD/scripts/integration/runtime-dns-lifecycle.sh"
		export FIXTURE_LIST_URL=http://10.0.2.2:18080 QEMU_ACCELERATION="$accel"
		scripts/integration/package-lifecycle.sh
		PERFORMANCE_REQUIRE_MEASURED=1 npm run test:performance
		exit 0
	fi
	sleep 2
done
tail -n 100 "$workdir/serial.log" >&2 || true
fail 'guest did not become SSH-ready'
