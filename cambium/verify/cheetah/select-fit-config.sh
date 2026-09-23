#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
	echo "Usage: $0 CHEETAH_FAMILY_FIT.itb BOARD_SKU_DECIMAL" >&2
	exit 2
fi
fit=$1
sku=$2
test -s "$fit"

case "$sku" in
	34) model=XV2-22H; config=config@mp03.3-cheetah; fdt=fdt@mp03.3-cheetah ;;
	35) model=XV2-21X; config=config@mp03.3-ocelot; fdt=fdt@mp03.3-ocelot ;;
	36) model=XV2-23T; config=config@mp03.3-lynx; fdt=fdt@mp03.3-lynx ;;
	*) echo "Cheetah FIT rejects unknown board SKU: $sku" >&2; exit 1 ;;
esac

actual_fdt=$(fdtget -t s "$fit" "/configurations/$config" fdt)
test "$actual_fdt" = "$fdt" || {
	echo "Cheetah FIT configuration $config points to $actual_fdt, expected $fdt" >&2
	exit 1
}

work_dir=$(mktemp -d)
trap 'rm -r "$work_dir"' EXIT HUP INT TERM
fdtget -t r "$fit" "/images/$fdt" data > "$work_dir/board.dtb"
actual_sku=$(fdtget -t x "$work_dir/board.dtb" /cambium-platform board-sku)
actual_model=$(fdtget -t s "$work_dir/board.dtb" / model)
test "$(printf '%d' "0x$actual_sku")" = "$sku" || {
	echo "Cheetah FIT tree $fdt has SKU $actual_sku, expected $sku" >&2
	exit 1
}
test "$actual_model" = "Cambium Networks $model" || {
	echo "Cheetah FIT tree $fdt has model $actual_model, expected $model" >&2
	exit 1
}

printf '%s\n' "$config"
