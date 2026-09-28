# Common changelog

Changes that apply to every family.

## 2026.09.28.0

- The RRM agent reports each radio's network addresses (BSSIDs), so
  OpenWISP's radio planning recognises all of an AP's own networks in other
  APs' scans, including those monitoring lists without an address.
- **Fix:** publishing a snapshot pruned the newest release instead of the
  oldest once 14 existed, deleting the build it had just published
  (`snapshot-2026.09.27.1`).
- Release builds: Cambium on OpenWrt's final stable releases, from the first
  series after 25.12. Each series gets a `cambium-X.Y` branch that only
  moves forward (point releases merged, fixes cherry-picked from `main`);
  builds are tagged `release-X.Y.Z-N`, published as release candidates and
  promoted once validated on hardware. The snapshot workflow starts the
  release workflow when upstream publishes a final release. Images record
  `CAMBIUM_CHANNEL` (`snapshot` or `release`) in
  `/etc/cambium-openwrt-release`, and the site lists release builds beside
  snapshots.

## 2026.09.27.1

- On an AP whose VLAN trunk OpenWISP already set up, the first boot after an
  upgrade also moves the OpenWISP agent's management interface from the
  legacy `br-lan` to `br-lan.1`, as it did for `lan6`: the old value named
  the filtered bridge, which carries no management address. Only exactly
  `br-lan` is changed; `wg0` and any other value are kept.
- The RRM agent no longer puts the device key on `curl`'s command line,
  where any process on the AP could read it while an upload ran. It passes
  the header in `curl`'s configuration on stdin instead.

## 2026.09.27.0

- The RRM agent escapes backslashes in network names correctly under
  BusyBox's awk: a hidden network whose name `iw` prints as `\x00…` made
  the whole report invalid JSON. Such a name is now reported as hidden.
- The RRM agent stops at once when its service is stopped or restarted,
  instead of being killed after its wait between measurements, and a
  measurement lock left by a run that was killed is taken over as soon as
  that run's process is gone.
- Each radio in the RRM report now carries its actual transmit power
  (`txpower`, after the country's limits) and how strongly it hears its
  clients (`client_signal`: weakest, median and strongest), for transmit
  power recommendations.

## 2026.09.26.4

- The RRM agent runs one measurement at a time: a `cambium-rrm-agent
  --once` by hand waits for the service's current run, instead of the two
  sharing the scanning interface and writing a mixed-up report.
- The RRM report includes every scanned channel's survey (noise, busy
  and active time) as `channels`, from Thor's scanning radio at every
  measurement and from the scheduled scans elsewhere, so OpenWISP can show
  how busy each channel is, not only the AP's own.

## 2026.09.26.3

- The RRM agent marks the AP's own networks in its scan results with
  `"own": true`, so they can be told apart from real neighbours. They stay
  in the list because hearing them confirms they are on the air.
- One set of first-boot defaults for every family, in recovery images as
  well: the AP never offers DHCP or IPv6 router advertisements to the site
  (Sage had no such step, so its router advertisements are now off too),
  and irqbalance spreads interrupts over all CPU cores (it was on only on
  Sage; Thor, Jaguar and Cheetah now use it too). The hostname step is one
  shared script instead of a copy per target.
- The RRM agent can scan for neighbouring networks on every family, at
  set times (`cambium_rrm.agent.scan_times`, e.g. `02:00 03:00 04:00`; off
  by default). Each scan takes a serving radio off its channel for a few
  seconds. A radio with clients waits for the next time, but always scans
  at the last one. DFS channels are included. Each neighbour now records
  which radio heard it and when, and the results stay in
  `/tmp/cambium-rrm/latest.json` until that radio's next scan. On Thor the
  scanning radio still scans every five minutes, and `scan_times` is not
  used.
- The RRM agent sends each measurement to OpenWISP, using the device ID
  and key `openwisp-config` registered with, so the server can build
  statistics from them. An AP not registered with OpenWISP sends nothing.
  Turn it off with `uci set cambium_rrm.agent.upload=0`.

## 2026.09.26.2

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
