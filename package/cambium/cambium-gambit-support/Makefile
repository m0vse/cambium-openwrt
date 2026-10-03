include $(TOPDIR)/rules.mk

PKG_NAME:=cambium-gambit-support
PKG_RELEASE:=5
PKG_LICENSE:=GPL-2.0-only
PKG_MAINTAINER:=Phil Taylor <phil@m0vse.uk>

include $(INCLUDE_DIR)/package.mk

define Package/cambium-gambit-support
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Cambium Gambit family access point support
  DEPENDS:=@TARGET_ath79 +ubi-utils +uboot-envtools +nand-utils +curl +cambium-ab +cambium-openwisp-led +cambium-rrm-agent
  PKGARCH:=all
endef

define Package/cambium-gambit-support/description
  Gambit E400 raw NAND kernel / UBI root bank support for the shared
  Cambium A/B guard and upgrade tools, plus recovery and VLAN defaults.
endef

define Build/Compile
endef

define Package/cambium-gambit-support/install
	$(INSTALL_DIR) $(1)/etc/uci-defaults $(1)/lib/functions
	$(INSTALL_DATA) ./files/cambium-ab-gambit.sh $(1)/lib/functions/
	$(INSTALL_BIN) ./files/12_gambit_recovery $(1)/etc/uci-defaults/
	$(INSTALL_BIN) ./files/17_gambit_bridge_section $(1)/etc/uci-defaults/
endef

$(eval $(call BuildPackage,cambium-gambit-support))
