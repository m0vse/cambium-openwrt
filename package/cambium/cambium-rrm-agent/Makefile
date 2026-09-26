include $(TOPDIR)/rules.mk

PKG_NAME:=cambium-rrm-agent
PKG_RELEASE:=2
PKG_LICENSE:=GPL-2.0-only
PKG_MAINTAINER:=Phil Taylor <phil@m0vse.uk>

include $(INCLUDE_DIR)/package.mk

define Package/cambium-rrm-agent
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Cambium access point radio measurements
  DEPENDS:=+iw
  PKGARCH:=all
endef

define Package/cambium-rrm-agent/description
  Measures what the radio resource planner needs on every Cambium family:
  each radio's channel, busy time, noise and clients, and the networks heard
  by the family's dedicated scanning radio where it has one (the XV3-8's).
  The latest measurement is kept as JSON in /tmp/cambium-rrm/latest.json.
  A dedicated scanning radio is kept in the Wi-Fi configuration as a
  disabled radio named "scan", so it never serves clients.
endef

define Package/cambium-rrm-agent/conffiles
/etc/config/cambium_rrm
endef

define Build/Compile
endef

define Package/cambium-rrm-agent/install
	$(INSTALL_DIR) $(1)/usr/sbin $(1)/etc/init.d $(1)/etc/config $(1)/etc/hotplug.d/ieee80211 \
		$(1)/lib/functions
	$(INSTALL_BIN) ./files/cambium-rrm-agent $(1)/usr/sbin/
	$(INSTALL_DATA) ./files/cambium-rrm.sh $(1)/lib/functions/cambium-rrm.sh
	$(INSTALL_BIN) ./files/cambium-rrm-agent.init $(1)/etc/init.d/cambium-rrm-agent
	$(INSTALL_CONF) ./files/cambium_rrm.config $(1)/etc/config/cambium_rrm
	$(INSTALL_DATA) ./files/20-cambium-scan-radio $(1)/etc/hotplug.d/ieee80211/
endef

$(eval $(call BuildPackage,cambium-rrm-agent))
