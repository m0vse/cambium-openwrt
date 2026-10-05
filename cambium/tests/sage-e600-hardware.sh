#!/bin/sh
# Source checks complement the compiled-DTB checks in verify-family-fit.sh.
set -eu
top=${CAMBIUM_TEST_TOP:-$(cd "$(dirname "$0")/../.." && pwd)}
base=$top/target/linux/ipq40xx
tree=$base/dts/qcom-ipq4019-sage-e600.dtsi
test -f "$tree" || { echo 'FAIL: E600 has no isolated hardware include'; exit 1; }
for mode in recovery persistent; do
	grep -q '#include "qcom-ipq4019-sage-e600.dtsi"' "$base/dts/qcom-ipq4019-sage-e600-$mode.dts"
done
grep -q 'reg = <0x80000000 0x10000000>' "$tree"
grep -q 'reg = <0x9000 0x2f20>' "$tree"
grep -q 'reg = <0x0 0x8000000>' "$tree"
grep -q 'perst-gpios = <&tlmm 38 GPIO_ACTIVE_LOW>' "$tree"
grep -q 'ath10k-firmware-qca9984' "$base/image/generic.mk"
grep -q 'lan_mac=$(mtd_get_mac_text mfginfo 0x6 12)' "$base/base-files/etc/board.d/02_network"
. "$base/base-files/lib/functions/cambium-sage.sh"
cambium_sage_board cambiumnetworks,e600
test "$SAGE_QUALIFIED" = 0
work=$(mktemp -d)
trap 'rm -r "$work"' EXIT HUP INT TERM
sed -n '/^ipq40xx_setup_macs()/,/^}/p' "$base/base-files/etc/board.d/02_network" > "$work/macs.sh"
. "$work/macs.sh"
mtd_get_mac_text() {
	test "$*" = 'mfginfo 0x6 12' || return 1
	echo '02:00:00:00:00:60'
}
ucidef_set_interface_macaddr() { test "$1" = lan; MAC_SEEN=$2; }
ucidef_set_label_macaddr() { LABEL_SEEN=$1; }
MAC_SEEN= LABEL_SEEN=
ipq40xx_setup_macs cambiumnetworks,e600
test "$MAC_SEEN" = 02:00:00:00:00:60
test "$LABEL_SEEN" = 02:00:00:00:00:60
for model in e410 e410b e510 e430h e430w e700; do
	MAC_SEEN= LABEL_SEEN=
	ipq40xx_setup_macs "cambiumnetworks,$model" || :
	test -z "$MAC_SEEN$LABEL_SEEN"
	for mode in recovery persistent; do
		if grep -q 'sage-e600.dtsi' "$base/dts/qcom-ipq4019-sage-$model-$mode.dts"; then
			echo "FAIL: $model inherits E600 hardware"; exit 1
		fi
	done
done
echo 'ok: isolated E600 hardware and persistent-write refusal'
