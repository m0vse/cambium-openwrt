#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
	echo "Usage: $0 FAMILY_FIT.itb BOARD_SKU_DECIMAL" >&2
	exit 2
fi
fit=$1
sku=$2
test -s "$fit"

case "$sku" in
	20) model=XV2-2; config=config@cp01-c1; fdt=fdt@cp01-c1 ;;
	22) model=XV2-2T0; config=config@cp01-c1-1; fdt=fdt@cp01-c1-2T ;;
	31) model=XV2-2T1; config=config@cp01-c1-2; fdt=fdt@cp01-c1-2T1 ;;
	32) model=XE3-4; config=config@cp01-c3-xv3-4; fdt=fdt@cp01-c3-xv3-4 ;;
	33) model=XE3-4TN; config=config@cp01-c3-2; fdt=fdt@cp01-c3-2 ;;
	*) echo "Jaguar FIT rejects unknown board SKU: $sku" >&2; exit 1 ;;
esac

actual_fdt=$(fdtget -t s "$fit" "/configurations/$config" fdt)
test "$actual_fdt" = "$fdt" || {
	echo "Jaguar FIT configuration $config points to $actual_fdt, expected $fdt" >&2
	exit 1
}

work_dir=$(mktemp -d)
trap 'rm -r "$work_dir"' EXIT HUP INT TERM
fdtget -t r "$fit" "/images/$fdt" data > "$work_dir/board.dtb"
actual_sku=$(fdtget -t x "$work_dir/board.dtb" /cambium-platform board-sku)
actual_model=$(fdtget -t s "$work_dir/board.dtb" / model)
test "$(printf '%d' "0x$actual_sku")" = "$sku" || {
	echo "Jaguar FIT tree $fdt has SKU $actual_sku, expected $sku" >&2
	exit 1
}
test "$actual_model" = "Cambium Networks $model" || {
	echo "Jaguar FIT tree $fdt has model $actual_model, expected $model" >&2
	exit 1
}

printf '%s\n' "$config"
