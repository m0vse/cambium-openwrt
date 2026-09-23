## Read before flashing

These are **automated development snapshots**, built from upstream OpenWrt
`main` with the Cambium patches on top. They are not OpenWrt releases and are
published without per-build hardware testing.

| Family | Models in the image | Hardware-validated so far |
| --- | --- | --- |
| Sage (IPQ4019) | E410, E410B, E430H, E430W, E510, E600, E700 | E410 only (RAM boot, persistent A/B, upgrades) |
| Thor (IPQ8074) | XV3-8 persistent; XV3-8 and XE5-8 recovery | XV3-8 only |
| Cheetah (IPQ5018) | XV2-21X persistent; XV2-21X, XV2-22H and XV2-23T recovery | XV2-21X only |
| Jaguar (IPQ6018) | XV2-2, XV2-2T0, XV2-2T1, XE3-4 and XE3-4TN | XV2-2T1 only |

Models not listed as validated are included for controlled, locally
recoverable trials only. Keep a verified backup of every unit and never
overwrite the bootloader, ART or U-Boot environment partitions.

- Images use stock OpenWrt defaults: no SSH keys are included and root has
  no password until you set one. The LAN is a DHCP client and never serves
  DHCP or router advertisements.
- No OEM Wi-Fi board data is distributed. On first boot the AP copies the
  board file its own stock firmware uses from the retained, read-only OEM
  slot; the OEM slot and calibration (ART) are never modified. If that slot
  is gone or unreadable, the radios stay down and wired operation continues.
- Cheetah (XV2-21X) persistent builds ship only `factory.ubi`: there is no
  generic sysupgrade path for that model yet.
- Kernel modules must come from the same snapshot as the image. The package
  feed for each snapshot is configured in the image and kept for the two
  most recent snapshots only.
