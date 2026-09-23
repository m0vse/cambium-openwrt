#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
	echo "Usage: $0 sage-family-initramfs.itb" >&2
	exit 2
fi
fit=$1
selector=$(dirname "$0")/select-fit-config.sh
flavor=${SAGE_FLAVOR:-recovery}
case "$flavor" in
	recovery|persistent) ;;
	*) echo "Unknown Sage flavor: $flavor" >&2; exit 2 ;;
esac

expected='config@5
config@10
config@13
config@14
config@15
config@16
config@17'
if [ "$flavor" = persistent ]; then
	expected="$expected
config@ap.dk01.1-c2"
fi
actual=$(fdtget -l "$fit" /configurations)
test "$actual" = "$expected" || {
	echo "FIT configuration list does not match the seven Sage models" >&2
	printf 'Actual:\n%s\n' "$actual" >&2
	exit 1
}

test "$(fdtget -t s "$fit" /images/kernel@1 arch)" = arm
test "$(fdtget -t s "$fit" /images/kernel@1 compression)" = none
test "$(fdtget -t s "$fit" /configurations default)" = config@5

for sku in 10 11 13 14 15 16 21; do
	config=$(sh "$selector" "$fit" "$sku")
	printf '%s -> %s\n' "$sku" "$config"
done
if sh "$selector" "$fit" 99 >/dev/null 2>&1; then
	echo "Selector accepted unknown SKU 99" >&2
	exit 1
fi

work_dir=$(mktemp -d)
trap 'rm -r "$work_dir"' EXIT HUP INT TERM
for board in e410 e510 e410b; do
	dtb=$work_dir/$board.dtb
	fdtget -t r "$fit" "/images/fdt@$board" data > "$dtb"
	if [ "$flavor" = recovery ]; then
		fdtget "$dtb" \
			/soc/spi@78b5000/flash@0/partitions/partition@e0000 \
			read-only >/dev/null
		fdtget "$dtb" \
			/soc/spi@78b5000/nand@1/partitions/partition@0 \
			read-only >/dev/null
	else
		if fdtget "$dtb" /soc/spi@78b5000/flash@0/partitions/partition@e0000 read-only >/dev/null 2>&1; then exit 1; fi
		if fdtget "$dtb" /soc/spi@78b5000/nand@1/partitions/partition@0 read-only >/dev/null 2>&1; then exit 1; fi
	fi
done
for board in e600 e430w e700 e430h; do
	dtb=$work_dir/$board.dtb
	fdtget -t r "$fit" "/images/fdt@$board" data > "$dtb"
	if [ "$flavor" = recovery ]; then
		test "$(fdtget -t s "$dtb" /soc/nand-controller@79b0000 status)" = disabled
	else
		test "$(fdtget -t s "$dtb" /soc/nand-controller@79b0000 status)" = okay
	fi
	if [ "$flavor" = recovery ]; then
		for partition in e0000 170000 180000 1c0000; do
			fdtget "$dtb" \
				"/soc/spi@78b5000/flash@0/partitions/partition@$partition" \
				read-only >/dev/null
		done
	fi
done

test "$(fdtget -t x "$work_dir/e410.dtb" /memory reg)" = '80000000 10000000'
test "$(fdtget -t x "$work_dir/e600.dtb" /memory reg)" = '80000000 20000000'
test "$(fdtget -t x "$work_dir/e510.dtb" /soc/spi@78b5000 cs-gpios | awk '{print $5}')" = 4
test "$(fdtget -t x "$work_dir/e600.dtb" /soc/pinctrl@1000000/phy-reset gpios | awk '{print $1}')" = 29
test "$(fdtget -t x "$work_dir/e430w.dtb" /soc/pinctrl@1000000/phy-reset gpios | awk '{print $1}')" = 31

printf 'Sage %s FIT has seven explicit mappings and model-specific hardware descriptions.\n' "$flavor"
