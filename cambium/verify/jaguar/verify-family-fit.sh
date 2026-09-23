#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
	echo "Usage: $0 jaguar-family-initramfs.itb" >&2
	exit 2
fi
fit=$1
selector=$(dirname "$0")/select-fit-config.sh
flavor=${JAGUAR_FLAVOR:-recovery}
case "$flavor" in
	recovery|persistent) ;;
	*) echo "Unknown Jaguar FIT flavor: $flavor" >&2; exit 2 ;;
esac

expected='config@cp01-c1
config@cp01-c1-1
config@cp01-c1-2
config@cp01-c3-xv3-4
config@cp01-c3-2'
actual=$(fdtget -l "$fit" /configurations)
test "$actual" = "$expected" || {
	echo "FIT configuration list does not match the five Jaguar models" >&2
	printf 'Actual:\n%s\n' "$actual" >&2
	exit 1
}

test "$(fdtget -t s "$fit" /images/kernel@1 arch)" = arm64
test "$(fdtget -t s "$fit" /images/kernel@1 compression)" = gzip
test "$(fdtget -t s "$fit" /configurations default)" = config@cp01-c1-2

for sku in 20 22 31 32 33; do
	config=$(sh "$selector" "$fit" "$sku")
	printf '%s -> %s\n' "$sku" "$config"
done

if sh "$selector" "$fit" 99 >/dev/null 2>&1; then
	echo "Selector accepted unknown SKU 99" >&2
	exit 1
fi

work_dir=$(mktemp -d)
trap 'rm -r "$work_dir"' EXIT HUP INT TERM
check_gpio() {
	gpio_node=$1
	gpio_pin_expected=$2
	gpio_flags_expected=$3
	set -- $(fdtget -t x "$dtb" "$gpio_node" gpios)
	test "$#" -eq 3
	test "$2" = "$gpio_pin_expected"
	test "$3" = "$gpio_flags_expected"
}
check_label() {
	test "$(fdtget -t s "$dtb" "$1" label)" = "$2"
}
for fdt in cp01-c1 cp01-c1-2T cp01-c1-2T1 cp01-c3-xv3-4 cp01-c3-2; do
	dtb=$work_dir/$fdt.dtb
	fdtget -t r "$fit" "/images/fdt@$fdt" data > "$dtb"
	for partition in 510000 520000 5c0000 660000 6e0000 700000; do
		fdtget "$dtb" \
			"/soc@0/spi@78b5000/flash@0/partitions/partition@$partition" \
			read-only >/dev/null
	done
	for partition in 6000000 c000000 f000000; do
		fdtget "$dtb" \
			"/soc@0/nand-controller@79b0000/nand@0/partitions/partition@$partition" \
			read-only >/dev/null
	done
	# The OEM 7.2 controller runs BCH8/516-byte codewords despite its
	# running tree's 4-bit request. Keep diagnostic and future images aligned.
	test "$(fdtget -t s "$dtb" /soc@0/nand-controller@79b0000 compatible)" = \
		qcom,ipq6018-nand
	test "$(fdtget -t x "$dtb" /soc@0/nand-controller@79b0000/nand@0 nand-ecc-strength)" = 8
	if fdtget "$dtb" /soc@0/nand-controller@79b0000/nand@0 \
		qcom,boot-partitions >/dev/null 2>&1; then
		echo "$fdt unexpectedly enables NAND codeword fixup" >&2
		exit 1
	fi
	if [ "$flavor" = recovery ]; then
		fdtget "$dtb" \
			/soc@0/spi@78b5000/flash@0/partitions/partition@6f0000 \
			read-only >/dev/null
		fdtget "$dtb" \
			/soc@0/nand-controller@79b0000/nand@0/partitions/partition@0 \
			read-only >/dev/null
		if fdtget "$dtb" /chosen bootargs-append >/dev/null 2>&1; then
			echo "$fdt unexpectedly carries a persistent-root bootargs-append" >&2
			exit 1
		fi
	else
		if fdtget "$dtb" \
			/soc@0/spi@78b5000/flash@0/partitions/partition@6f0000 \
			read-only >/dev/null 2>&1; then
			echo "$fdt keeps the boot environment read-only" >&2
			exit 1
		fi
		if fdtget "$dtb" \
			/soc@0/nand-controller@79b0000/nand@0/partitions/partition@0 \
			read-only >/dev/null 2>&1; then
			echo "$fdt keeps the OpenWrt slot read-only" >&2
			exit 1
		fi
		bootargs=$(fdtget -t s "$dtb" /chosen bootargs-append)
		case "$bootargs" in
			*'ubi.mtd=rootfs root=/dev/ubiblock0_1 rootfstype=squashfs rootwait'*) ;;
			*) echo "$fdt has wrong persistent root arguments" >&2; exit 1 ;;
		esac
	fi
	test "$(fdtget -t x "$dtb" /keys/reset linux,code)" = 198
	test "$(fdtget -t x "$dtb" /keys/reset debounce-interval)" = 3c
	check_gpio /keys/reset 13 1
	check_gpio /leds/status-gpio73 49 0
	check_gpio /leds/status-white 38 0
	check_gpio /leds/status-gpio37 25 0
	check_gpio /leds/status-amber 23 0
	check_label /leds/status-gpio73 jaguar:status:red
	check_label /leds/status-white jaguar:status:green
	check_label /leds/status-gpio37 jaguar:status:orange
	check_label /leds/status-amber jaguar:status:blue
	test "$(fdtget -t s "$dtb" /aliases led-boot)" = /leds/status-gpio37
	test "$(fdtget -t s "$dtb" /aliases led-failsafe)" = /leds/status-gpio73
	test "$(fdtget -t s "$dtb" /aliases led-running)" = /leds/status-white
	test "$(fdtget -t s "$dtb" /aliases led-upgrade)" = /leds/status-gpio37
	check_gpio /leds/usb 32 0
done

printf 'Jaguar %s FIT has five validated mappings, scoped storage and common LED/button controls.\n' "$flavor"
