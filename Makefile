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
	$(INSTALL_DIR) $(1)/etc/config $(1)/etc/init.d $(1)/usr/libexec/rpcd $(1)/usr/libexec $(1)/usr/lib/adblock-fast-monitor
	$(INSTALL_CONF) ./root/etc/config/adblock-fast-monitor $(1)/etc/config/adblock-fast-monitor
	$(INSTALL_BIN) ./root/etc/init.d/adblock-fast-monitor $(1)/etc/init.d/adblock-fast-monitor
	$(INSTALL_BIN) ./root/usr/libexec/adblock-fast-monitor-collector $(1)/usr/libexec/adblock-fast-monitor-collector
	$(INSTALL_BIN) ./root/usr/libexec/adblock-fast-monitor-job $(1)/usr/libexec/adblock-fast-monitor-job
	$(INSTALL_BIN) ./root/usr/libexec/adblock-fast-monitor-metadata.uc $(1)/usr/libexec/adblock-fast-monitor-metadata.uc
	$(INSTALL_BIN) ./root/usr/libexec/adblock-fast-monitor-ring.uc $(1)/usr/libexec/adblock-fast-monitor-ring.uc
	$(INSTALL_BIN) ./root/usr/libexec/rpcd/adblock-fast-monitor $(1)/usr/libexec/rpcd/adblock-fast-monitor
	$(INSTALL_BIN) ./root/usr/libexec/rpcd/adblock-fast-monitor-actions $(1)/usr/libexec/rpcd/adblock-fast-monitor-actions
	$(INSTALL_DATA) ./root/usr/lib/adblock-fast-monitor/common.sh $(1)/usr/lib/adblock-fast-monitor/common.sh
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d $(1)/usr/share/luci/menu.d $(1)/www/luci-static/resources/view/adblock-fast-monitor $(1)/www/luci-static/resources/adblock-fast-monitor
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-adblock-fast-monitor.json $(1)/usr/share/rpcd/acl.d/luci-app-adblock-fast-monitor.json
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-app-adblock-fast-monitor.json $(1)/usr/share/luci/menu.d/luci-app-adblock-fast-monitor.json
	$(INSTALL_DATA) ./root/www/luci-static/resources/view/adblock-fast-monitor/overview.js $(1)/www/luci-static/resources/view/adblock-fast-monitor/overview.js
	$(INSTALL_DATA) ./root/www/luci-static/resources/view/adblock-fast-monitor/settings.js $(1)/www/luci-static/resources/view/adblock-fast-monitor/settings.js
	$(INSTALL_DATA) ./root/www/luci-static/resources/adblock-fast-monitor/model.js $(1)/www/luci-static/resources/adblock-fast-monitor/model.js
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
