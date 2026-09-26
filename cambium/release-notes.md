## Read before flashing

These are **automated development snapshots**, built from upstream OpenWrt
`main` with the Cambium patches on top. They are not OpenWrt releases and are
published without per-build hardware testing.

Each family has one recovery image and one persistent image; each image
holds every model's device tree and boots the one matching the AP's board
SKU. Hardware status per model:

| Family | Stock firmware | Model | Recovery (RAM) | Persistent | Sysupgrade |
| --- | --- | --- | --- | --- | --- |
| Gambit (Wi-Fi 5, MIPS) | 4.2.3.3-r10 | E400, E500, E501S, E502S | no build yet | no build yet | no build yet |
| Sage (IPQ4019) | 4.2.3.3-r10 | E410, E410B | validated | validated (A/B install and upgrades) | A/B, validated |
| | | E510 | untested | untested | A/B, untested (same layout as the E410) |
| | | E430H, E430W, E600, E700 | untested | untested | refused: layout not yet captured |
| Lila (Wi-Fi 5, MIPS) | 4.2.3.3-r10 | E425W, E505 | no build yet | no build yet | no build yet |
| Thor (IPQ8074) | 7.2-r1 | XV3-8 | validated | validated (A/B build) | A/B, validated |
| | | XE5-8 | untested | not built: flash layout not yet captured | none |
| Jaguar (IPQ6018) | 7.2-r1 | XV2-2T1 | validated | validated (A/B build) | A/B, validated |
| | | XV2-2 (128 MiB NAND, 52 MiB slots) | validated | validated (A/B build) | A/B, validated |
| | | XV2-2T0, XE3-4TN | untested | untested: RAM boot only | A/B, untested |
| | | XE3-4 | untested | untested: RAM boot only | not yet: shares its board name with upstream's XE3-4 image |
| Cheetah (IPQ5018) | 7.2-r1 | XV2-21X | validated | untested: now the A/B build | A/B, untested |
| | | XV2-22H, XV2-23T | untested | untested: RAM boot only | A/B, untested |
| Miami (Wi-Fi 7, IPQ5332) | 7.2-r1 | X7-35X, X7-53X, X7-55X, X7-56X | no build yet | no build yet | no build yet |

Families are listed oldest first. Run the listed (latest) stock firmware,
ideally in both slots, before installing. Gambit, Lila and Miami have no OpenWrt
port yet; they are listed so the table covers every Cambium access point
family.

**Installing:** `cambium-install.sh` (a release asset) RAM-boots or installs
from the stock firmware's root shell for every family, with all checks,
backups and read-back built in; see the site's installer section.

**Untested models: RAM boot only.** On any model not marked validated, use
only the recovery (RAM) image, then run `cambium-report.sh` (a release
asset) in the booted image, and on the stock firmware, and attach the
reports to a *Cambium hardware report* issue. Do not install the persistent
image on these models: `select-config.sh` refuses it. The report script only
reads, and masks MAC addresses and serial numbers.
Keep a verified backup of every unit and never
overwrite the bootloader, ART or U-Boot environment partitions. Models in a
family do not always share a flash layout: the Jaguar XV2-2 has two 52 MiB
slots where the XV2-2T1 has two 96 MiB slots.

Hardware for validation is very welcome: if you can send a unit of an
untested or unported model, please open an issue on this repository.

- Images use stock OpenWrt defaults: no SSH keys are included and root has
  no password until you set one. The LAN is a DHCP client and never serves
  DHCP or router advertisements.
- No OEM Wi-Fi board data is distributed. On first boot the AP copies the
  board file its own stock firmware uses from the retained, read-only OEM
  slot; the OEM slot and calibration (ART) are never modified. If that slot
  is gone or unreadable, the radios stay down and wired operation continues.
- Sysupgrade works on the Sage E410-layout models (A/B with automatic
  rollback). Thor, Jaguar and Cheetah have A/B sysupgrade with automatic
  rollback after conversion (validated on the Jaguar XV2-2 and XV2-2T1 and
  the Thor XV3-8, untested on Cheetah). An XV3-8 on the earlier single-bank image
  sysupgrades in place to this image, then reinstalls once
  (`cambium-install.sh stock`, then `install`) to move to A/B.
- Kernel modules must come from the same snapshot as the image. The package
  feed for each snapshot is configured in the image and kept for the two
  most recent snapshots only.
