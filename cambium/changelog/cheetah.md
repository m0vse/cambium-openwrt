# Cheetah changelog

XV2-21X (validated); XV2-22H, XV2-23T (RAM boot only).

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
