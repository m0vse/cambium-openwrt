#!/bin/sh
# Sage leaf trees use model-specific OpenWrt IDs; old E410 images stay accepted.
set -eu

top=$(cd "$(dirname "$0")/../.." && pwd)
base=$top/target/linux/ipq40xx

for model in e410 e410b e510 e600 e700 e430w e430h; do
	for mode in persistent recovery; do
		file=$base/dts/qcom-ipq4019-sage-$model-$mode.dts
		grep -q "compatible = \"cambiumnetworks,$model\"" "$file" || {
			echo "FAIL: $model $mode does not have its own primary board ID" >&2
			exit 1
		}
	done
done

grep -q 'cambium,e410|cambiumnetworks,e410)' "$base/base-files/lib/functions/cambium-sage.sh" || {
	echo 'FAIL: Sage board table does not accept new and legacy E410 IDs' >&2
	exit 1
}
grep -q 'SUPPORTED_DEVICES := .*cambium,e410.*cambiumnetworks,e410b' "$base/image/generic.mk" || {
	echo 'FAIL: installed E410 compatibility is missing from sysupgrade metadata' >&2
	exit 1
}

for helper in sage-migration-mark-good sage-migration-rollback-oem; do
	grep -q 'cambium,e410|cambiumnetworks,e410|cambiumnetworks,e410b' \
		"$top/package/cambium/cambium-sage-support/files/$helper" || {
		echo "FAIL: $helper does not accept all E410 IDs" >&2
		exit 1
	}
done

work=$(mktemp -d)
trap 'rm -r "$work"' EXIT HUP INT TERM
python3 "$top/cambium/scripts/gen-select-config.py" "$top/cambium/families.json" > "$work/select-config.sh"
printf '\000\000\000\025' > "$work/sku"
CAMBIUM_SKU_NODE="$work/sku" sh "$work/select-config.sh" recovery > "$work/selection" || {
	echo 'FAIL: generated selector refuses E410B recovery' >&2
	exit 1
}
grep -qx "MODEL='E410B'" "$work/selection" &&
	grep -qx "CONFIG='config@17'" "$work/selection" || {
	echo 'FAIL: generated selector does not choose E410B config@17' >&2
	exit 1
}

echo 'ok: model-specific Sage board IDs and installed E410 compatibility'
