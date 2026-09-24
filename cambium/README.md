# Cambium access point support

This fork is upstream OpenWrt `main` plus a linear stack of commits adding
Cambium Networks access points. Hardware support lives where upstream expects
it (`target/linux`, `package/`), so the stack can be submitted upstream patch
by patch. This directory holds only the downstream build and release tooling.

The project site, https://m0vse.github.io/cambium-openwrt/, is built from
`site/` by `scripts/update-site.sh` on every publish: it describes the
project, the per-model hardware status and the install, upgrade and rollback
procedure, and lists the current snapshots and their package feeds.

## Families

| Family | Target | Devices built | Support package |
| --- | --- | --- | --- |
| Gambit (E400, E500, E501S, E502S) | `ath79` (MIPS) | no build yet | — |
| Sage | `ipq40xx/generic` | `cambiumnetworks_sage-persistent`, `cambiumnetworks_sage-recovery` | `cambium-sage-support` |
| Lila (E425W, E505) | `ath79` (MIPS) | no build yet | — |
| Thor | `qualcommax/ipq807x` | `cambiumnetworks_thor-persistent`, `cambiumnetworks_thor-recovery` | `cambium-thor-support` |
| Jaguar | `qualcommax/ipq60xx` | `cambiumnetworks_jaguar-persistent`, `cambiumnetworks_jaguar-recovery` | `cambium-jaguar-support` |
| Cheetah | `qualcommax/ipq50xx` | `cambiumnetworks_cheetah-persistent`, `cambiumnetworks_cheetah-recovery` | `cambium-cheetah-support` |
| Miami (X7-35X, X7-53X, X7-55X, X7-56X) | new IPQ5332 subtarget | no build yet | — |

Each family publishes one recovery and one persistent image. Thor's
persistent image covers the XV3-8 only until the XE5-8 flash layout has been
captured. Family images are one kernel plus every model's device tree in a single FIT,
built by the `cambium-family-fit` image command. The OEM U-Boot boots a
named configuration (`config@5`, `config@hk02`, ...), so each configuration
keeps the name used by Cambium's own family image. `verify/<family>/`
checks every configuration against its board SKU and model after each build.

The ath11k families (Thor, Cheetah, Jaguar) install `cambium-board-data`.
It copies the Wi-Fi board file that the AP's stock firmware selects for its
SKU from the retained, read-only OEM slot at boot, so no OEM board data is
distributed. Per-device calibration still comes from `0:ART`. Neither the
OEM slot nor ART is ever written; the importer refuses writable partitions.

## Family data and release manifest

`families.json` is the single source of truth for each family's models,
board SKUs, FIT configurations and hardware status. From it:

- `scripts/manifest.py` writes `cambium-manifest.json` into every build and
  fails the build if a listed configuration is missing from the built FITs;
  `publish.sh` combines the families into one release manifest.
- `scripts/gen-select-config.py` generates `select-config.sh`, published with
  each release and on the site. On the stock firmware it maps the board SKU
  to the FIT configuration for a recovery, installer or persistent image,
  and refuses unknown SKUs and images not built for the model.

Update `families.json` (and the site's tables) when a model's status or
configuration changes.

## Building

```sh
git remote add upstream https://github.com/openwrt/openwrt.git
git fetch upstream main
cambium/scripts/build.sh sage 2026.09.23.1
```

`build.sh` updates the feeds, applies `configs/common.config` and the family
config, builds, verifies the FITs, the root filesystems' release identity and
the absence of SSH keys or OEM board data, and collects everything under
`cambium-output/<family>/`.

Persistent images get OpenWrt's default package set, LuCI and the managed-AP
packages (OpenWISP, WPA-Enterprise `wpad-mbedtls`, WireGuard, OpenVPN,
usteer, lldpd, irqbalance and diagnostics). Recovery images stay minimal.

## Versioning

The upstream OpenWrt identity (`/etc/openwrt_release`) is left untouched. The
downstream build ID `YYYY.MM.DD.N` is recorded in `/etc/cambium-openwrt-release`
under the family key (`SAGE_BUILD_ID`, `THOR_BUILD_ID`, `CHEETAH_BUILD_ID`,
`JAGUAR_BUILD_ID`), together with the source and upstream commits. Each
snapshot is tagged `snapshot-YYYY.MM.DD.N`.

## Daily snapshots

`.github/workflows/cambium-snapshot.yml` runs daily at 02:17 UTC:

1. **Sync** – `scripts/sync-upstream.sh` rebases the Cambium commits onto
   upstream `main` and force-pushes the default branch. On a conflict the
   branch is left alone and an `upstream-sync` issue is opened. Upstream's
   own CI workflows are kept disabled in this fork.
2. **Build** – one job per family on a GitHub-hosted runner.
3. **Publish** – `scripts/publish.sh` creates a pre-release with the images,
   ImageBuilders and checksums, and pushes the matching apk feeds to the
   `gh-pages` branch. The newest 14 releases and 2 feeds are kept.

It can also be started by hand from the Actions tab, optionally without
syncing, for a subset of families, or forced when upstream has not changed.

### Release builds

Only snapshots are built for now. OpenWrt 25.12 uses the older qualcommax
Ethernet description (`dp1`-`dp6` NSS-DP ports rather than `swport`/`uniphy`),
so the Thor, Cheetah and Jaguar device trees would need new hardware bring-up
there. Release builds will start with the next stable series, which branches
from `main`; the sync job opens a `stable-branch` issue when upstream creates it.

### One-time repository setup

- Enable Actions for the fork.
- Settings → Pages: deploy from the `gh-pages` branch (created by the first
  publish).
- Secret `CAMBIUM_SYNC_TOKEN`: a fine-grained token for this repository with
  *Contents* and *Workflows* read/write. Without it, a rebase that brings in
  upstream workflow changes cannot be pushed.
- Secret `CAMBIUM_APK_PRIVATE_KEY`: a stable package signing key, created
  with `openssl ecparam -name prime256v1 -genkey -noout`. Without it every
  build signs with a throwaway key.

## Resolving a sync conflict

```sh
git fetch origin && git checkout main && git reset --hard origin/main
git fetch upstream main
git rebase upstream/main   # fix each conflict, git add, git rebase --continue
git push --force-with-lease origin main
```

Then close the `upstream-sync` issue; the next run continues normally.
