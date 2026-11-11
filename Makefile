# SPDX-License-Identifier: Apache-2.0
#
# Out-of-tree LuCI application. Build it in an OpenWrt 25.12 SDK or buildroot
# with the luci feed installed (./scripts/feeds update -a && ./scripts/feeds install -a):
#   cp -r . <sdk>/package/luci-app-adblock-fast-monitor
#   make -C <sdk> package/luci-app-adblock-fast-monitor/compile
# luci.mk installs the whole root/ tree, copies htdocs/ to /www (minifying
# the JavaScript) and builds a
# luci-i18n-adblock-fast-monitor-<lang> package for every po/<lang>/.

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-adblock-fast-monitor
PKG_VERSION:=0.2.0
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=Leandro Quaresma <11012599+LeandroSQ@users.noreply.github.com>

# luci.mk derives the package name from the directory name unless this is
# set; the build directory may be named differently.
LUCI_NAME:=$(PKG_NAME)

LUCI_TITLE:=Dashboard and domain actions for adblock-fast
LUCI_DESCRIPTION:=Standalone LuCI dashboard for adblock-fast: recent DNS \
	queries read from the system log in the browser (no resident process) \
	and staged block/allow actions applied in one job. Grant it to admins \
	only: viewers can read the whole system log.
LUCI_DEPENDS:=+luci-base +adblock-fast +ucode-mod-io +ucode-mod-resolv
LUCI_PKGARCH:=all
LUCI_URL:=https://github.com/LeandroSQ/adblock-fast-monitor
LUCI_MAINTAINER:=$(PKG_MAINTAINER)

# Modes come from here, not from git: 0755 for init scripts and everything
# under /usr/libexec, 0644 for all other files (rpcd skips a world-writable
# ucode plugin). Runs on the copy luci.mk installs with cp -p.
define Build/Prepare/$(PKG_NAME)
	find $(PKG_BUILD_DIR)/root $(PKG_BUILD_DIR)/htdocs -type d -exec chmod 0755 {} +
	find $(PKG_BUILD_DIR)/root $(PKG_BUILD_DIR)/htdocs -type f -exec chmod 0644 {} +
	for d in $(PKG_BUILD_DIR)/root/etc/init.d $(PKG_BUILD_DIR)/root/usr/libexec; do \
		[ ! -d "$$$$d" ] || find "$$$$d" -type f -exec chmod 0755 {} +; \
	done
endef

define Package/$(PKG_NAME)/conffiles
/etc/config/adblock-fast-monitor
endef

# The SDK's generated scripts call default_postinst (enable on install, then
# start /etc/init.d/adblock-fast-monitor, which reconciles the drop-ins and
# re-registers the procd triggers) and default_prerm (disable + stop on
# removal; stop removes the dnsmasq drop-ins). On top of that, install and
# removal both do what luci.mk's postinst does, so the rpcd plugin, ACL and
# menu appear and disappear without a manual rpcd restart. Removal also
# drops the runtime state (tmpfs): the last job, the private UCI savedir and
# the lock files.
define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	/etc/init.d/rpcd reload 2>/dev/null
}
exit 0
endef

define Package/$(PKG_NAME)/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	/etc/init.d/rpcd reload 2>/dev/null
	[ "$${PKG_UPGRADE}" = 1 ] || rm -rf /var/run/adblock-fast-monitor /var/lock/adblock-fast-monitor.*lock
}
exit 0
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
