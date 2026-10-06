## Read before flashing

**Snapshots** are automated development builds of upstream OpenWrt `main`
with the Cambium patches on top, published without per-build hardware
testing. **Releases** are built from an OpenWrt stable release with the same
patches; each is a release candidate until it has been validated on each
family's hardware, and is then promoted to a full release.

Each family has one recovery image and one persistent image; each image
holds every model's device tree and boots the one matching the AP's board
SKU. Hardware status per model:

| Family | Stock firmware | Model | Recovery (RAM) | Persistent | Sysupgrade |
| --- | --- | --- | --- | --- | --- |
| Gambit (Wi-Fi 5, MIPS) | 4.2.3.3-r10 | E400 | validated | validated (A/B build, raw uImage kernel) | A/B, validated |
| | | E500 | no build yet | no build yet | no build yet: needs hardware |
| | | E501S | no build yet | no build yet | no build yet: needs hardware |
| | | E502S | no build yet | no build yet | no build yet: needs hardware |
| Sage (IPQ4019) | 4.2.3.3-r10 | E410, E410B | validated | validated | A/B, validated (shared A/B code) |
| | | E510 | untested | untested | A/B, untested (same layout as the E410) |
| | | E430H, E430W, E600, E700 | untested | untested | refused: layout not yet captured |
| Lila (Wi-Fi 5, MIPS) | 4.2.3.3-r10 | E425W, E505 | no build yet | no build yet | no build yet |
| Thor (IPQ8074) | 7.2-r1 | XV3-8 | validated | validated (A/B build) | A/B, validated |
| | | XE5-8 | untested | not built: flash layout not yet captured | none |
| Jaguar (IPQ6018) | 7.2-r1 | XV2-2T1 | validated | validated (A/B build) | A/B, validated |
| | | XV2-2 (128 MiB NAND, 52 MiB slots) | validated | validated (A/B build) | A/B, validated |
| | | XV2-2T0, XE3-4TN | untested | untested: RAM boot only | A/B, untested |
| | | XE3-4 | validated | validated (A/B build); 6 GHz not validated | A/B, validated; **must not** be used on an XE3-4 running upstream OpenWrt |
| Cheetah (IPQ5018) | 7.2-r1 | XV2-21X | validated | validated (A/B build) | A/B, validated |
| | | XV2-22H, XV2-23T | untested | untested: RAM boot only | A/B, untested |
| Miami (Wi-Fi 7, IPQ5332) | 7.2-r1 | X7-35X | validated | validated (beside the stock firmware, kept by the boot guard) | A/B, untested; until conversion reinstall with `--keep-settings` |
| | | X7-53X, X7-55X, X7-56X | no build yet | no build yet | no build yet |

Families are listed oldest first. **The listed stock firmware version MUST
be running** (currently the latest published Cambium version): it is the
version the layouts and procedures were validated on, and earlier versions
fail validation. Ideally have it in both slots before installing. Lila, the Miami models other
than the X7-35X and the Gambit models other than the E400 have no OpenWrt
build yet; they are listed so
the table covers every Cambium access point family.

**Installing:** `cambium-install.sh` (a release asset) RAM-boots or installs
from the stock firmware's root shell for every family, with all checks,
backups and read-back built in; see the site's installer section. With it
nothing else is needed: no TFTP server and none of the manual commands the
site shows for reference.

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
- Sage uses the same A/B code as the other families and, from 2026.09.28.1,
  a SquashFS root with a writable overlay per slot. An E410 or E410B on an
  earlier (UBIFS) image converts in two stages: run `cambium-install.sh
  update-upgrader` on it, then two normal sysupgrades, each converting one
  pair (validated on the E410 and E410B). Thor,
  Jaguar, Cheetah and Gambit have A/B sysupgrade with automatic rollback
  after conversion (validated on the Jaguar XV2-2, XV2-2T1 and XE3-4, the
  Thor XV3-8, the Cheetah XV2-21X and the Gambit E400). An XV3-8 on the earlier single-bank image
  sysupgrades in place to this image, then reinstalls once
  (`cambium-install.sh stock`, then `install`) to move to A/B.
- Miami (Wi-Fi 7) is new: see *Miami* below for what is and is not
  supported.
- **The Jaguar sysupgrade image MUST NOT be used to upgrade an XE3-4
  running upstream OpenWrt.** Upstream's XE3-4 image has the same board
  name, so its sysupgrade accepts this image but writes it without the A/B
  writer, into a layout it was not built for. Upgrade only an XE3-4
  installed with `cambium-install.sh`.
- Kernel modules must come from the same build as the image. The package
  feed for each build is configured in the image and kept for the two most
  recent snapshots and each OpenWrt series' newest release (fewer snapshots
  if the site nears GitHub Pages' 1 GB limit).

## Miami (Wi-Fi 7, IPQ5332)

New family, on a new OpenWrt subtarget (`qualcommbe/ipq53xx`). Only the
X7-35X has been run; the X7-53X, X7-55X and X7-56X are not in the image.

**Supported on the X7-35X (validated):**

- RAM boot of the recovery image from the stock firmware
  (`cambium-install.sh ram`).
- Persistent install into the stock firmware's inactive bank, whichever
  bank the stock firmware runs from (`cambium-install.sh install`). The
  stock firmware stays in the other bank, read-only to OpenWrt.
- The boot guard keeps OpenWrt as the boot after each healthy start (LAN
  up with a reachable gateway). If the LAN does not come up, the next boot
  returns to the stock firmware. `cambium-ab-stock --yes` makes the stock
  firmware the default again.
- Upgrades from the stock firmware, keeping settings
  (`cambium-install.sh --keep-settings install`).
- Wired Ethernet on the LAN port (DHCP, management on VLAN 1 as the other
  families).
- All three radios: 2.4 GHz (IPQ5332) and 5 and 6 GHz (QCN9224). Firmware,
  board files and the regulatory database come from the unit's own stock
  firmware, then from the bank's device-data vault; none are distributed.
  The 5/6 GHz board file follows the configured Wi-Fi country, as the
  stock firmware selects it from its regulatory domain.
- LuCI, OpenWISP and the other packages of the persistent images.

**Not supported yet:**

- A/B conversion (`cambium-ab-convert`) and A/B `sysupgrade`: implemented,
  but not run on hardware. `sysupgrade` refuses until conversion, and
  conversion needs `--allow-untested`.
- The second Ethernet port (on a separate switch chip).
- Bluetooth and Zigbee (EFR32MG21 radio).
- The LEDs.
- The X7-53X, X7-55X and X7-56X: no build yet; their hardware needs
  capturing from a unit.
