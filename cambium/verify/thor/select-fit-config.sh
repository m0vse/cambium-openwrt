#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
	echo "Usage: $0 THOR_FIT.itb BOARD_SKU_DECIMAL" >&2
	exit 2
fi
fit=$1
sku=$2
test -s "$fit"
flavor=${THOR_FLAVOR:-recovery}

case "$sku" in
	19) model='Cambium Networks XV3-8'; compatible='cambiumnetworks,xv3-8'; config='config@hk02' ;;
	30)
		[ "$flavor" = recovery ] || {
			echo 'Thor persistent FIT rejects unvalidated XE5-8 SKU 30' >&2
			exit 1
		}
		model='Cambium Networks XE5-8'; compatible='cambiumnetworks,xe5-8'; config='config@hk01.c6'
		;;
	*) echo "Thor FIT rejects unknown board SKU: $sku" >&2; exit 1 ;;
esac

fdt=$(fdtget -t s "$fit" "/configurations/$config" fdt)
work_dir=$(mktemp -d)
trap 'rm -r "$work_dir"' EXIT HUP INT TERM
fdtget -t r "$fit" "/images/$fdt" data > "$work_dir/board.dtb"

actual_sku=$(fdtget -t x "$work_dir/board.dtb" /cambium-platform board-sku)
actual_model=$(fdtget -t s "$work_dir/board.dtb" / model)
actual_compatible=$(fdtget -t s "$work_dir/board.dtb" / compatible | awk '{print $1}')
test "$(printf '%d' "0x$actual_sku")" = "$sku" || {
	echo "Thor FIT tree $fdt has SKU $actual_sku, expected $sku" >&2
	exit 1
}
test "$actual_model" = "$model" || {
	echo "Thor FIT tree $fdt has model $actual_model, expected $model" >&2
	exit 1
}
test "$actual_compatible" = "$compatible" || {
	echo "Thor FIT tree $fdt has compatible $actual_compatible, expected $compatible" >&2
	exit 1
}

printf '%s\n' "$config"
