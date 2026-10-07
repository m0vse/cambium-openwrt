# Keeping the Cambium changes out of OpenWrt's core

OpenWrt is unlikely to accept most of this fork's changes, so every change to
an upstream file is something the weekly rebase can conflict on, for good.
This note lists what can move into our own packages, what has to stay in the
tree (and how to make it touch upstream files as little as possible), and
what Sage needs to become an ordinary family like Thor, Jaguar and Cheetah.

Sections 1 and 2 are one task for all four families together, to be done
later. Section 4 (Sage) is a separate task and leaves them alone.

## 1. Move into our packages

These are edits to upstream files that only matter at run time, on Cambium
boards. Each can ship from a package in `package/cambium/` instead.

| Upstream file edited now | Moves to | How |
| --- | --- | --- |
| `package/base-files/files/etc/uci-defaults/12_cambium_ap`, `13_cambium_hostname` | a common Cambium package (or `cambium-ab`) | The same uci-defaults scripts, shipped by the package. They then exist only on Cambium images. |
| `target/linux/ipq40xx/base-files/lib/functions/cambium-sage.sh` | `cambium-sage-support` | Already Sage-only; it only lives in the wrong place. |
| `etc/board.d/02_network` entries (ipq40xx; qualcommax ipq50xx, ipq60xx, ipq807x) | each family's support package | A package's own `/etc/board.d/` script runs after `02_network` and sets the Cambium boards' ports. |
| `etc/hotplug.d/firmware/11-ath11k-caldata` entries (three qualcommax subtargets) | `cambium-board-data` | A second hotplug script extracts Cambium calibration; the core script no longer matches those boards. |
| `package/boot/uboot-tools/uboot-envtools/files/{ipq40xx,qualcommax_*}` entries | the support packages | Their uci-defaults script writes `/etc/fw_env.config` for Cambium boards, after uboot-envtools' own. |
| `lib/upgrade/platform.sh` dispatch (four targets) | `cambium-ab` | sysupgrade sources every `/lib/upgrade/*.sh`. A `cambium-ab` file named to sort after `platform.sh` defines `platform_check_image`/`platform_do_upgrade` only when the board is a Cambium one, so no other board changes and `platform.sh` is untouched. |

After this, upstream's `base-files`, the targets' `base-files` and
`uboot-envtools` carry no Cambium edits. The existing tests
(`cambium-ab.sh`, `cambium-vlan.sh`, `cambium-ap-defaults.sh`,
`sage-sysupgrade.sh`) cover the moved behaviour.

## 2. Must stay in the tree: keep it to new files

- **Image recipes.** The device definitions appended to
  `target/linux/ipq40xx/image/generic.mk` and
  `target/linux/qualcommax/image/ipq{50,60,807}xx.mk` and
  `target/linux/qualcommbe/image/ipq53xx.mk` (Miami), the family FIT recipe
  in `include/image.mk` and `include/image-commands.mk`, and
  `scripts/cambium-family-its.sh`. They cannot be packages. Move each block
  into a new file of its own (for example
  `target/linux/qualcommax/image/cambium.mk`, `include/image-cambium.mk`)
  with one `include` line in the upstream file: one line to conflict with
  instead of a block. `CAMBIUM_VAULT_SIZE` (the Miami vault) is one more
  device variable in `include/image.mk`.
- **The qualcommbe/ipq53xx subtarget** (Til Kaiser's pending upstream
  series) and its `base-files`; it goes away once upstream merges it.
- **Device trees.** Around 45 new files in `target/linux/*/dts/`. Additions
  only; they never conflict.

## 3. Must stay as patches

- `package/kernel/mac80211/patches/ath11k/952-ath11k-xv3-8-configurable-radio-mode.patch`
  (XV3-8-specific; no upstream home).
- `target/linux/generic/pending-6.18/950-net-phy-aquantia-add-aqr111c.patch`
  and `target/linux/qualcommax/patches-6.18/090{0,1,2,3}-ipq5018-mdio-*.patch`:
  generic enough to offer to the Linux kernel itself.

- Miami: `target/linux/qualcommbe/patches-6.18/0379`-`0399` (IPQ5332 PPE
  and CMN PLL backports, the X7-35X PHY reference clock, the WCSS secure
  PIL series, QSDK split-image metadata, the X7-35X user-PD boot record)
  and `package/kernel/mac80211/patches/ath12k/106`, `109`-`111`. The PPE
  fixes (0383, 0385), the metadata fix (0399), 106, 110 and 111 (the
  `mem_profile` parameter) are generic enough to offer upstream (110 would
  need gating: it lets a device regdb.bin override board-2.bin's on every
  platform); the rest is X7-35X-specific. One-line core edits:
  `kmod-qrtr-smd` allowed on qualcommbe (`netsupport.mk`) and ath12k's AHB
  bus on ipq53xx (`mac80211/ath.mk`).

