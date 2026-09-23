#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
	echo "Usage: $0 SAGE_FAMILY_FIT.itb BOARD_SKU_DECIMAL" >&2
	exit 2
fi
fit=$1
sku=$2
test -s "$fit"

case "$sku" in
	10) model=E410; config=config@5; fdt=fdt@e410 ;;
	11) model=E600; config=config@10; fdt=fdt@e600 ;;
	13) model=E430W; config=config@13; fdt=fdt@e430w ;;
	14) model=E700; config=config@14; fdt=fdt@e700 ;;
	15) model=E430H; config=config@15; fdt=fdt@e430h ;;
	16) model=E510; config=config@16; fdt=fdt@e510 ;;
	21) model=E410B; config=config@17; fdt=fdt@e410b ;;
	*) echo "Sage FIT rejects unknown board SKU: $sku" >&2; exit 1 ;;
esac

actual_fdt=$(fdtget -t s "$fit" "/configurations/$config" fdt)
test "$actual_fdt" = "$fdt" || {
	echo "Sage FIT configuration $config points to $actual_fdt, expected $fdt" >&2
	exit 1
}

work_dir=$(mktemp -d)
trap 'rm -r "$work_dir"' EXIT HUP INT TERM
fdtget -t r "$fit" "/images/$fdt" data > "$work_dir/board.dtb"
actual_sku=$(fdtget -t x "$work_dir/board.dtb" /cambium-platform board-sku)
actual_model=$(fdtget -t s "$work_dir/board.dtb" / model)
test "$(printf '%d' "0x$actual_sku")" = "$sku" || {
	echo "Sage FIT tree $fdt has SKU $actual_sku, expected $sku" >&2
	exit 1
}
test "$actual_model" = "Cambium Networks $model" || {
	echo "Sage FIT tree $fdt has model $actual_model, expected $model" >&2
	exit 1
}

printf '%s\n' "$config"
