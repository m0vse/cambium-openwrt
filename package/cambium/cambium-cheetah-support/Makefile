include $(TOPDIR)/rules.mk

PKG_NAME:=cambium-cheetah-support
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-only
PKG_MAINTAINER:=Phil Taylor <phil@m0vse.uk>

include $(INCLUDE_DIR)/package.mk

define Package/cambium-cheetah-support
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Cambium Cheetah family access point support
  DEPENDS:=@TARGET_qualcommax_ipq50xx +uboot-envtools +curl
  PKGARCH:=all
endef

define Package/cambium-cheetah-support/description
  Guarded OEM-fallback boot, OpenWISP status LED and management bridge
  defaults for Cambium Cheetah (XV2-2x) access points.
endef

define Build/Compile
endef

define Package/cambium-cheetah-support/install
	$(INSTALL_DIR) $(1)/usr/sbin $(1)/etc/init.d $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/cheetah-openwisp-led ./files/cheetah-bootguard $(1)/usr/sbin/
	$(INSTALL_BIN) ./files/cheetah-openwisp-led.init $(1)/etc/init.d/cheetah-openwisp-led
	$(INSTALL_BIN) ./files/cheetah-bootguard.init $(1)/etc/init.d/cheetah-bootguard
	$(INSTALL_BIN) ./files/14_cheetah_openwisp_led ./files/17_cheetah_bridge_section \
		./files/18_cheetah_bootguard $(1)/etc/uci-defaults/
endef

$(eval $(call BuildPackage,cambium-cheetah-support))
