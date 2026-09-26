# Thor changelog

XV3-8 (validated); XE5-8 (RAM boot only).

## Unreleased

- The XV3-8 image no longer copies `/etc/dropbear/recovery_authorized_key`
  into `authorized_keys` after each OpenWISP config reload. SSH keys now
  come only from OpenWISP's SSH keys template, as on the other families.
- A duplicate first-boot script that switched off the XV3-8's DHCP server
  is removed; `12_thor_recovery` already does the same for the XV3-8 and
  XE5-8.

## 2026.09.26.2

- The XV3-8's QCA9887 scanning radio is enabled in the persistent image
  (PCIe 1, ath10k, with this unit's own calibration from ART). It serves no
  clients: it has one disabled `scan` section in `/etc/config/wireless`
  and no networks, so it stays out of LuCI's and OpenWISP's radio lists.
  The RRM agent scans with it every five minutes, through an interface
  that exists only during the scan. The three serving radios keep their
  settings (they are matched by hardware path, so their phy numbers moving
  up does not matter). Tested on an XV3-8 with a scan every minute
  alongside normal service.
- The XV3-8's auxiliary 1 GbE port (`lan`) is enabled. A fresh install
  bridges it with `lan-multigig`, with untagged VLAN 1 on both. An
  upgraded AP keeps its saved network settings, so the port stays unused
  until its config adds it (for an OpenWISP-managed AP, the XV3-8 trunk
  template). Tested on an XV3-8: the link comes up at 1 Gb/s full duplex.
- Both XV3-8 test images (scanning radio, auxiliary port) are retired: the
  released image now has both.

## 2026.09.26.1

- Test images for the XV3-8's QCA9887 scanning radio and its auxiliary
  1 GbE port, as CI artifacts only (`test-only/`), never released. The
  released image is unchanged.

## 2026.09.26.0

- XV3-8 A/B build and sysupgrade marked validated: installed from the
  stock firmware, converted, and switched banks through OpenWISP.

## 2026.09.25.2

- **Fix:** the GPIO LED and reset-button drivers are included; earlier fork
  snapshots had no status LEDs and no failsafe button.
- **Fix:** a single-bank XV3-8 upgraded in place keeps its Wi-Fi board data
  and is not rebooted repeatedly by the boot guard.

## 2026.09.25.1

- **Fix:** an upgrade keeps a hostname set by hand or by OpenWISP.

## 2026.09.25.0

- XV3-8 moves onto the shared A/B banks (`rootfs` and `rootfs_1`), with a
  FIT configuration per bank (`config@hk02`, `config@hk02-bank1`) and a
  device-data vault. Installs work from the stock firmware directly, or
  through the RAM installer when it lacks `ubiformat`. Single-bank installs
  keep working after an in-place upgrade and move to A/B by reinstalling.

## 2026.09.24.0

- The persistent image is named after the family, and the RAM installer is
  published as `thor-installer`.

## Before the snapshots (20–23 September 2026)

- 20 September: XV3-8 RAM boot, the multi-gigabit primary port, the three
  integrated radios, the persistent single-bank install, status LEDs and the
  reset button.
- 20–21 September: OpenWISP management, the radio policy service, and VLAN
  filtering on the LAN bridge so a busy tagged VLAN cannot starve DHCP.
- XE5-8: recovery (RAM) image only; its flash layout is not captured.
