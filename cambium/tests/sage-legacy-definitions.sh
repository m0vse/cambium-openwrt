#!/bin/sh
# Legacy E410 images and trees must not shadow the Sage family images.
set -eu

top=$(cd "$(dirname "$0")/../.." && pwd)
image=$top/target/linux/ipq40xx/image/generic.mk
dts=$top/target/linux/ipq40xx/dts

if grep -Eq '^define Device/cambium_e410(-recovery)?$|^TARGET_DEVICES \+= cambium_e410(-recovery)?$' "$image"; then
	echo 'FAIL: legacy E410 image definitions remain' >&2
	exit 1
fi

for legacy in "$dts"/qcom-ipq4019-e410.dts "$dts"/qcom-ipq4019-e410-recovery.dts "$dts"/qcom-ipq4019-e410.dtsi; do
	if [ -e "$legacy" ]; then
		echo "FAIL: legacy E410 tree remains: $legacy" >&2
		exit 1
	fi
done

for model in e410 e410b e510; do
	for mode in persistent recovery; do
		file=$dts/qcom-ipq4019-sage-$model-$mode.dts
		[ -f "$file" ] || { echo "FAIL: missing $file" >&2; exit 1; }
		grep -q '#include "qcom-ipq4019-sage-shared.dtsi"' "$file" || {
			echo "FAIL: Sage tree does not use shared include: $file" >&2
			exit 1
		}
	done
done

echo 'ok: legacy E410 definitions removed; Sage trees retained'
