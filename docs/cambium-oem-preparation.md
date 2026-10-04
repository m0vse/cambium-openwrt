# Cambium OEM migration preparation

These tools inspect OEM devices and prepare essential recovery data. They never
write firmware, modify the environment, select a boot bank, attach or mount an
inactive bank, or reboot. A successful check establishes layout evidence only.
Direct OEM installation remains disabled for every model until current OEM
access, authenticated image validation, inactive-bank writes and rollback are
qualified. Stock OpenWrt qualification is reusable evidence; no OpenWISP
connection or enrollment is required.

Known unsupported models are rejected before any changes, including backup
directory creation and staging. The manifest records production admission
separately from layout evidence. Current captured models are `unqualified`,
and models with uncaptured layouts are `unsupported`; none is production
admitted. The backup entry point also requires `qualified` admission, including
when the Sage adapter is invoked directly. There is no experimental trial or
force option. Qualification fixtures are separate from production migration.

Stock OpenWrt to the destination firmware remains a separate maintained route.
These OEM preparation tools do not replace, modify or qualify its existing
sysupgrade/operator compatibility path. An OEM qualification refusal must not
disable an independently qualified stock OpenWrt migration. Identify the source
runtime first; retain its model, minimum-version, installed-updater compatibility,
image validation, unique-data preservation and rollback requirements. The two
routes can reuse model evidence while retaining their own source contracts.

## Running the checks

Place `cambium-oem-prepare.sh`, `cambium-oem-sage-prepare.sh` and
`cambium-oem-models.tsv` together. Run through the verified OEM root shell:

```sh
sh cambium-oem-prepare.sh check
```

The readers require a valid named partition table and explicit environment
configuration. The scripts pass that configuration using `fw_printenv -c`;
OEM versions without that capability stop rather than guess the reader's
compiled default. Conflicting `/etc/fw_env.config` and `/tmp/fw_env.config`
are rejected. A present binary is reported as unqualified, not assumed safe.

`inspect-capture DIRECTORY` replays private evidence on a workstation. It
reads files beneath that directory with their original relative paths, plus
`environment/image`, `environment/bootcmd` and, for E400, `environment/load_addr`.
It cannot perform a backup or authorize installation. Keep manufacturing data
and full environment captures private. Test fixtures are synthetic.

## Model coverage and remaining evidence

The schema 1 tab-separated manifest covers all 17 distinct model names in the
current stock image supported-device lists. The two E410 board aliases denote
one model. A source coverage test fails if a new source model lacks a row.
All rows have current OEM qualification and hardware migration acceptance
pending, including those with historical stock OpenWrt validation.

| Family | Exact model and SKU | Preparation implemented | Specific remaining evidence |
| --- | --- | --- | --- |
| Sage | E410 10 | Pair-layout inspection and critical capture | Current OEM tools/configuration and recovery test; fresh A-suffix manufacturing evidence was captured on OpenWiFi, not OEM |
| Sage | E410B 21 | Pair-layout inspection and critical capture | Current OEM tool compatibility; live product/SKU agreement and recovery test |
| Sage | E510 16 | Named refusal | Exact OEM identity/layout despite stock shared-tree support |
| Sage | E600 11, E430W 13, E700 14, E430H 15 | Separate manifest rows and named refusals | Each OEM NAND controller, geometry, tools, assets and boot path |
| Jaguar | XV2-2 20 | 52 MiB bank inspection | Exact offsets, inactive volumes, protected assets and current boot guard |
| Jaguar | XV2-2T1 31, XE3-4 32 | Separate 96 MiB bank entries and inspection | Exact offsets, inactive volumes, radio assets and current boot guard; XE3-4 Puma/QCN9074 assets remain model-specific |
| Jaguar | XV2-2T0 22, XE3-4TN 33 | Separate manifest rows and named refusals | Each exact OEM geometry, assets and boot path |
| Cheetah | XV2-21X 35 | 96 MiB bank inspection | Training offset, inactive volumes, environment guard and critical capture adapter |
| Cheetah | XV2-22H 34, XV2-23T 36 | Separate manifest rows and named refusals | Each exact OEM geometry, assets and boot path |
| Thor | XV3-8 19 | 96 MiB bank inspection including PHY boot command | BOOTCONFIG pair, ART, PHY firmware, inactive volumes and current boot guard |
| Gambit | E400 6 | OEM raw 3+45 MiB banks and nboot/root agreement | Raw NAND/OOB tooling; conversion differs from stock 4+44 MiB layout; MRAM purpose, watchdog and recovery; hardware unavailable |

