# Jaguar changelog

XV2-2, XV2-2T1 (validated); XV2-2T0, XE3-4, XE3-4TN (RAM boot only).

## 2026.09.25.1

- **Fix:** an upgrade keeps a hostname set by hand or by OpenWISP.
- The XE3-4 has no sysupgrade yet: upstream OpenWrt's XE3-4 image shares its
  board name.

## 2026.09.25.0

- VLAN filtering on the LAN bridge: only untagged VLAN 1 on `lan1` (and
  `lan2`), management on `br-lan.1`.
- A/B validated on the XV2-2 and XV2-2T1, and moved onto the shared
  `cambium-ab` package; the `jaguar-ab-*` commands become `cambium-ab-*`.

## 2026.09.24.3

- **Fix:** the A/B sysupgrade creates its UBI device nodes in stage 2 (the
  first XV2-2 upgrade stopped after formatting the inactive bank).
- Installs work in either slot; `update-upgrader` installs a release's A/B
  scripts on a running system.

## 2026.09.24.2

- A/B firmware banks with a trial boot, automatic rollback, a one-time
  conversion and a per-bank device-data vault; the XV2-2's 128 MiB NAND with
  two 52 MiB banks.

## Before the snapshots (22–23 September 2026)

- 22 September: XV2-2T1 first RAM boot, then the reset button, LEDs and
  radios, and a persistent trial.
- 23 September: persistent image qualified on the XV2-2T1.
