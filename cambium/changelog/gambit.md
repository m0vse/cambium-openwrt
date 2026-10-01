# Gambit changelog

E400 (recovery validated; persistent/A-B hardware trials pending).

## Unreleased

- Add the E400 RAM installer and persistent 4 MiB raw-kernel / 44 MiB UBI
  bank layout. Use the shared Cambium A/B guard, conversion and sysupgrade
  machinery; first install writes the inactive bank, preserves the running
  OEM bank and rearms only healthy OpenWrt. Load uImages at the validated
  non-overlapping 0x83000000.
- Generate the E400 U-Boot environment configuration by partition label and
  publish Gambit installer/upgrade assets through the common build pipeline.
  Persistent installation and A/B upgrades remain untested on hardware.
- Apply the temporary recovery DHCP/hostname defaults only in RAM boots;
  saved persistent network settings are retained across upgrades.

- Move the E400 recovery image to the NAND subtarget, use the factory Ethernet
  MAC from ART, and filter recovery management to untagged VLAN 1.

- First E400 build: a RAM-only recovery image (initramfs kernel), built by
  the snapshot workflow. Bring-up only: no persistent or sysupgrade image,
  and the installer does not support Gambit yet.
