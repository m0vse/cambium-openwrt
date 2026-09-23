include $(TOPDIR)/rules.mk

PKG_NAME:=cambium-jaguar-support
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-only
PKG_MAINTAINER:=Phil Taylor <phil@m0vse.uk>

include $(INCLUDE_DIR)/package.mk

define Package/cambium-jaguar-support
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Cambium Jaguar family access point support
  DEPENDS:=@TARGET_qualcommax_ipq60xx +uboot-envtools
  PKGARCH:=all
endef

define Package/cambium-jaguar-support/description
  Guarded OEM-fallback boot for Cambium Jaguar (XV2-2 / XE3-4 family)
  access points.
endef

define Build/Compile
endef

define Package/cambium-jaguar-support/install
	$(INSTALL_DIR) $(1)/usr/sbin $(1)/etc/init.d $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/jaguar-bootguard $(1)/usr/sbin/
	$(INSTALL_BIN) ./files/jaguar-bootguard.init $(1)/etc/init.d/jaguar-bootguard
	$(INSTALL_BIN) ./files/18_jaguar_bootguard $(1)/etc/uci-defaults/
endef

$(eval $(call BuildPackage,cambium-jaguar-support))
