# Cheetah bring-up and candidate support — 7 November 2026

## XV2-23T status

**Persistent installation and A/B booting are expected to work with high
confidence; direct XV2-23T hardware validation is pending.** Shared Cheetah
support and the observed RAM bring-up provide enough
evidence to proceed to an OpenWiFi build. This does not establish full stock
OpenWrt validation. Qualification flags and persistent/sysupgrade metadata
remain untested.

Stock RAM build `2026.11.07.2`, source
`11b719d2ca6d485c145774a6a31965ee32a3bb9f`, uses Linux 6.18.60 and upstream
`606ee33b8a049244759de735a48e98b00ec8ad5c`. On one SKU36 unit running OEM
7.2-r1 before the trial, the following were observed:

- Correct lynx identity and boot; DHCP, SSH, gateway routing and DNS work.
- Ethernet links at 100 Mb/s; the attached peer advertises only 10/100, as
  in this unit's OEM capture. Gigabit operation was not tested on this link.
- Twenty 1400-byte gateway pings completed with no loss. Two existing RX
  length errors did not increase during that test; no CRC errors were seen.
- MDIO remains accessible after unused-clock cleanup. Its required sibling
  clock has an active reference.
- The AP imports b24-lynx and b60.stock from its own retained OEM firmware.
  Both running calibration files match this unit's backed-up ART data.
- IPQ5018 2.4 GHz and QCN6122 5 GHz PHYs initialize with two antenna chains
  and HE support. Passive scans receive neighboring BSSs on both bands.
  Temporary test interfaces were removed; default SSIDs remain disabled.
- Status LED devices and the GPIO button driver bind. Physical colour and
  button press/release tests remain pending.
- After the one-shot boot, the environment is back at bootipq, image1 and
  bootcount0. Actual failed-boot fallback and persistent storage were not tested.

AP transmission, client association/traffic, settings across reboot, physical
GPIO behaviour and actual A/B boot/rollback remain acceptance work. Passive
reception does not establish AP operation or throughput.

## Corrected model-specific gaps

The first 23T trial reached a green LED but did not obtain DHCP. Its inherited
DTS declared the sibling MDIO clock, while the production driver enabled that
clock only when the machine matched XV2-21X. The corrected guard also matches
XV2-23T; broad clk_ignore_unused is not used. A regression harness compiles
the production patch's added C block. The old guard fails 23T; the new guard
passes eight model/error cases. The actual delivered recovery kernel payload
was also checked for the new 23T match, and live MDIO/networking now work.

XV2-23T radio enablement/variants, ART calibration dispatch and management VLAN
startup also have explicit model support. The remaining XV2-21X-only reset-register
diagnostic block is not the clock consumer and was not extended blindly.
The PHY's mandatory RX/TX clocks, netdev label rename, DHCP protocol argument,
MAC provider and environment CRC were checked.

## Persistent installation and A/B tools

The model table recognizes SKU36/lynx and the captured two 96 MiB bank layout.
Persistent trees leave the two firmware banks and environment writable while
protecting calibration, bootloaders, training, NVRAM and crash logs. The 23T
health contract expects its management bridge and both radio PHYs, without
promoting its hardware qualification flag.

- OEM persistent installation is available through `cambium-install.sh
  --trial ... install`; the explicit trial option permits untested persistent
  candidates. Board/SKU, geometry, backup and image readback checks still run.
- Conversion is available through `cambium-ab-convert --allow-untested
  --oem-sha256 HASH --yes`. It requires a verified data-only backup hash of the
  specific OEM bank; an OOB-inclusive full-NAND archive is not that bank hash.
- Conversion replaces the retained OEM bank with the second OpenWrt bank.
  Following conversion, sysupgrade writes the inactive bank and arms a trial
  with the previously confirmed bank as fallback. OEM retention and two
  OpenWrt banks are distinct stages of this two-bank layout.
- These tool paths are covered by simulations, including XV2-23T persistent
  staging, conversion and upgrades in both directions. They are not physical
  proof of XV2-23T persistent installation or A/B rollback.
- Recovery RAM images have no five-minute automatic reboot timer. The
  one-shot restores OEM as the next-boot default; a manual reboot/power cycle
  returns there. Persistent boot-guard behaviour is separate.

### Initial-install entry points

The currently tested recovery image intentionally makes both firmware banks
and the environment read-only. MTD numbers also change between OEM and
OpenWrt: resolve exact partition labels and current sysfs geometry/flags for
every write. Do not reuse numeric indices from an OEM report.

The supported generic Cheetah initial-install path runs `install --trial`
from the OEM root shell. A separately built persistent-initramfs FIT also
exists in stock build 2026.11.07.2; its lynx tree leaves both banks and the
environment writable while protecting ART/boot regions. This exact RAM FIT
passed the persistent family FIT/protection checks, but has not been booted
on 23T. It can support an explicit OEM-staged one-shot writable-RAM bridge.
Check staging-volume capacity because this FIT is larger than recovery.

`cambium-install.sh --persistent-test` is currently implemented for Jaguar
only; Cheetah explicitly rejects that option. The presence of a Cheetah
persistent-RAM artifact does not make that generic flag a supported path.
The OpenWiFi installer owns its reviewed bridge/staging procedure. No direct
bank-formatting operation should be attempted from the read-only recovery
session, and no broad protection bypass is part of this stock procedure.

The operator intends to move directly to OpenWiFi. The OpenWiFi family task
owns that build and must audit its own SDK/kernel and model checks. Actual
acceptance should establish a working persistent bank, boot each bank, test
failed-trial rollback and preserve settings/device data. Permanent OEM
retention is not an operator requirement once safe A/B operation is established.

## XV2-22H inferred candidate

SKU34/mp03.3-cheetah is inferred from the captured OEM tree and shared firmware
setup script. Source enables its PCS and both radios, uses XV2-22H calibration
variants, handles ART extraction and applies multi-port management startup.
The candidate DTS compiles. QCA8K and QCA UNIPHY PCS are already built into the
current kernel; a missing package entry was not a missing driver binary.

The OEM tree describes an internal PHY plus a QCA8337 on MDIO1, reset GPIO39,
MDC/MDIO GPIO36/37, CPU port6 and four switch PHY lanes. This is not a claim of
four exposed jacks: the [official data sheet](https://brandcentral.cambiumnetworks.com/asset/25db5a08-4529-4a3e-a5a1-aeaeb81a3124/XV2-22H-Wi-Fi-6-Access-Point-Data-Sheet.pdf)
lists one GE WAN and two GE LAN ports. Physical jack numbering, actual RAM/flash,
the existing second MAC offset and PoE polarity/sequencing remain unmeasured.
PoE controls are left undriven. XV2-22H remains an inferred, untested candidate.

## OEM shell and evidence handling

OEM 7.2-r1 BusyBox tar has no `-z`: use `tar -cf`. Large binary uploads should
use streaming `curl -T`, with nohup/redirection for long console operations;
buffering the 264 MiB NAND dump through --data-binary was killed. Do not ask
operators to hash diagnostic text reports. Binary backup/firmware integrity
checks remain appropriate.

Raw reports, board/calibration binaries, full flash backups, boot logs and
neighbor scan data are retained privately outside Git. No proprietary board
files or unit calibration data are redistributed in these source changes.
