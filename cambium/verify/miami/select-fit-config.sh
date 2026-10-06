#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
	echo "Usage: $0 MIAMI_FAMILY_FIT.itb BOARD_SKU_DECIMAL" >&2
	exit 2
fi
fit=$1
sku=$2
test -s "$fit"

# The recovery FIT has the OEM configuration name; the persistent FIT names
# the Cambium A/B tree (the per-bank trees share its device tree source).
case "$sku" in
	44) model=X7-35X; base=mi01.6-acadia ;;
	*) echo "Miami FIT rejects unknown board SKU: $sku" >&2; exit 1 ;;
esac
config=config@$base
fdtget -l "$fit" /configurations | grep -qx "$config" || config=config@$base-ab
fdt=fdt@${config#config@}

actual_fdt=$(fdtget -t s "$fit" "/configurations/$config" fdt)
test "$actual_fdt" = "$fdt" || {
	echo "Miami FIT configuration $config points to $actual_fdt, expected $fdt" >&2
	exit 1
}

work_dir=$(mktemp -d)
trap 'rm -r "$work_dir"' EXIT HUP INT TERM
fdtget -t r "$fit" "/images/$fdt" data > "$work_dir/board.dtb"
actual_sku=$(fdtget -t x "$work_dir/board.dtb" /cambium-platform board-sku)
actual_model=$(fdtget -t s "$work_dir/board.dtb" / model)
test "$(printf '%d' "0x$actual_sku")" = "$sku" || {
	echo "Miami FIT tree $fdt has SKU $actual_sku, expected $sku" >&2
	exit 1
}
test "$actual_model" = "Cambium Networks $model" || {
	echo "Miami FIT tree $fdt has model $actual_model, expected $model" >&2
	exit 1
}

printf '%s\n' "$config"
