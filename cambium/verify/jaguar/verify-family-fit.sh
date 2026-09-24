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
	nand=/soc@0/nand-controller@79b0000/nand@0/partitions
	# Per-model NAND layout and ECC. The XV2-2 has a 128 MiB Winbond NAND
	# with 64-byte OOB: BCH4 and two 52 MiB banks, slot 1 at 0x3400000. The
	# other trees keep the XV2-2T1's BCH8 (OEM 7.2 runs BCH8/516-byte
	# codewords) and two 96 MiB banks, slot 1 at 0x6000000.
	if [ "$fdt" = cp01-c1 ]; then
		ecc=4; bank1=3400000; protected='6800000 7800000'
		test "$(fdtget -t x "$dtb" "$nand/partition@0" reg)" = '0 3400000'
		test "$(fdtget -t x "$dtb" "$nand/partition@3400000" reg)" = '3400000 3400000'
		test "$(fdtget -t x "$dtb" "$nand/partition@6800000" reg)" = '6800000 1000000'
		test "$(fdtget -t x "$dtb" "$nand/partition@7800000" reg)" = '7800000 800000'
		for partition in 6000000 c000000 f000000; do
			if fdtget "$dtb" "$nand/partition@$partition" reg >/dev/null 2>&1; then
				echo "$fdt keeps a 256 MiB partition at $partition" >&2
				exit 1
			fi
		done
	else
		ecc=8; bank1=6000000; protected='c000000 f000000'
		test "$(fdtget -t x "$dtb" "$nand/partition@0" reg)" = '0 6000000'
		test "$(fdtget -t x "$dtb" "$nand/partition@6000000" reg)" = '6000000 6000000'
	fi
	# NVRAM and crashLog are never firmware banks.
	for partition in $protected; do
		fdtget "$dtb" "$nand/partition@$partition" read-only >/dev/null
	done
	test "$(fdtget -t s "$dtb" /soc@0/nand-controller@79b0000 compatible)" = \
		qcom,ipq6018-nand
	test "$(fdtget -t x "$dtb" /soc@0/nand-controller@79b0000/nand@0 nand-ecc-strength)" = "$ecc"
	if fdtget "$dtb" /soc@0/nand-controller@79b0000/nand@0 \
		qcom,boot-partitions >/dev/null 2>&1; then
		echo "$fdt unexpectedly enables NAND codeword fixup" >&2
		exit 1
	fi
	if [ "$flavor" = recovery ]; then
		fdtget "$dtb" \
			/soc@0/spi@78b5000/flash@0/partitions/partition@6f0000 \
			read-only >/dev/null
		for partition in 0 $bank1; do
			fdtget "$dtb" "$nand/partition@$partition" read-only >/dev/null
		done
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
		# A/B: both firmware banks are writable and U-Boot selects the bank,
		# so the tree must not append a fixed ubi.mtd= root.
		for partition in 0 $bank1; do
			if fdtget "$dtb" "$nand/partition@$partition" read-only >/dev/null 2>&1; then
				echo "$fdt keeps firmware bank $partition read-only" >&2
				exit 1
			fi
		done
		if fdtget "$dtb" /chosen bootargs-append >/dev/null 2>&1; then
			echo "$fdt appends fixed root arguments; U-Boot must select the bank" >&2
			exit 1
		fi
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
