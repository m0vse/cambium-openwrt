# Cheetah changelog

XV2-21X (validated); XV2-23T (RAM bring-up confirmed; persistent/A/B untested);
XV2-22H (inferred candidate; not hardware tested).

## Unreleased

- Neutralize the captured Cheetah v2.7.5b OEM bootcount bank-switch sentinel
  before inactive-bank writes and legacy boot rearming. Validate the surviving
  OEM image selector, read back count zero, and save both in the trial prefix.
  Covers RAM staging and persistent installation; not yet hardware-tested.
- Gate candidate/OEM execution on successful environment writes and save.
  Apply OEM counter/selector preflight to both legacy health outcomes only;
  converted A/B boots retain their independent slot policy.

## 2026.11.07.0

- XV2-23T RAM bring-up confirmed with build 2026.11.07.2: DHCP/SSH,
  routing/DNS, unit-specific board/calibration import and passive reception
  on both Wi-Fi 6 radios. Full radio/AP operation remains unvalidated.
- Extend the MDIO sibling-clock guard, radio/calibration dispatch and
  management VLAN startup to XV2-23T. Persistent installation and A/B should
  work from shared Cheetah support, but remain untested on this hardware.
- Infer XV2-22H PCS/radio/calibration and management startup from captured OEM
  evidence. Physical ports, memory/flash and PoE remain unverified.

## 2026.09.26.0

- XV2-21X A/B build and sysupgrade marked validated: installed from the
  stock firmware, converted, and switched banks through OpenWISP.

## 2026.09.25.1

- **Fix:** an upgrade keeps a hostname set by hand or by OpenWISP.
- The installer checks the `0:TRAINING` partition and both banks' offsets.

## 2026.09.25.0

- Cheetah moves onto the shared A/B banks (96 MiB at `0x80000` and
  `0x6080000`), with the bank selected by the boot command's kernel
  arguments and a device-data vault. Management on `br-lan.1` with VLAN
  filtering.

## 2026.09.24.0

- One persistent image for all three models, each booting its own device
  tree.

## Before the snapshots (21–22 September 2026)

- 21 September: XV2-21X hardware capture and first RAM boot; Ethernet fixed
  by the MDIO1 clock reference.
- 22 September: Wi-Fi, LEDs and reset button; persistent one-stock-slot
  release 2026.09.22.2 with a boot guard, onboarded to OpenWISP.
