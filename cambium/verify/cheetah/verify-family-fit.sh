#!/bin/sh
set -eu
if [ "$#" -ne 1 ]; then echo "Usage: $0 cheetah-family.itb" >&2; exit 2; fi
fit=$1
flavor=${CHEETAH_FLAVOR:-recovery}
case "$flavor" in recovery|persistent) ;; *) echo "Unknown Cheetah flavor: $flavor" >&2; exit 2 ;; esac
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

# partitions DTB: "path label" for every flash partition in the tree.
partitions() {
	local dtb=$1 base node
	for base in $(fdtget -l "$dtb" /soc@0 2>/dev/null | sed 's|^|/soc@0/|'); do
		for node in $(fdtget -l "$dtb" "$base" 2>/dev/null); do
			fdtget -l "$dtb" "$base/$node/partitions" 2>/dev/null | while read -r p; do
				echo "$base/$node/partitions/$p $(fdtget -t s "$dtb" "$base/$node/partitions/$p" label)"
			done
		done
	done
}
# read_only DTB PARTITIONS LABEL: true when the partition labelled LABEL is
# read-only; fails (and says so) when no partition has that label.
read_only() {
	local path
	path=$(echo "$2" | awk -v l="$3" '$2 == l { print $1; exit }')
	[ -n "$path" ] || { echo "no partition labelled $3" >&2; exit 1; }
	fdtget "$1" "$path" read-only >/dev/null 2>&1
}

work_dir=$(mktemp -d)
trap 'rm -r "$work_dir"' EXIT HUP INT TERM
for item in mp03.3-cheetah:34:XV2-22H mp03.3-ocelot:35:XV2-21X mp03.3-lynx:36:XV2-23T; do
	node=${item%%:*}; rest=${item#*:}; sku=${rest%%:*}; model=${rest#*:}
	dtb=$work_dir/$node.dtb
	fdtget -t r "$fit" "/images/fdt@$node" data > "$dtb"
	test "$(fdtget -t s "$dtb" / model)" = "Cambium Networks $model"
	actual=$(fdtget -t x "$dtb" /cambium-platform board-sku)
	test "$(printf '%d' "0x$actual")" = "$sku"
	# Neither flavour appends a root: U-Boot selects the bank with ubi.mtd=.
	if fdtget "$dtb" /chosen bootargs-append 2>/dev/null | grep -q 'ubi.mtd='; then
		echo "$model $flavor tree appends a fixed ubi.mtd root" >&2
		exit 1
	fi
	parts=$(partitions "$dtb")
	for label in 0:TRAINING 0:NVRAM crashLog 0:ART 0:SBL1 0:APPSBL; do
		read_only "$dtb" "$parts" "$label" || { echo "$model $flavor: $label is writable" >&2; exit 1; }
	done
	for label in rootfs rootfs_1 0:APPSBLENV; do
		if [ "$flavor" = recovery ]; then
			read_only "$dtb" "$parts" "$label" || { echo "$model recovery: $label is writable" >&2; exit 1; }
		else
			! read_only "$dtb" "$parts" "$label" || { echo "$model persistent: $label is read-only" >&2; exit 1; }
		fi
	done
done
printf 'Cheetah %s FIT has three explicit known-SKU mappings, unknown SKUs are rejected, and its partitions are protected for the flavour.\n' "$flavor"
