# Sage changelog

E410, E410B, E510 (validated layout); E430H, E430W, E600, E700 (RAM boot only).

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
