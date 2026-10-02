# Gambit changelog

E400 (validated: recovery, installer, persistent and A/B sysupgrade); E500, E501S, E502S (no build yet).

## Unreleased

- Add hardware-verified E400 power and network LED GPIOs and polarities.
  Network green indicates Ethernet link/activity; network amber stays off.
  Power indicates boot/failsafe/upgrade, then the shared OpenWISP service
  shows green when its controller check succeeds and amber otherwise.
  Existing blue/green families retain their colours. Include the GPIO LED
  driver in recovery and installer images as well as persistent images.
- The E400 (SKU 6) is validated for the RAM installer, persistent install
  and A/B sysupgrade, on one unit: the first install wrote only the inactive
  bank; warm reboot and cold power-cycle passed; the preserved OEM bank was
  converted after a verified off-device backup; sysupgrade 1→0 and 0→1 kept
  the network, system and wireless configuration; and a failed-health trial
  rolled back automatically. Factory MAC, DHCP with VLAN 1 filtering, both
  radios and the writable overlay work. The installer no longer needs
  `--trial`, and `cambium-ab-convert` no longer needs `--allow-untested`.
  Other Gambit models are unchanged. Known: early boot logs a harmless
  `fw_env.config`/NVMEM warning before the environment configuration exists.
- Match OEM/U-Boot NAND ECC: use 1-bit software Hamming in 256-byte steps,
  with 24 parity bytes at OOB offsets 40–63. The inherited hardware BCH
  mode read its own writes but produced kernels unreadable by U-Boot.
  Verify the mode in all three built device trees and provide a read-only
  raw-backup parity checker.
- Isolate the downloaded family module during RAM installation, so the
  upgrade writer is not recursively loaded by the core's module scan.
- Read Ethernet's OEM MAC from the manufacturing-data hexadecimal cell,
  not the integrated radio's calibration MAC. Verify the reference in all
  built recovery, installer and persistent device trees.
- Add the E400 RAM installer and persistent 4 MiB raw-kernel / 44 MiB UBI
  bank layout. Use the shared Cambium A/B guard, conversion and sysupgrade
  machinery; first install writes the inactive bank, preserves the running
  OEM bank and rearms only healthy OpenWrt. Load uImages at the validated
  non-overlapping 0x83000000.
- Generate the E400 U-Boot environment configuration by partition label and
  publish Gambit installer/upgrade assets through the common build pipeline.
- Apply the temporary recovery DHCP/hostname defaults only in RAM boots;
  saved persistent network settings are retained across upgrades.
- Move the E400 recovery image to the NAND subtarget and filter recovery
  management to untagged VLAN 1.
- First E400 build: a RAM-only recovery image (initramfs kernel), built by
  the snapshot workflow.
