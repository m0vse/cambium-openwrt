include $(TOPDIR)/rules.mk

PKG_NAME:=cambium-sage-support
PKG_RELEASE:=6
PKG_LICENSE:=GPL-2.0-only
PKG_MAINTAINER:=Phil Taylor <phil@m0vse.uk>

include $(INCLUDE_DIR)/package.mk

define Package/cambium-sage-support
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Cambium Sage family access point support
  DEPENDS:=@TARGET_ipq40xx +uboot-envtools +curl +jsonfilter +cambium-ab +cambium-openwisp-led +cambium-rrm-agent
  PKGARCH:=all
endef

define Package/cambium-sage-support/description
  The Sage (E410 family) module for cambium-ab (volume-pair layout, U-Boot
  boot commands and the adoption of the earlier Sage A/B state), OEM
  migration helpers and management VLAN defaults for Cambium Sage access
  points.
endef

define Build/Compile
endef

define Package/cambium-sage-support/install
	$(INSTALL_DIR) $(1)/usr/sbin $(1)/etc/uci-defaults $(1)/lib/functions
	$(INSTALL_BIN) ./files/sage-migration-mark-good ./files/sage-migration-rollback-oem $(1)/usr/sbin/
	$(INSTALL_DATA) ./files/cambium-ab-sage.sh $(1)/lib/functions/cambium-ab-sage.sh
	$(INSTALL_DATA) ./files/96-sage-vlan-management $(1)/etc/uci-defaults/
endef

$(eval $(call BuildPackage,cambium-sage-support))
