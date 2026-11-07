#!/bin/sh
# Exercise the real firmware hotplug dispatch for the Cheetah candidate models.
set -eu
cd "$(dirname "$0")/../.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
cat > "$work/caldata.sh" <<'LIB'
board_name() { echo "$TEST_BOARD"; }
caldata_extract() { printf '%s %s %s\n' "$1" "$2" "$3"; }
LIB
sed 's|^\. /lib/functions/caldata.sh$|. "$CALDATA_TEST_LIB"|'  target/linux/qualcommax/ipq50xx/base-files/etc/hotplug.d/firmware/11-ath11k-caldata > "$work/hotplug.sh"
for board in xv2-21x xv2-22h xv2-23t; do
 for spec in IPQ5018:c000000:0x1000 QCN6122:b00a040:0x26800; do
  chip=${spec%%:*}; rest=${spec#*:}; addr=${rest%%:*}; offset=${rest#*:}
  got=$(TEST_BOARD="cambiumnetworks,$board" CALDATA_TEST_LIB="$work/caldata.sh"    FIRMWARE="ath11k/$chip/hw1.0/cal-ahb-$addr.wifi.bin" sh "$work/hotplug.sh")
  [ "$got" = "0:ART $offset 0x20000" ] || {
   echo "$board/$chip: unexpected extraction: $got" >&2; exit 1;
  }
 done
done
echo 'Cheetah calibration dispatch: six cases passed'
