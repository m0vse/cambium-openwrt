include $(TOPDIR)/rules.mk

PKG_NAME:=cambium-sage-support
PKG_RELEASE:=3
PKG_LICENSE:=GPL-2.0-only
PKG_MAINTAINER:=Phil Taylor <phil@m0vse.uk>

include $(INCLUDE_DIR)/package.mk

define Package/cambium-sage-support
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Cambium Sage family access point support
  DEPENDS:=@TARGET_ipq40xx +uboot-envtools +curl +jsonfilter +cambium-openwisp-led
  PKGARCH:=all
endef

define Package/cambium-sage-support/description
  Guarded A/B upgrade commit, OEM migration helpers and management VLAN
  defaults for Cambium Sage (E410 family) access points.
endef

define Build/Compile
endef

define Package/cambium-sage-support/install
	$(INSTALL_DIR) $(1)/usr/sbin $(1)/etc/init.d $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/sage-sysupgrade-mark-good \
		./files/sage-migration-mark-good ./files/sage-migration-rollback-oem $(1)/usr/sbin/
	$(INSTALL_BIN) ./files/sage-sysupgrade-mark-good.init $(1)/etc/init.d/sage-sysupgrade-mark-good
	$(INSTALL_DATA) ./files/96-sage-vlan-management ./files/99-sage-defaults $(1)/etc/uci-defaults/
endef

$(eval $(call BuildPackage,cambium-sage-support))
