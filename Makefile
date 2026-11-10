# SPDX-License-Identifier: Apache-2.0
include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-adblock-fast-monitor
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=AdBlock Fast Monitor contributors

include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=Bounded privacy-preserving monitor for adblock-fast
  PKGARCH:=all
  DEPENDS:=+luci-base +adblock-fast +rpcd +jsonfilter +ucode +ucode-mod-io +ucode-mod-uloop
endef

define Package/$(PKG_NAME)/description
Standalone LuCI dashboard and bounded RAM-only DNS activity monitor for
adblock-fast. Monitoring is opt-in and does not change adblock-fast lists.
endef

define Package/$(PKG_NAME)/conffiles
/etc/config/adblock-fast-monitor
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)
	$(CP) ./root/. $(1)/
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || /etc/init.d/adblock-fast-monitor enable
exit 0
endef

define Package/$(PKG_NAME)/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || /etc/init.d/adblock-fast-monitor stop
exit 0
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