Optional: `package/cambium/` could become a separate feed. It never
conflicts, so this is tidiness only.

## 4. Normalising Sage

Sage (E410 family, IPQ4019) is built, installed, upgraded and managed
differently from the other three families. What makes it different, and
what normalising each point takes, cheapest and safest first. Some
differences are hardware and stay (listed at the end).

1. **Legacy E410 device definitions.** `Device/cambium_e410` and
   `Device/cambium_e410-recovery` in `generic.mk`, with
   `qcom-ipq4019-e410*.dts{,i}`, predate the family images and are not in
   `cambium/configs/sage.config`. Remove them once nothing refers to them.
2. **Core-file edits**: `cambium-sage.sh` in the target's base-files, the
   Sage branches in `platform.sh` and `02_network`, and the ipq40xx
   uboot-envtools entry. Not part of the Sage task: they move with the other
   families' in the later packaging task (section 1).
3. **The earlier Sage upgrade state.** `ab_sage_takeover` in
   `cambium-ab-sage.sh` adopts `e410_upgrade_*` and `owrt_boot0/1` from
   images before the shared A/B code, with its test fixtures and site note.
   Remove once every E410 shows `mode=ab` in `cambium-ab-status`.
4. **Board names.** The persistent FIT's compatible is the legacy
   `cambium,e410` (plus `cambiumnetworks,e410`), and the E410B boots the
   E410's configuration, so it reports `cambium,e410` too; the other
   families use `cambiumnetworks,<model>` per model. Switching Sage to
   `cambiumnetworks,<model>` touches `cambium-sage.sh`'s board table,
   `platform.sh`/`02_network` matches, `sage-migration-*`'s board check,
   `families.json`/`select-config.sh`, the sysupgrade metadata
   (`SUPPORTED_DEVICES` must accept the old name so installed units can
   upgrade) and the board list in OpenWISP's `OPENWISP_CUSTOM_OPENWRT_IMAGES`.
5. **RAM recovery over TFTP.** Sage's `ram` needs a TFTP server
   (`--tftp`) because U-Boot loads `sage-recovery.itb` with `tftpboot`; the
   other families stage the recovery image in a UBI volume and `ubi read` it.
   Sage's U-Boot can `ubi read` (its boot commands do), so the installer
   can stage the recovery FIT in a volume of the shared `fs` UBI device
   instead. This also makes RAM recovery possible at sites with no local
   TFTP server.
6. **Install and commit.** Sage installs with its own `install_sage`
   (`ubiupdatevol` of `kernel.itb` and `rootfs.ubifs` into the stock pair),
   then needs a manual `sage-migration-mark-good --confirm` (root password
   and OpenWISP contact required), with `sage-migration-rollback-oem` to
   return. The others ubiformat `factory.ubi` into a bank and
   `cambium-ab-guard` commits a healthy first boot by itself. Normalise by
   having the installer write the slot through the shared `cambium-ab` writer
   (its `pair` layout) and arming the same guarded first boot, so the guard
   commits it; `sage-migration-*` then go.
7. **Root filesystem.** Sage's root is a writable UBIFS (`rootfs.ubifs`,
   `Build/e410-rootfs-ubifs`), laid over the stock volume pairs
   `linux0/rootfs0` and `linux1/rootfs1` in one UBI device. The others run
   SquashFS with a per-bank `rootfs_data` overlay. Consequences today: no
   factory reset (`firstboot`), no `sysupgrade -c` semantics (configuration
   is carried as `sysupgrade.tgz`), a separate image set (`kernel.itb`,
   `rootfs.ubifs`, `sysupgrade.bin` instead of `factory.ubi`), a second
   release-gate pass in `build.sh`, `manifest.py`'s kernel/rootfs pair
   case, and OpenWISP's "full-UBIFS" upgrader behaviour (the `E410OpenWrt`
   alias). Moving to SquashFS plus a `rootfs_data` volume per pair within
   the same UBI device is the largest step: installed units have to change
   layout, one pair per upgrade (the running pair cannot be rewritten), so
   it takes a two-upgrade migration and its own tests. Do it last.
8. **Build and CI special cases** that go once 5-7 are done:
   `build.sh`'s Sage verification branch and UBIFS gate, the installer's
   Sage-only paths, and the separate `sage-sysupgrade.sh` test suite (its
   cases folded into `cambium-ab.sh`).

Stays different, because the hardware is:

- ARM32: the kernel is a zImage FIT, not a uImage.
- The U-Boot has no `changing_bootcmd` marker (`AB_MARKER=0`).
- No device-data vault: ath10k reads its calibration from ART directly.
- ath10k takes the US regulatory domain from ART for radar timing, so the
  E410 OpenWISP template carries a `chanlist` keeping it off the
  weather-radar channels, and the radio cannot scan from a radar channel.
