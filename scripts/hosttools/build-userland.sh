#!/bin/sh
# Builds a minimal OpenWrt-25.12-like userland into $ROOTFS: BusyBox with
# OpenWrt's default applet set and patches, ucode (+ OpenWrt patches) with the
# fs/io/uloop/ubus/uci/struct/... modules, libubox (jshn), ubus, uci and
# jsonfilter, all at the commits OpenWrt v25.12.6 pins. Runs inside the Alpine
# (musl) build stage of scripts/hosttools/Dockerfile.
set -eu

. /build/pins.env
ROOTFS=${ROOTFS:-/rootfs}
SRC=/build/src
JOBS=$(nproc)
OPENWRT_RAW="https://raw.githubusercontent.com/openwrt/openwrt/$OPENWRT_COMMIT"

fetch() { curl --fail --silent --show-error --location --retry 3 --output "$2" "$1"; }
fetch_github() { # owner/repo commit dir
	mkdir -p "$3"
	fetch "https://codeload.github.com/$1/tar.gz/$2" "$3.tar.gz"
	tar -xzf "$3.tar.gz" -C "$3" --strip-components=1
}
cmake_build() { # srcdir [cmake args...]
	dir=$1; shift
	# In-source: jsonpath builds contrib/lemon relative to the build directory.
	(cd "$dir" && cmake . -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=Release "$@" >/dev/null)
	make -C "$dir" -j"$JOBS" >/dev/null
	make -C "$dir" install >/dev/null
	DESTDIR="$ROOTFS" make -C "$dir" install >/dev/null
}

mkdir -p "$SRC" "$ROOTFS"

# --- libubox, ubus, uci, jsonfilter ----------------------------------------
fetch_github openwrt/libubox "$LIBUBOX_COMMIT" "$SRC/libubox"
cmake_build "$SRC/libubox" -DBUILD_LUA=OFF -DBUILD_EXAMPLES=OFF
fetch_github openwrt/ubus "$UBUS_COMMIT" "$SRC/ubus"
cmake_build "$SRC/ubus" -DBUILD_LUA=OFF -DBUILD_EXAMPLES=OFF
fetch_github openwrt/uci "$UCI_COMMIT" "$SRC/uci"
cmake_build "$SRC/uci" -DBUILD_LUA=OFF
fetch_github openwrt/jsonpath "$JSONPATH_COMMIT" "$SRC/jsonpath"
cmake_build "$SRC/jsonpath"

# --- ucode at the OpenWrt pin, with OpenWrt's patches -----------------------
fetch_github jow-/ucode "$UCODE_COMMIT" "$SRC/ucode"
for patch in $UCODE_PATCHES; do
	fetch "$OPENWRT_RAW/package/utils/ucode/patches/$patch" "$SRC/$patch"
	patch -d "$SRC/ucode" -p1 --quiet <"$SRC/$patch"
done
cmake_build "$SRC/ucode" -DSOVERSION="$UCODE_ABI_VERSION" \
	-DFS_SUPPORT=ON -DIO_SUPPORT=ON -DMATH_SUPPORT=ON -DSTRUCT_SUPPORT=ON \
	-DULOOP_SUPPORT=ON -DUBUS_SUPPORT=ON -DUCI_SUPPORT=ON -DLOG_SUPPORT=ON \
	-DDEBUG_SUPPORT=ON -DRESOLV_SUPPORT=ON -DSOCKET_SUPPORT=ON \
	-DZLIB_SUPPORT=ON -DDIGEST_SUPPORT=ON \
	-DNL80211_SUPPORT=OFF -DRTNL_SUPPORT=OFF

# --- BusyBox with OpenWrt's patches and default applet set -------------------
fetch "https://busybox.net/downloads/busybox-$BUSYBOX_VERSION.tar.bz2" "$SRC/busybox.tar.bz2" ||
	fetch "https://sources.openwrt.org/busybox-$BUSYBOX_VERSION.tar.bz2" "$SRC/busybox.tar.bz2"
