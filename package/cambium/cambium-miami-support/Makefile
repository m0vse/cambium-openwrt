include $(TOPDIR)/rules.mk

PKG_NAME:=cambium-miami-support
PKG_RELEASE:=2
PKG_LICENSE:=GPL-2.0-only
PKG_MAINTAINER:=Phil Taylor <phil@m0vse.uk>

include $(INCLUDE_DIR)/package.mk

define Package/cambium-miami-support
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Cambium Miami family access point support
  DEPENDS:=@TARGET_qualcommbe_ipq53xx +uboot-envtools +ubi-utils +cambium-ab +cambium-openwisp-led +cambium-rrm-agent
  PKGARCH:=all
endef

define Package/cambium-miami-support/description
  The Miami (X7-35X) module for cambium-ab (board table, firmware bank
  layout and U-Boot boot commands), the radio data stager miami-board-data
  (Q6 firmware, board files and regulatory database from the unit's own
  OEM firmware or device-data vault, calibration from ART) and the
  management bridge and Wi-Fi country defaults for Cambium Miami access
  points, and a fallback to the smaller QCN9224 firmware memory profile if
  the default one crashes. Nothing proprietary is included.
endef

define Build/Compile
endef

define Package/cambium-miami-support/install
	$(INSTALL_DIR) $(1)/etc/uci-defaults $(1)/etc/hotplug.d/ieee80211 \
		$(1)/etc/init.d $(1)/lib/functions $(1)/lib/preinit $(1)/usr/sbin
	$(INSTALL_BIN) ./files/13_miami_radio_country $(1)/etc/uci-defaults/
	$(INSTALL_BIN) ./files/17_miami_bridge_section $(1)/etc/uci-defaults/
	$(INSTALL_DATA) ./files/20-miami-radio $(1)/etc/hotplug.d/ieee80211/20-miami-radio
	$(INSTALL_DATA) ./files/cambium-ab-miami.sh $(1)/lib/functions/cambium-ab-miami.sh
	$(INSTALL_DATA) ./files/05_miami_radio_hold $(1)/lib/preinit/05_miami_radio_hold
	$(INSTALL_DATA) ./files/81_miami_radio_provision $(1)/lib/preinit/81_miami_radio_provision
	$(INSTALL_BIN) ./files/miami-board-data $(1)/usr/sbin/
	$(INSTALL_BIN) ./files/miami-wifi-profile $(1)/usr/sbin/
	$(INSTALL_BIN) ./files/miami-wifi-profile.init $(1)/etc/init.d/miami-wifi-profile
endef

$(eval $(call BuildPackage,cambium-miami-support))