XE5-8 and E500/E501S/E502S are not in these current image supported-device
lists. Their presence in vendor firmware does not add installer support.

## Critical recovery capture

The E410/E410B adapter implements `backup NEW_PRIVATE_DIRECTORY`, gated on
production admission and all layout checks. It is currently disabled by the
unqualified admission rows. Once qualified, it reads only the named 64 KiB `0:APPSBLENV`, `0:ART` and
`mfginfo` partitions: 192 KiB of raw data. It also saves partition and running
boot metadata, the actual environment configuration, the textual environment
and optional board SKU. The directory uses mode 0700 and files use 0600.
Short reads, insufficient space and existing destinations fail; failed captures
have no completion marker. Copy the directory privately off-device and verify
`SHA256SUMS` there. A completion marker is never permission to flash.

The exact manufacturing forms are `PL-E410XXXA-` for E410 and `PL-E410XXXB-`
for E410B, corroborated with the running SKU when exposed. The A-suffix was
captured read-only on a current OpenWiFi E410 on 4 October 2026. It establishes
manufacturing identity and 128 MiB NAND, not OEM runtime compatibility. Both
revisions have the same NAND capacity; capacity must not choose the model.
These are hardware revisions, not enclosure styles: early B units retained the
A-style case, and later B units changed enclosure without other hardware changes.
Case appearance must not choose the model either.

ART contains the two device-specific calibration regions at offsets 0x1000
and 0x5000, each length 0x2f20; radio MACs are inside those cells. Manufacturing
data holds factory wired identity. Preserve these originals byte-for-byte.
Do not derive radio MACs from arbitrary wired-MAC offsets.

Other adapters deliberately refuse automatic backups until exact critical
asset targets have been captured. Their manifest asset lists are investigation
requirements, not executable recovery recipes. Preserve complete own-device
ART, manufacturing identity, environment and minimum boot-selection metadata.
Thor also needs its PHY firmware and BOOTCONFIG records. Preserve any necessary
OEM radio board files with model/revision/source checksum provenance; reusable
identical release assets can be retained once per qualified release rather
than copied as whole firmware for every AP. Never transplant unique calibration.
E400's unidentified 32 KiB MRAM remains a specific unresolved asset.

Do not make whole-bank, whole-NAND, bootloader or irrelevant OEM configuration
backups per AP. Existing archival captures remain historical reference assets.
If an OEM file is required for radio operation, establish its exact path, size,
hash and provenance before losing that OEM bank. Environment captures can
contain credentials and must remain private.

## OEM release qualification

