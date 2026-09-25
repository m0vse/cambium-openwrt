include $(TOPDIR)/rules.mk

PKG_NAME:=cambium-board-data
PKG_RELEASE:=3
PKG_LICENSE:=GPL-2.0-only
PKG_MAINTAINER:=Phil Taylor <phil@m0vse.uk>

include $(INCLUDE_DIR)/package.mk

define Package/cambium-board-data
  SECTION:=firmware
  CATEGORY:=Firmware
  TITLE:=Cambium access point Wi-Fi board data importer
  DEPENDS:=@TARGET_qualcommax +ubi-utils
  PKGARCH:=all
endef

define Package/cambium-board-data/description
  Installs the Wi-Fi board data files used by the access point's own stock
  firmware. They are read at boot from the retained OEM firmware
  slot, so no OEM board data is redistributed in OpenWrt images. The ART
  calibration partition is never modified. Jaguar A/B images keep the files
  in a per-bank device-data vault bound to the unit's board, SKU and ART.
endef

define Build/Compile
endef

define Package/cambium-board-data/install
	$(INSTALL_DIR) $(1)/usr/sbin $(1)/etc/init.d
	$(INSTALL_BIN) ./files/cambium-board-data $(1)/usr/sbin/
	$(INSTALL_BIN) ./files/cambium-board-data.init $(1)/etc/init.d/cambium-board-data
endef

$(eval $(call BuildPackage,cambium-board-data))
