# Sage changelog

E410, E410B, E510 (validated layout); E430H, E430W, E600, E700 (RAM boot only).

## Unreleased

- E600 initial hardware trial: use the captured 256 MiB RAM size, PCIe QCA9984 5 GHz radio (ART calibration at 0x9000), factory Ethernet MAC and 128 MiB parallel NAND layout. Disable the unused integrated 5 GHz radio and DVK SD interface. All E600 flash partitions remain read-only and persistent installation remains unqualified; other Sage model trees are unchanged.
- No firmware change. The E410B's `config@17` (in the images since 2026.09.28.1) is now marked validated for RAM boot and persistent install, so the installer accepts an E410B without `CAMBIUM_HARDWARE_TRIAL=1`.

## 2026.09.28.1

- Sage's normal sysupgrade image now uses SquashFS with a separate 67-LEB UBIFS overlay per slot. Existing UBIFS APs run `update-upgrader` before the first SquashFS upgrade (the UBIFS bridge image is a fallback); that upgrade converts the inactive pair and the next converts the remaining pair. Fresh OEM/OEM devices still use the proven UBIFS installer, then the same two upgrades. Each trial retains the running pair as fallback; the guard requires a persistent overlay before committing.
- Sage installation now writes and verifies the inactive volume pair through the shared A/B writer and automatically commits a healthy first boot through the shared guard. The preserved OEM pair is recorded for a safe `stock` return until the first sysupgrade; the manual migration commit/rollback helpers are retired.
- Sage recovery now stages its verified FIT in the inactive rootfs UBI volume and RAM-boots it with U-Boot `ubi read`, without TFTP. The installer requires an off-AP SHA-256-verified backup and explicit inactive-rootfs overwrite confirmation; the active OEM pair stays untouched.
- Give E410 its model-specific board ID while retaining the legacy ID for installed APs. E410B uses its own FIT tree; B-suffix units on the legacy tree trial that configuration on the second upgrade, keeping the old pair as fallback.
- Retire the pre-A/B Sage takeover helper, its test fixtures and obsolete site note; deployed E410s already use shared A/B mode.
- Remove the obsolete E410 image definitions and leaf trees; use a Sage-named shared device-tree include for family images.

## 2026.09.26.2

- E410 and E410B sysupgrade marked validated on the shared A/B code.

## 2026.09.26.0

- Sage moves onto the shared A/B code: `cambium-ab-status`, the shared boot
  guard and automatic rollback, as on the other families. The layout is
  unchanged (volume pairs `linux0`/`rootfs0` and `linux1`/`rootfs1`, writable
  UBIFS roots). An E410 on an earlier image upgrades with a normal
  sysupgrade and adopts its earlier upgrade state on first boot. Managed APs
  still commit only once OpenWISP answers. `sage-sysupgrade-mark-good` is
  replaced by the boot guard.

## 2026.09.25.2

- The GPIO LED and reset-button drivers are included in the persistent image.

## 2026.09.25.1

- **Fix:** the persistent image is built from the Sage device's own root
  filesystem. Every earlier snapshot's Sage persistent image (2026.09.24.1 to
  2026.09.25.0) lacked LuCI, uHTTPd, OpenWISP, WireGuard and
  `cambium-sage-support`; do not install those.
- **Fix:** an upgrade keeps a hostname set by hand or by OpenWISP.
- E410B notes explain why it installs with the E410 configuration.

## 2026.09.25.0

- **Fix:** the upgrade commit reads the shared OpenWISP managed state.

## 2026.09.24.0

- One family image for all Sage models, each booting its own device tree;
  A/B sysupgrade refuses the models whose layout has not been captured.
- A migration commits without OpenWISP on unmanaged APs.
- The E410B is treated as the validated E410.

## Before the snapshots (19–23 September 2026)

- 19 September: E410 RAM boot, then the first persistent A/B build, keeping
  the stock UBI volume pairs.
- 20 September: installed E410s migrated from the stock firmware and onto
  OpenWISP, with VLAN-filtered management.
- 21 September: release 2026.09.21.1.
- 23 September: one Sage family image for all seven models.
