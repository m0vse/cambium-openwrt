include $(TOPDIR)/rules.mk

PKG_NAME:=cambium-jaguar-support
PKG_RELEASE:=4
PKG_LICENSE:=GPL-2.0-only
PKG_MAINTAINER:=Phil Taylor <phil@m0vse.uk>

include $(INCLUDE_DIR)/package.mk

define Package/cambium-jaguar-support
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Cambium Jaguar family access point support
  DEPENDS:=@TARGET_qualcommax_ipq60xx +cambium-ab +cambium-board-data +cambium-openwisp-led
  PKGARCH:=all
endef

define Package/cambium-jaguar-support/description
  The Jaguar (XV2-2 / XE3-4 family) module for cambium-ab: board table,
  firmware bank layouts and U-Boot boot commands.
endef

define Build/Compile
endef

define Package/cambium-jaguar-support/install
	$(INSTALL_DIR) $(1)/lib/functions
	$(INSTALL_DATA) ./files/cambium-ab-jaguar.sh $(1)/lib/functions/cambium-ab-jaguar.sh
endef

$(eval $(call BuildPackage,cambium-jaguar-support))
