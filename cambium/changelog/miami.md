# Miami changelog

X7-35X (validated: RAM boot and persistent install beside the stock
firmware; A/B conversion and sysupgrade not yet tested); X7-53X, X7-55X,
X7-56X (no build yet).

## Unreleased

- First Miami build: OpenWrt on the IPQ5332 (new `qualcommbe/ipq53xx`
  subtarget) with one recovery and one persistent image for the family.
- X7-35X: wired Ethernet with DHCP on the LAN port, and all three radios
  (2.4 GHz on the IPQ5332, 5 and 6 GHz on the QCN9224). Their firmware,
  board files and regulatory database are staged at boot from the unit's
  own stock firmware, then from the bank's device-data vault; the
  5/6 GHz board file follows the configured Wi-Fi country.
- `cambium-install.sh` RAM-boots, installs into whichever bank the stock
  firmware is not running from, and `upgrade` reinstalls keeping the
  settings (interim, until A/B sysupgrade is tested on Miami); the
  boot guard keeps OpenWrt the boot after each healthy start, and
  `cambium-ab-stock --yes` makes the stock firmware the default again.
- Not yet: the second Ethernet port, Bluetooth/Zigbee and the LEDs.
