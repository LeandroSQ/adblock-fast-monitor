# SPDX-License-Identifier: Apache-2.0
#
# Out-of-tree LuCI application. Build it in an OpenWrt 25.12 SDK or buildroot
# with the luci feed installed (./scripts/feeds update -a && ./scripts/feeds install -a):
#   cp -r . <sdk>/package/luci-app-adblock-fast-monitor
#   make -C <sdk> package/luci-app-adblock-fast-monitor/compile
# luci.mk installs the whole root/ tree and builds a
# luci-i18n-adblock-fast-monitor-<lang> package for every po/<lang>/.

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-adblock-fast-monitor
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=AdBlock Fast Monitor contributors

LUCI_TITLE:=Dashboard and domain actions for adblock-fast
LUCI_DESCRIPTION:=Standalone LuCI dashboard for adblock-fast: an opt-in, \
	bounded, RAM-only DNS activity monitor and staged block/allow actions \
	applied in one job.
LUCI_DEPENDS:=+luci-base +adblock-fast +ucode-mod-uloop +ucode-mod-io +ucode-mod-resolv
LUCI_PKGARCH:=all
LUCI_URL:=https://github.com/LeandroSQ/adblock-fast-monitor
LUCI_MAINTAINER:=$(PKG_MAINTAINER)

# Modes come from here, not from git: 0755 for init scripts and everything
# under /usr/libexec, 0644 for all other files (rpcd skips a world-writable
# ucode plugin). Runs on the copy luci.mk installs with cp -p.
define Build/Prepare/$(PKG_NAME)
	find $(PKG_BUILD_DIR)/root -type d -exec chmod 0755 {} +
	find $(PKG_BUILD_DIR)/root -type f -exec chmod 0644 {} +
	for d in $(PKG_BUILD_DIR)/root/etc/init.d $(PKG_BUILD_DIR)/root/usr/libexec; do \
		[ ! -d "$$$$d" ] || find "$$$$d" -type f -exec chmod 0755 {} +; \
	done
endef

define Package/$(PKG_NAME)/conffiles
/etc/config/adblock-fast-monitor
endef

# The SDK's generated scripts call default_postinst (enable + start
# /etc/init.d/adblock-fast-monitor) and default_prerm (disable + stop; stop
# removes the dnsmasq drop-ins), so no prerm is needed. On top of that,
# install and removal both do what luci.mk's postinst does, so the rpcd
# plugin, ACL and menu appear and disappear without a manual rpcd restart.
# On upgrade default_postinst only runs "start", which procd ignores for an
# unchanged instance, so the old daemon code would keep running: restart it
# (restart keeps the drop-ins, so dnsmasq is not restarted).
define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	/etc/init.d/rpcd reload 2>/dev/null
	[ "$${PKG_UPGRADE}" != 1 ] || /etc/init.d/adblock-fast-monitor restart 2>/dev/null
}
exit 0
endef

define Package/$(PKG_NAME)/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	/etc/init.d/rpcd reload 2>/dev/null
}
exit 0
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
