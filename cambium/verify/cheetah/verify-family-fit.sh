#!/bin/sh
set -eu
if [ "$#" -ne 1 ]; then echo "Usage: $0 cheetah-family-recovery.itb" >&2; exit 2; fi
fit=$1
selector=$(dirname "$0")/select-fit-config.sh
expected='config@mp03.3-cheetah
config@mp03.3-ocelot
config@mp03.3-lynx'
test "$(fdtget -l "$fit" /configurations)" = "$expected"
test "$(fdtget -t s "$fit" /images/kernel@1 arch)" = arm64
test "$(fdtget -t s "$fit" /images/kernel@1 compression)" = none
test "$(fdtget -t s "$fit" /configurations default)" = config@mp03.3-ocelot
for sku in 34 35 36; do sh "$selector" "$fit" "$sku"; done
if sh "$selector" "$fit" 99 >/dev/null 2>&1; then
	echo "Selector accepted unknown SKU 99" >&2
	exit 1
fi

work_dir=$(mktemp -d)
trap 'rm -r "$work_dir"' EXIT HUP INT TERM
for item in mp03.3-cheetah:34:XV2-22H mp03.3-ocelot:35:XV2-21X mp03.3-lynx:36:XV2-23T; do
	node=${item%%:*}; rest=${item#*:}; sku=${rest%%:*}; model=${rest#*:}
	dtb=$work_dir/$node.dtb
	fdtget -t r "$fit" "/images/fdt@$node" data > "$dtb"
	test "$(fdtget -t s "$dtb" / model)" = "Cambium Networks $model"
	actual=$(fdtget -t x "$dtb" /cambium-platform board-sku)
	test "$(printf '%d' "0x$actual")" = "$sku"
	# Recovery must not carry a persistent root selection.
	if fdtget "$dtb" /chosen bootargs-append 2>/dev/null | grep -q 'ubi.mtd=rootfs'; then
		echo "$model recovery tree selects persistent rootfs" >&2
		exit 1
	fi
done
printf 'Cheetah recovery FIT has three explicit known-SKU mappings; unknown SKUs are rejected.\n'
