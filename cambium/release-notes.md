## Read before flashing

These are **automated development snapshots**, built from upstream OpenWrt
`main` with the Cambium patches on top. They are not OpenWrt releases and are
published without per-build hardware testing.

Each family has one recovery image and one persistent image; each image
holds every model's device tree and boots the one matching the AP's board
SKU. Hardware status per model:

| Family | Stock firmware | Model | Recovery (RAM) | Persistent |
| --- | --- | --- | --- | --- |
| Gambit (Wi-Fi 5, MIPS) | 4.2.3.3-r10 | E400, E500, E501S, E502S | no build yet | no build yet |
| Sage (IPQ4019) | 4.2.3.3-r10 | E410 | validated | validated (A/B install and upgrades) |
| | | E410B, E430H, E430W, E510, E600, E700 | untested | untested |
| Lila (Wi-Fi 5, MIPS) | 4.2.3.3-r10 | E425W, E505 | no build yet | no build yet |
| Thor (IPQ8074) | 7.2-r1 | XV3-8 | validated | validated |
| | | XE5-8 | untested | not built: flash layout not yet captured |
| Jaguar (IPQ6018) | 7.2-r1 | XV2-2T1 | validated | validated |
| | | XV2-2, XV2-2T0, XE3-4, XE3-4TN | untested | untested |
| Cheetah (IPQ5018) | 7.2-r1 | XV2-21X | validated | validated |
| | | XV2-22H, XV2-23T | untested | untested |
| Miami (Wi-Fi 7, IPQ5332) | 7.2-r1 | X7-35X, X7-53X, X7-55X, X7-56X | no build yet | no build yet |

Families are listed oldest first. Run the listed (latest) stock firmware,
ideally in both slots, before installing. Gambit, Lila and Miami have no OpenWrt
port yet; they are listed so the table covers every Cambium access point
family.

Untested models are included for controlled, locally recoverable trials:
a model that RAM-boots the recovery image has a reasonable chance of
running the persistent image, but neither has run on that hardware yet.
Keep a verified backup of every unit and never
overwrite the bootloader, ART or U-Boot environment partitions.

Hardware for validation is very welcome: if you can send a unit of an
untested or unported model, please open an issue on this repository.

- Images use stock OpenWrt defaults: no SSH keys are included and root has
  no password until you set one. The LAN is a DHCP client and never serves
  DHCP or router advertisements.
- No OEM Wi-Fi board data is distributed. On first boot the AP copies the
  board file its own stock firmware uses from the retained, read-only OEM
  slot; the OEM slot and calibration (ART) are never modified. If that slot
  is gone or unreadable, the radios stay down and wired operation continues.
- Cheetah persistent builds ship only `factory.ubi`: there is no generic
  sysupgrade path for that family yet.
- Kernel modules must come from the same snapshot as the image. The package
  feed for each snapshot is configured in the image and kept for the two
  most recent snapshots only.
