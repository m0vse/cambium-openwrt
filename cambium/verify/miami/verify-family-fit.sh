#!/bin/sh
set -eu
if [ "$#" -ne 1 ]; then echo "Usage: $0 miami-family.itb" >&2; exit 2; fi
fit=$1
flavor=${MIAMI_FLAVOR:-recovery}
selector=$(dirname "$0")/select-fit-config.sh
case "$flavor" in
recovery)
	expected='config@mi01.6-acadia'
	default=config@mi01.6-acadia
	trees='mi01.6-acadia:recovery'
	;;
persistent)
	expected='config@mi01.6-acadia-slot0
config@mi01.6-acadia-slot1
config@mi01.6-acadia-ab'
	default=config@mi01.6-acadia-slot0
	trees='mi01.6-acadia-slot0:slot0 mi01.6-acadia-slot1:slot1 mi01.6-acadia-ab:ab'
	;;
*) echo "Unknown Miami flavor: $flavor" >&2; exit 2 ;;
esac
test "$(fdtget -l "$fit" /configurations)" = "$expected"
test "$(fdtget -t s "$fit" /images/kernel@1 arch)" = arm64
test "$(fdtget -t s "$fit" /images/kernel@1 compression)" = lzma
test "$(fdtget -t s "$fit" /configurations default)" = "$default"
sh "$selector" "$fit" 44 >/dev/null
if sh "$selector" "$fit" 99 >/dev/null 2>&1; then
	echo "Selector accepted unknown SKU 99" >&2
	exit 1
fi

# partitions DTB: "path label" for every flash partition in the tree (the
# NOR and the SPI NAND sit one level below their SPI controllers).
partitions() {
	local dtb=$1 ctrl flash p
	for ctrl in $(fdtget -l "$dtb" /soc@0 2>/dev/null); do
		for flash in $(fdtget -l "$dtb" "/soc@0/$ctrl" 2>/dev/null); do
			fdtget -l "$dtb" "/soc@0/$ctrl/$flash/partitions" 2>/dev/null | while read -r p; do
				echo "/soc@0/$ctrl/$flash/partitions/$p $(fdtget -t s "$dtb" "/soc@0/$ctrl/$flash/partitions/$p" label)"
			done
		done
	done
}
read_only() {
	local path
	path=$(echo "$2" | awk -v l="$3" '$2 == l { print $1; exit }')
	[ -n "$path" ] || { echo "no partition labelled $3" >&2; exit 1; }
	fdtget "$1" "$path" read-only >/dev/null 2>&1
}

work_dir=$(mktemp -d)
trap 'rm -r "$work_dir"' EXIT HUP INT TERM
for item in $trees; do
	node=${item%%:*}; role=${item#*:}
	dtb=$work_dir/$node.dtb
	fdtget -t r "$fit" "/images/fdt@$node" data > "$dtb"
	test "$(fdtget -t s "$fit" "/configurations/config@$node" fdt)" = "fdt@$node"
	test "$(fdtget -t s "$dtb" / model)" = "Cambium Networks X7-35X"
	test "$(printf '%d' "0x$(fdtget -t x "$dtb" /cambium-platform board-sku)")" = 44
	parts=$(partitions "$dtb")
	for label in 0:SBL1 0:MIBIB 0:APPSBL 0:CDT 0:ART mfginfo 0:QSEE 0:NVRAM crashLog; do
		read_only "$dtb" "$parts" "$label" || { echo "X7-35X $role: $label is writable" >&2; exit 1; }
	done
	# What each tree may write: its own bank(s) and, outside RAM, the env.
	case "$role" in
	recovery) writable= ;;
	slot0) writable='rootfs 0:APPSBLENV' ;;
	slot1) writable='rootfs_1 0:APPSBLENV' ;;
	ab) writable='rootfs rootfs_1 0:APPSBLENV' ;;
	esac
	for label in rootfs rootfs_1 0:APPSBLENV; do
		case " $writable " in
		*" $label "*) ! read_only "$dtb" "$parts" "$label" || { echo "X7-35X $role: $label is read-only" >&2; exit 1; } ;;
		*) read_only "$dtb" "$parts" "$label" || { echo "X7-35X $role: $label is writable" >&2; exit 1; } ;;
		esac
	done
done
printf 'Miami %s FIT: X7-35X trees with their own SKU and model, unknown SKUs rejected, and each tree writes only its own bank(s).\n' "$flavor"
