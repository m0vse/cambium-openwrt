include $(TOPDIR)/rules.mk

PKG_NAME:=cambium-thor-support
PKG_RELEASE:=2
PKG_LICENSE:=GPL-2.0-only
PKG_MAINTAINER:=Phil Taylor <phil@m0vse.uk>

include $(INCLUDE_DIR)/package.mk

define Package/cambium-thor-support
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Cambium Thor family access point support
  DEPENDS:=@TARGET_qualcommax_ipq807x +uboot-envtools +curl +cambium-openwisp-led
  PKGARCH:=all
endef

define Package/cambium-thor-support/description
  Radio topology settings and management bridge defaults
  for Cambium Thor (XV3-8 family) access points.
endef

define Package/cambium-thor-support/conffiles
/etc/config/xv3_8_radio
endef

define Build/Compile
endef

define Package/cambium-thor-support/install
	$(INSTALL_DIR) $(1)/usr/sbin $(1)/etc/init.d $(1)/etc/uci-defaults $(1)/etc/config $(1)/etc/hotplug.d/openwisp
	$(INSTALL_BIN) ./files/thor-radio-settings $(1)/usr/sbin/
	$(INSTALL_BIN) ./files/thor-radio-settings.init $(1)/etc/init.d/thor-radio-settings
	$(INSTALL_DATA) ./files/xv3_8_radio.config $(1)/etc/config/xv3_8_radio
	$(INSTALL_DATA) ./files/95-thor-radio-settings $(1)/etc/hotplug.d/openwisp/
	$(INSTALL_BIN) ./files/15_thor_radio_settings \
		./files/17_thor_bridge_section $(1)/etc/uci-defaults/
endef

$(eval $(call BuildPackage,cambium-thor-support))
