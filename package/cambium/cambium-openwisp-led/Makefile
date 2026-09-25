include $(TOPDIR)/rules.mk

PKG_NAME:=cambium-openwisp-led
PKG_RELEASE:=2
PKG_LICENSE:=GPL-2.0-only
PKG_MAINTAINER:=Phil Taylor <phil@m0vse.uk>

include $(INCLUDE_DIR)/package.mk

define Package/cambium-openwisp-led
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Cambium access point OpenWISP status LED
  DEPENDS:=+curl
  PKGARCH:=all
endef

define Package/cambium-openwisp-led/description
  Lights the status LED of a Cambium access point blue while its OpenWISP
  controller answers the device's checksum request, and green otherwise.
  Works on every Cambium family (Sage, Thor, Jaguar and Cheetah).
endef

define Build/Compile
endef

define Package/cambium-openwisp-led/install
	$(INSTALL_DIR) $(1)/usr/sbin $(1)/etc/init.d
	$(INSTALL_BIN) ./files/cambium-openwisp-led $(1)/usr/sbin/
	$(INSTALL_BIN) ./files/cambium-openwisp-led.init $(1)/etc/init.d/cambium-openwisp-led
endef

$(eval $(call BuildPackage,cambium-openwisp-led))