printf '%s  %s\n' "$BUSYBOX_SHA256" "$SRC/busybox.tar.bz2" | sha256sum -c - >/dev/null
mkdir -p "$SRC/busybox"
tar -xjf "$SRC/busybox.tar.bz2" -C "$SRC/busybox" --strip-components=1
for patch in $BUSYBOX_PATCHES; do
	fetch "$OPENWRT_RAW/package/utils/busybox/patches/$patch" "$SRC/$patch"
	patch -d "$SRC/busybox" -p1 --quiet <"$SRC/$patch"
done
fetch "$OPENWRT_RAW/package/utils/busybox/Config-defaults.in" "$SRC/Config-defaults.in"
awk -f /build/busybox-defaults.awk "$SRC/Config-defaults.in" >"$SRC/busybox/.config"
yes n | make -C "$SRC/busybox" oldconfig >/dev/null
make -C "$SRC/busybox" -j"$JOBS" busybox busybox.links >/dev/null
install -D -m 0755 "$SRC/busybox/busybox" "$ROOTFS/bin/busybox"
while read -r link; do
	mkdir -p "$ROOTFS$(dirname "$link")"
	ln -sf /bin/busybox "$ROOTFS$link"
done <"$SRC/busybox/busybox.links"
install -D -m 0644 "$SRC/busybox/.config" "$ROOTFS/usr/share/abfm/busybox.config"
sed -n 's#.*/##p' "$SRC/busybox/busybox.links" | sort >"$ROOTFS/usr/share/abfm/busybox.applets"

# --- OpenWrt filesystem layout ----------------------------------------------
mv "$ROOTFS/usr/bin/jsonpath" "$ROOTFS/usr/bin/jsonfilter"
mkdir -p "$ROOTFS/sbin"
mv "$ROOTFS/usr/bin/uci" "$ROOTFS/sbin/uci"
mv "$ROOTFS/usr/bin/ubus" "$ROOTFS/bin/ubus"
mv "$ROOTFS/usr/sbin/ubusd" "$ROOTFS/sbin/ubusd"
rm -rf "$ROOTFS/usr/include" "$ROOTFS/usr/lib/pkgconfig" "$ROOTFS/usr/share/lua" "$ROOTFS"/usr/lib/*.a
mkdir -p "$ROOTFS/etc/config" "$ROOTFS/tmp" "$ROOTFS/root" "$ROOTFS/dev" "$ROOTFS/proc"
chmod 1777 "$ROOTFS/tmp"
ln -sfn tmp "$ROOTFS/var"
printf 'root:x:0:0:root:/root:/bin/ash\nnobody:*:65534:65534:nobody:/var:/bin/false\n' >"$ROOTFS/etc/passwd"
printf 'root:x:0:\nnogroup:x:65534:\n' >"$ROOTFS/etc/group"
printf 'OPENWRT_RELEASE=%s\nUCODE_COMMIT=%s\nBUSYBOX_VERSION=%s\n' \
	"$OPENWRT_RELEASE" "$UCODE_COMMIT" "$BUSYBOX_VERSION" >"$ROOTFS/usr/share/abfm/userland.env"

# --- shared libraries (musl loader, json-c, zlib, libmd) ---------------------
find "$ROOTFS" -type f \( -perm -0100 -o -name '*.so*' \) | while read -r file; do
	ldd "$file" 2>/dev/null | awk '/=>/ { print $3 } /ld-musl/ { print $1 }'
done | sort -u | while read -r lib; do
	[ -f "$lib" ] || continue
	case "$lib" in /usr/lib/libubox*|/usr/lib/libubus*|/usr/lib/libuci*|/usr/lib/libucode*|/usr/lib/libblobmsg*|/usr/lib/libjson_script*) continue ;; esac
	mkdir -p "$ROOTFS$(dirname "$lib")"
	cp -L "$lib" "$ROOTFS$lib"
done
