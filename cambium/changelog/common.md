# Common changelog

Changes that apply to every family.

## Unreleased

- Release notes list only the changes of the families built in that
  snapshot (and the changes common to all).
- New RRM measurement agent (`cambium-rrm-agent`) on every family, the
  first step towards automatic channel and power planning. Every five
  minutes it records each radio's channel, width, noise, busy time and
  client count into `/tmp/cambium-rrm/latest.json`. These are passive
  readings the radio already keeps: nothing leaves the operating channel
  and clients are not affected. Only a family with a dedicated scanning
  radio (Thor) also scans for neighbouring networks, and only with that
  radio. Turn it off with `uci set cambium_rrm.agent.enabled=0`.
- An AP whose VLAN trunk OpenWISP set up now has its IPv6 management
  interface (`lan6`) on untagged VLAN 1 as well, like a fresh install. The
  trunk templates configure only IPv4, which left `lan6` on the filtered
  bridge where it received nothing. OpenWISP can still override it.

## 2026.09.26.0

- The OpenWISP status LED service records the managed state even on a unit
  without status LEDs, so an upgrade commit that waits for OpenWISP is never
  blocked by a missing LED driver.

## 2026.09.25.1

- Every persistent image passes a release gate before publishing: the build
  unpacks the image's own root filesystem and fails unless LuCI, uHTTPd,
  OpenWISP, WireGuard, the full wpad and the family's support packages are
  installed. An installed-package manifest is published beside each image.
- The daily snapshot runs once, at 19:17 UTC, instead of at 02:17 with a
  06:17 backstop.
- Installer advice for serving the release files names `cambium-serve.py`.
- The installer checks both firmware banks' sizes and NAND offsets on every
  family before writing, and Cheetah's `0:TRAINING` partition.
- The A/B boot guard checks DHCP on the interface the LAN is configured on,
  so a missing VLAN bridge fails the health check instead of passing on
  `br-lan`.

## 2026.09.25.0

- The stock firmware's hostname, the model and the last six hex digits of the
  MAC address (for example `E410-ABABAB`), on every family.
- One shared A/B firmware bank package (`cambium-ab`) with the same commands
  on every family: `cambium-ab-status`, `cambium-ab-convert` and the boot
  guard.
- One shared OpenWISP status LED service (`cambium-openwisp-led`): blue
  while the controller answers, green otherwise.
- The installer uploads its backups to the computer serving the release
  (`cambium-serve.py`), so the stock firmware's root password is never
  needed; gluebi volumes no longer confuse its partition lookup.
- `cambium-install.sh stock` makes the stock firmware the default boot again
  on an unconverted install.

## 2026.09.24.3

- One-command installer (`cambium-install.sh`) for every family: `ram`,
  `install` and `update-upgrader`, with backups, checksum and read-back
  checks and an exact reason for every failure.

## 2026.09.24.2

- Untested models are offered only the RAM (recovery) image, with a
  read-only hardware report (`cambium-report.sh`) to send back.

## 2026.09.24.0

- Project site on GitHub Pages with the models, statuses and install
  procedures for every family.
- Family manifest (`families.json`) and a SKU-based selector
  (`select-config.sh`) that picks each model's boot configuration.
- Recovery (RAM) images published only for recovery devices.

## 2026.09.23.0

- First automated snapshot: one recovery and one persistent image per
  family, built daily from upstream OpenWrt `main` with the Cambium patches
  rebased on top.