As checked on 4 October 2026, vendor announcements establish
[4.2.3.3 availability](https://community.cambiumnetworks.com/t/enterprise-wi-fi-access-point-release-4-2-3-3-now-available/108167)
and [7.2 support for the listed Wi-Fi 6 and 6E models](https://community.cambiumnetworks.com/t/enterprise-wi-fi-access-point-release-7-2-is-now-available/108581).
They do not establish the latest downloadable revision per hardware SKU.
The authenticated support portal listing, exact release notes and image digest
remain required. No credentials should be copied into reports or Git.

For each exact SKU record the latest applicable portal image, hardware/revision
coverage, minimum upgrade prerequisites, image size/hash, and unit `show version`.
The 7.2 notice requires staged OEM upgrades for XE3-4 revisions B/C from 6.x
through 6.6.2.1 before 7.1 or later; it also restricts downgrades of Wi-Fi 6
devices on 7.1 below 6.6.1. OEM restoration must obey the applicable notes.
Historical 4.2.3.3-r10/7.2-r1 captures establish only those observed baselines.
Version floors should reflect a proven capability contract; version alone
does not prove shell access, signed-container acceptance or updater compatibility.
Current OEM UI upload/signature acceptance remains unqualified.

## Authenticating firmware payloads

The workstation helper `cambium-oem-verify-bundle.py` verifies a detached
SHA256 signature over schema 1 `manifest.json`, then verifies the exact kernel
and rootfs lengths/hashes and model/SKU/compatible tuple. Supply the release
signing public key through an independent trusted channel; a key inside the
bundle is rejected. The helper freezes the manifest/signature/key bytes before
verification and parsing. It refuses duplicate roles, traversal, symlinks,
substituted content and mismatched model identifiers.

```sh
python3 cambium-oem-verify-bundle.py PRIVATE_BUNDLE \
  --public-key INDEPENDENTLY_TRUSTED_RELEASE_PUBLIC_KEY \
  --model E410 --sku-hex 0000000a
```

The signed manifest has `schema: 1`, `model`, `sku_hex`, `image_compatible`
and a `payloads` array with exactly one `kernel` and one `rootfs` record, each
containing `role`, direct `file` name, positive integer `size` and lowercase
`sha256`. This is a generic authentication layer, not a new certificate issuer.
No actual deployment signing key is configured or generated by these tools.
Python and this workstation OpenSSL helper are not OEM runtime dependencies.

Successful authentication still reports `write_enabled: false`: actual image
format/FIT configuration/rootfs semantics, live inactive capacity, OEM tools,
protected targets and rollback have to pass before any installation. Signature
verification does not prove a bootable or model-compatible FIT by itself.

## Standalone Sage source inspection

`scripts/cambium-oem-sage-storage-check.sh` checks the reviewed OEM release
and that `/root` resides on the active writable UBIFS root without a covering
mount. It does not create a directory or authorize a writer. The destination
installer chooses its private state path and authenticates its runtime separately.

`scripts/cambium-oem-sage-context.sh` emits seven tab-separated fields: canonical
factory label MAC, family, exact model, active bank, pending target, pending
transaction digest and pending image digest. The last three are empty when no
transaction exists. It reads the reviewed manufacturing TLV directly, validates
pending state as a complete transaction, and does not load converted-stock
libraries. Both helpers support read-only `check` and `inspect-capture ROOT`.
Fixture tests cover these interfaces; OEM runtime and hardware acceptance remain
required before production admission.

## Inactive Sage pair staging implementation

`scripts/lib/cambium-sage-pair-write.sh` implements the controller-neutral
inactive-pair staging primitive for authenticated FIT plus SquashFS/UBIFS
payloads. It verifies fixed IDs, running bank/attachment, geometry, mounts,
inactive-only capacity, payload length/magic, root and kernel readback and
unchanged protected volume geometry. Restoration may reclaim only the inactive
67-LEB overlay; SquashFS staging recreates that bank's overlay. It never writes
the environment, selects a boot, reboots or touches bootloader code. No production
entrypoint loads it and no model becomes qualified by its presence.

The qualified caller must additionally establish exact manufacturing identity,
OEM version/tools, authenticated frozen payloads, FIT/UBIFS semantics, private
critical recovery, guarded selection/defaults and incoming identity handoff.
The library's admission state is a caller precondition, not an authentication
mechanism or force option. It is not a complete installer or factory reset.
Shared NVRAM reset/OEM first-boot behavior and reviewed OEM environment defaults
remain separate prerequisites.

`scripts/tests/test_cambium_sage_pair_write.py` executes the actual shell library
with isolated replacement UBI commands. Both banks, mutation/sync failures,
corrupt readback and pre-write refusals retain active-bank/key/factory sentinels
and never report completion after failure. These fixtures do not prove physical
NAND power-loss recovery or bootloader behavior.

## Shared OEM recovery firmware

Maintain one private, verified recovery firmware set per exact model and
hardware variant, with a matching OEM kernel and root filesystem or qualified
vendor recovery container. Each AP's recovery manifest references that shared
set by immutable digests. Do not duplicate it per AP. A family firmware may be
shared only where the exact variants are explicitly qualified; otherwise keep
separate model entries. A/B hardware revisions and region restrictions remain
part of the compatibility record.

Prefer the authenticated vendor image as provenance. If the set comes from a
reference AP, establish that its firmware payloads contain no unique device
identity, key, calibration or customer configuration before sharing. Keep all
reference dumps private until that review passes. Raw whole-NAND/OOB archives
are not automatically flashable firmware payloads. Record original container
hash, extracted payload hashes, format, geometry, exact destinations and the
accepted restore tool/version; see `cambium-oem-recovery.template.json`.

The shared set must also contain reviewed model/version-specific U-Boot
environment defaults. OEM restoration restores the normal OEM boot command,
bank selection, boot arguments and any required guard/boot-selection metadata,
and removes migration-specific overrides. For Sage the historical OEM command
is `bootipq`; for Thor the PHY-loading default must also be retained. These
observations do not establish a complete defaults template for a new OEM release.
Verify every proposed variable against that release's captured/default boot
behavior before applying it. Record and read back the exact intended environment
transaction before reboot. Preserve the old working boot route until restoration
and rollback preparation pass.

Do not replace the AP's complete environment with a donor dump or blindly run
`env default -a`: environment can hold unique MACs, serial, manufacturing data
and board-specific settings. Merge the approved OEM defaults with this AP's own
critical identity and remove only explicitly identified migration variables.
Recovery does not replace U-Boot executable code. If this AP's original OEM
environment is unavailable, qualify the model defaults and the exact unique
fields independently; current OpenWiFi environment is not an OEM defaults backup.

OEM recovery is a deliberate factory reset: restore the shared OEM firmware
and reviewed OEM U-Boot defaults, retain the affected AP's own calibration and
manufacturing identity, and restore necessary original boot-selection metadata.
Do not replay another
device's environment, MACs, serial or client keys. Whole OEM configuration is
unnecessary. Never overwrite bootloader or factory partitions to perform the
reset. The currently running good bank remains untouched while the inactive
OEM candidate is written and verified using the exact qualified adapter.

If a device has lost both bootable banks, ordinary Linux inactive-bank recovery
is unavailable. Require the exact validated external recovery route and named
operator approval; do not invent serial/U-Boot/TFTP access from a console
setting. The factory-reset/shared-firmware policy does not remove this blocker.

## Adding a model

1. Reuse its reviewed stock OpenWrt board definition, image compatibility,
   radio and calibration evidence. Add a row using the manifest template;
   keep unknown fields `-`. Do not copy another model's geometry.
2. Capture exact product/SKU, OEM version and shell access, partition labels
   with offsets/sizes/erase geometry, running-bank evidence and reader config.
   Identify the minimal unique recovery assets and verified reusable radio files.
3. Supply synthetic captures for both banks and refusals for conflicting
   identities, layouts, attachments and environment state. Extend a family
   adapter only when its storage or boot behavior actually differs.
4. Qualify authenticated image compatibility, inactive-only writes/readback,
   durable rollback, watchdog behavior and every interruption boundary on named
   recoverable hardware. A stock updater test does not qualify the OEM updater.
5. Record the successful OEM baseline and capability contract. Enable deployment
   only after controller-neutral checks and the destination's separate identity
   and first-boot acceptance contract pass. Do not add controller logic here.
   Change production admission to `qualified` only with that acceptance evidence;
   adding a profile or passing fixtures never enables production admission.

Run `python3 -m unittest discover -s scripts/tests -p 'test_cambium_oem*.py'`
and shell syntax checks. Tests cover source-manifest completeness, both running
banks, differing capacities and unsafe evidence. They do not prove OEM execution,
critical backup I/O on hardware, inactive writes, reset survival or controller
acceptance.

## Recovery and the first hardware test

A spare E410B with working OEM root access, Linux serial output, controlled
power and a verified preserved OEM bank is the first qualification candidate. Approval must
name the AP and authorize restoration, flash and reboot separately from these
read-only checks. Do not concurrently reset hardware reserved by another task.

Before any restoration record actual running/confirmed banks, verify which
bank still contains OEM and its own release identity, verify critical hashes
off-device, and qualify root/serial/power recovery. If no OEM bank survives,
obtain the exact applicable OEM image and a validated restoration adapter first;
these preparation tools cannot restore it. Do not run generic sysupgrade on OEM.

For a preserved OEM bank, use only the exact family's qualified selector after
approval, retaining the running bank until OEM boots and is verified. Then
capture the current OEM state again and test one inactive-bank migration.
Never write bootloader, calibration or factory identity. Production first-boot
acceptance must first persist the old OEM default before starting the candidate. A power cycle can
then return to OEM; automatic recovery from a kernel hang additionally requires
proven watchdog/reset behavior. `bootcount` alone is insufficient. Interruptions
before/after each write, boot selection, first boot and confirmation remain
qualification work performed separately from production migration. Production
has no trial mode for unsupported hardware. No flashing commands are published here because that
current OEM qualification has not been established.
