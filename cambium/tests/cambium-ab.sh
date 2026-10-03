#!/bin/sh
# Simulation tests for the shared Cambium A/B code (package cambium-ab) and
# every family module (Jaguar, Cheetah, Thor, Sage): board tables and the identity
# preflight, boot commands, the inactive-bank writer and its platform.sh
# dispatch, the boot guard, the one-time conversion and the device-data vault
# in cambium-board-data. The real scripts run against simulated MTD/UBI
# devices, sysfs, device tree and U-Boot environment; fault injection covers
# failed and interrupted writes. Nothing touches the host's flash.
#
# Usage: cambium/tests/cambium-ab.sh   (exit status 0 when all pass)

set -u

top=$(cd "$(dirname "$0")/../.." && pwd)
base=$top/target/linux/qualcommax/ipq60xx/base-files
ab_pkg=$top/package/cambium/cambium-ab/files
jaguar_module_dir=$top/package/cambium/cambium-jaguar-support/files
board_data=$top/package/cambium/cambium-board-data/files/cambium-board-data
S=$(mktemp -d)
trap 'rm -rf "$S"' EXIT HUP INT TERM
pass=0 fail=0
LEB=126976

# --- simulated tools -------------------------------------------------------------
mkdir -p "$S/bin"
cat > "$S/bin/_sim" <<'EOF'
S=${JAGUAR_SIM:?}
LEB=126976
# Every mutating operation counts; fail_at makes the Nth one fail, as a
# power cut or flash error at that point would.
fail_point() {
	n=$(( $(cat "$S/opcount" 2>/dev/null || echo 0) + 1 ))
	echo "$n" > "$S/opcount"
	[ -f "$S/fail_at" ] && [ "$(cat "$S/fail_at")" = "$n" ] && { echo "$1 failed (injected)" >&2; exit 1; }
	:
}
ubi_mtd() { cat "$S/sys/ubi/$1/mtd_num"; }
# Sysupgrade stage 2 has no hotplug: with $S/no_hotplug, attaching a device
# or creating a volume makes its sysfs entry but no new /dev node. Nodes that
# already exist are kept.
hotplug() { [ ! -f "$S/no_hotplug" ]; }
need_node() { [ -e "$1" ] || { echo "error while opening \"$1\": No such file or directory" >&2; exit 1; }; }
refresh() { # refresh UBI_DEV MTD
	rm -rf "$S/sys/ubi/$1"_*
	echo "250:${1#ubi}" > "$S/sys/ubi/$1/dev"
	hotplug && touch "$S/dev/$1"
	for n in "$S/flash/mtd$2"/*.name; do
		[ -f "$n" ] || continue
		v=$(basename "$n" .name)
		mkdir -p "$S/sys/ubi/$1_$v"
		cp "$n" "$S/sys/ubi/$1_$v/name"
		cp "$S/flash/mtd$2/$v.size" "$S/sys/ubi/$1_$v/data_bytes"
		echo "$(( $(cat "$S/flash/mtd$2/$v.size") / 126976 ))" > "$S/sys/ubi/$1_$v/reserved_ebs"
		echo 126976 > "$S/sys/ubi/$1_$v/usable_eb_size"
		echo "251:$v" > "$S/sys/ubi/$1_$v/dev"
		hotplug && ln -sf "$S/flash/mtd$2/$v.data" "$S/dev/$1_$v"
	done
	used=0
	for f in "$S/flash/mtd$2"/*.size; do [ -f "$f" ] && used=$((used + $(cat "$f") / LEB)); done
	echo "$(( $(cat "$S/bank_lebs" 2>/dev/null || echo 724) - used ))" > "$S/sys/ubi/$1/avail_eraseblocks"
	:
}
EOF
tool() { cat > "$S/bin/$1"; chmod +x "$S/bin/$1"; }

tool ubiattach <<'EOF'
#!/bin/sh
. "$(dirname "$0")/_sim"
[ "$1" = -m ] || exit 2
for d in "$S"/sys/ubi/ubi[0-9]*; do
	case "${d##*/}" in *_*) continue ;; esac
	[ -f "$d/mtd_num" ] && [ "$(cat "$d/mtd_num")" = "$2" ] && exit 1
done
k=0; while [ -d "$S/sys/ubi/ubi$k" ]; do k=$((k + 1)); done
mkdir -p "$S/sys/ubi/ubi$k" "$S/flash/mtd$2"
echo "$2" > "$S/sys/ubi/ubi$k/mtd_num"
refresh "ubi$k" "$2"
echo "attach mtd$2" >> "$S/calls"
EOF
tool ubidetach <<'EOF'
#!/bin/sh
. "$(dirname "$0")/_sim"
[ ! -f "$S/detach_stays" ] || exit 0
for d in "$S"/sys/ubi/ubi[0-9]*; do
	case "${d##*/}" in *_*) continue ;; esac
	[ "$(cat "$d/mtd_num")" = "$2" ] || continue
	k=${d##*/}; rm -rf "$S/sys/ubi/$k" "$S/sys/ubi/$k"_*; rm -f "$S/dev/$k" "$S/dev/$k"_*
	echo "detach mtd$2" >> "$S/calls"
	[ ! -f "$S/detach_false_error" ] || { echo 'error 22 (Invalid argument)' >&2; exit 255; }
	exit 0
done
exit 1
EOF
tool ubiformat <<'EOF'
#!/bin/sh
. "$(dirname "$0")/_sim"
m=${1##*/mtd}
for d in "$S"/sys/ubi/ubi[0-9]*; do
	case "${d##*/}" in *_*) continue ;; esac
	[ -f "$d/mtd_num" ] && [ "$(cat "$d/mtd_num")" = "$m" ] && { echo 'attached' >&2; exit 1; }
done
fail_point ubiformat
rm -rf "$S/flash/mtd$m"; mkdir -p "$S/flash/mtd$m"
echo formatted > "$S/dev/mtd$m"
echo "format mtd$m" >> "$S/calls"
EOF
tool ubimkvol <<'EOF'
#!/bin/sh
. "$(dirname "$0")/_sim"
need_node "$1"
dev=${1##*/}; shift
m=$(ubi_mtd "$dev"); id= name= size=
while [ $# -gt 0 ]; do
	case "$1" in -n) id=$2; shift ;; -N) name=$2; shift ;; -s) size=$2; shift ;; -m) size=max ;; esac
	shift
done
if [ -z "$id" ]; then
	id=0
	while [ -f "$S/flash/mtd$m/$id.name" ]; do id=$((id + 1)); done
fi
fail_point ubimkvol
used=0
for f in "$S/flash/mtd$m"/*.size; do [ -f "$f" ] && used=$((used + $(cat "$f") / LEB)); done
avail=$(( $(cat "$S/bank_lebs" 2>/dev/null || echo 724) - used ))
if [ "$size" = max ]; then lebs=$avail; else lebs=$(( (size + LEB - 1) / LEB )); fi
[ "$lebs" -le "$avail" ] && [ "$lebs" -gt 0 ] || { echo 'no space' >&2; exit 1; }
echo "$name" > "$S/flash/mtd$m/$id.name"
echo $((lebs * LEB)) > "$S/flash/mtd$m/$id.size"
: > "$S/flash/mtd$m/$id.data"
refresh "$dev" "$m"
echo "mkvol mtd$m $id $name" >> "$S/calls"
EOF
tool ubirsvol <<'EOF'
#!/bin/sh
. "$(dirname "$0")/_sim"
need_node "$1"
dev=${1##*/}; shift
m=$(ubi_mtd "$dev"); id= size=
while [ $# -gt 0 ]; do
	case "$1" in -n) id=$2; shift ;; -s) size=$2; shift ;; esac
	shift
done
[ -f "$S/flash/mtd$m/$id.size" ] || exit 1
[ "$size" -le "$(cat "$S/flash/mtd$m/$id.size")" ] || exit 1
fail_point ubirsvol
echo "$(( (size + LEB - 1) / LEB * LEB ))" > "$S/flash/mtd$m/$id.size"
refresh "$dev" "$m"
echo "resize mtd$m $id $size" >> "$S/calls"
EOF
tool ubiupdatevol <<'EOF'
#!/bin/sh
. "$(dirname "$0")/_sim"
if [ "$1" = -t ]; then
	shift
	need_node "$1"
	vol=${1##*/}; k=${vol%_*}; v=${vol##*_}; m=$(ubi_mtd "$k")
	fail_point ubiupdatevol
	: > "$S/flash/mtd$m/$v.data"
	echo "truncate mtd$m $v" >> "$S/calls"
	exit 0
fi
len=
[ "$1" = -s ] && { len=$2; shift 2; }
need_node "$1"
vol=${1##*/}; k=${vol%_*}; v=${vol##*_}; m=$(ubi_mtd "$k")
# Like the real tool, a character-device source needs an explicit length.
[ -n "$len" ] || [ ! -L "$2" ] || { echo 'no length for a device source' >&2; exit 1; }
fail_point ubiupdatevol
if [ -n "$len" ]; then head -c "$len" "$2"; else cat "$2"; fi > "$S/flash/mtd$m/$v.data.new" &&
	mv "$S/flash/mtd$m/$v.data.new" "$S/flash/mtd$m/$v.data"
[ "$(cat "$S/corrupt" 2>/dev/null)" = "mtd$m/$v" ] &&
	printf 'X' | dd of="$S/flash/mtd$m/$v.data" bs=1 count=1 conv=notrunc 2>/dev/null
echo "update mtd$m $v" >> "$S/calls"
EOF
tool fw_printenv <<'EOF'
#!/bin/sh
. "$(dirname "$0")/_sim"
[ "$1" = -c ] && shift 2
[ "$1" = -n ] && shift
v=$(sed -n "s/^$1=//p" "$S/env")
grep -q "^$1=" "$S/env" || exit 1
printf '%s\n' "$v"
EOF
tool fw_setenv <<'EOF'
#!/bin/sh
. "$(dirname "$0")/_sim"
[ "$1" = -c ] && shift 2
fail_point fw_setenv
set_one() {
	grep -v "^$1=" "$S/env" > "$S/env.new"
	[ -n "$2" ] && printf '%s=%s\n' "$1" "$2" >> "$S/env.new"
	mv "$S/env.new" "$S/env"
}
if [ "$1" = -s ]; then
	while read -r n v; do set_one "$n" "$v"; done < "$2"
	echo "setenv-batch" >> "$S/calls"
else
	n=$1; shift; set_one "$n" "$*"
	echo "setenv $n" >> "$S/calls"
fi
EOF
tool mknod <<'EOF'
#!/bin/sh
. "$(dirname "$0")/_sim"
# mknod PATH c MAJOR MINOR: a volume node reads and writes the volume data.
n=${1##*/}
case "$n" in
*_*) k=${n%_*}; v=${n##*_}; ln -s "$S/flash/mtd$(ubi_mtd "$k")/$v.data" "$1" ;;
*) touch "$1" ;;
esac
echo "mknod $n" >> "$S/calls"
EOF
tool ubiblock <<'EOF'
#!/bin/sh
exit 0
EOF
tool mount <<'EOF'
#!/bin/sh
. "$(dirname "$0")/_sim"
for last; do :; done
# A Sage UBIFS root mounted to take the configuration.
if [ "$2" = ubifs ]; then
	mkdir -p "$last" && echo "mount-ubifs ${3##*/}" >> "$S/calls"
	exit 0
fi
cp -R "$S/oem_root/." "$last/" && echo "mount-oem" >> "$S/calls"
EOF
for t in umount logger sync; do printf '#!/bin/sh\nexit 0\n' | tool "$t"; done
tool reboot <<'EOF'
#!/bin/sh
. "$(dirname "$0")/_sim"
echo reboot >> "$S/calls"
EOF
tool ip <<'EOF'
#!/bin/sh
. "$(dirname "$0")/_sim"
[ -f "$S/net_ok" ] || exit 0
# Only br-lan and the interfaces present under $S/net have an address.
dev=$(echo "$*" | sed -n 's/.* dev \([^ ]*\).*/\1/p')
[ -n "$dev" ] || dev=$(cat "$S/default_dev" 2>/dev/null || echo br-lan)
[ "$dev" = br-lan ] || [ -d "$S/net/$dev" ] || exit 0
case "$*" in
*address*) echo '    inet 192.0.2.10/24 brd 192.0.2.255 scope global br-lan' ;;
*route*) [ ! -f "$S/no_default" ] && echo "default via 192.0.2.1 dev $dev" ;;
esac
EOF
command -v sha256sum >/dev/null 2>&1 || tool sha256sum <<'EOF'
#!/bin/sh
exec shasum -a 256 "$@"
EOF
# uci: enough network configuration for management-interface guard tests.
tool uci <<'EOF'
#!/bin/sh
. "$(dirname "$0")/_sim"
case "$*" in
"-q show network")
	[ -f "$S/management_section" ] || exit 1
	section=$(cat "$S/management_section")
	echo "network.$section=interface"
	;;
"-q get network.lan.device")
	[ -f "$S/lan_device" ] || exit 1
	cat "$S/lan_device"
	;;
"-q get network."*.device)
	[ -f "$S/management_device" ] || exit 1
	cat "$S/management_device"
	;;
*) exit 1 ;;
esac
EOF
cat > "$S/functions.sh" <<'EOF'
find_mtd_index() {
	awk -v w="\"$1\"" '$4 == w { sub(/^mtd/, "", $1); sub(/:$/, "", $1); print $1 }' "$AB_PROC_MTD"
}
EOF
cat > "$S/system.sh" <<'EOF'
board_name() { cat "$JAGUAR_SIM/board"; }
EOF
tool board-data <<EOF
#!/bin/sh
exec sh "$board_data" "\$@"
EOF

export PATH="$S/bin:$PATH" JAGUAR_SIM=$S
export AB_PROC_MTD=$S/proc_mtd AB_CMDLINE=$S/cmdline AB_DT=$S/dt
export AB_UBI_SYS=$S/sys/ubi AB_MTD_SYS=$S/sys/mtd AB_DEV=$S/dev
export AB_ENV_CONFIG=$S/fw_env.config AB_PROC_MOUNTS=$S/mounts
mkdir -p "$S/modules"
ln -s "$jaguar_module_dir/cambium-ab-jaguar.sh" "$S/modules/"
ln -s "$top/package/cambium/cambium-cheetah-support/files/cambium-ab-cheetah.sh" "$S/modules/"
ln -s "$top/package/cambium/cambium-thor-support/files/cambium-ab-thor.sh" "$S/modules/"
ln -s "$top/package/cambium/cambium-sage-support/files/cambium-ab-sage.sh" "$S/modules/"
ln -s "$top/package/cambium/cambium-gambit-support/files/cambium-ab-gambit.sh" "$S/modules/"
export CAMBIUM_SAGE_LIB=$top/target/linux/ipq40xx/base-files/lib/functions/cambium-sage.sh
export AB_NEWROOT=$S/newroot
export CAMBIUM_AB_LIB=$ab_pkg/cambium-ab.sh CAMBIUM_AB_MODULES=$S/modules
export AB_SYS_NET=$S/net AB_SYS_IEEE80211=$S/ieee80211 AB_SYS_MODULE=$S/module
export CAMBIUM_AB_UPGRADE_LIB=${CAMBIUM_AB_UPGRADE_LIB:-$ab_pkg/cambium-ab-upgrade.sh}
export CAMBIUM_FUNCTIONS=$S/functions.sh CAMBIUM_SYSTEM_FUNCTIONS=$S/system.sh
export CAMBIUM_BDF_FW_DIR=$S/fw CAMBIUM_BDF_WORK=$S/bdwork CAMBIUM_BDF_STATUS=$S/bdstatus
export AB_BOARD_DATA=$S/bin/board-data AB_WORK=$S/work
export AB_GUARD_TRIES=2 AB_GUARD_PAUSE=0
export AB_HEALTH_DIR=$S/health
mkdir -p "$AB_HEALTH_DIR"

# --- simulated AP ---------------------------------------------------------------
BDF=lib/firmware/IPQ6018/WIFI_FW/bdwlan.b13.stock

sku_byte() {
	case "$1" in
	cambiumnetworks,xv2-2) echo 024 ;; cambiumnetworks,xv2-2t0) echo 026 ;;
	cambiumnetworks,xv2-2t1) echo 037 ;; cambiumnetworks,xe3-4) echo 040 ;;
	cambiumnetworks,xe3-4tn) echo 041 ;; cambiumnetworks,xv2-22h) echo 042 ;;
	cambiumnetworks,xv2-21x) echo 043 ;; cambiumnetworks,xv2-23t) echo 044 ;;
	cambiumnetworks,xv3-8) echo 023 ;; cambium,e410) echo 012 ;;
	cambiumnetworks,e410b) echo 025 ;; cambiumnetworks,e510) echo 020 ;;
	cambiumnetworks,e600) echo 013 ;; *) echo 177 ;;
	esac
}
cheetah_board() {
	case "$1" in cambiumnetworks,xv2-21x|cambiumnetworks,xv2-22h|cambiumnetworks,xv2-23t) ;; *) return 1 ;; esac
}
# The stock firmware's board files for BOARD, as PATH:SIZE (cambium-board-data).
oem_bdfs() {
	case "$1" in
	cambiumnetworks,xv2-21x) echo lib/firmware/IPQ5018/WIFI_FW/bdwlan.b24-ocelot:131072 lib/firmware/IPQ5018/WIFI_FW/qcn6122/bdwlan.b60-ocelot:131072 ;;
	cambiumnetworks,xv2-22h) echo lib/firmware/IPQ5018/WIFI_FW/bdwlan.b24-cheetah:131072 lib/firmware/IPQ5018/WIFI_FW/qcn6122/bdwlan.b50-cheetah:131072 ;;
	cambiumnetworks,xv2-23t) echo lib/firmware/IPQ5018/WIFI_FW/bdwlan.b24-lynx:131072 lib/firmware/IPQ5018/WIFI_FW/qcn6122/bdwlan.b60.stock:131072 ;;
	cambiumnetworks,xv2-2|cambiumnetworks,xv2-2t0|cambiumnetworks,xv2-2t1) echo "$BDF:65536" ;;
	cambiumnetworks,xe3-4) echo lib/firmware/IPQ6018/WIFI_FW/bdwlan.b10-puma:65536 lib/firmware/qcn9000/WIFI_FW/bdwlan.bab-puma:131072 ;;
	cambiumnetworks,xv3-8) echo lib/firmware/IPQ8074/WIFI_FW/bdwlan.b215.accton:131072 ;;
	esac
}
set_sku() { printf "\\000\\000\\000\\$1" > "$S/dt/cambium-platform/board-sku"; }

# new_ap [BOARD] [ACTIVE-SLOT] [oem|openwrt]: the other bank's contents.
new_ap() {
	local board=${1:-cambiumnetworks,xv2-2t1} active=${2:-0} other=${3:-oem} i
	rm -rf "$S/sys" "$S/dev" "$S/flash" "$S/dt" "$S/fw" "$S/bdwork"* "$S/work" "$S/oem_root" "$S/net" "$S/ieee80211" "$S/module"
	rm -f "$S/calls" "$S/opcount" "$S/fail_at" "$S/corrupt" "$S/bank_lebs" "$S/bdstatus" "$S/net_ok" "$S/lan_device" \
		"$S/default_dev" "$S/no_default" "$S/management_section" "$S/management_device"
	mkdir -p "$S/sys/ubi" "$S/dev" "$S/flash" "$S/dt/cambium-platform" "$S/fw"
	touch "$S/calls"
	echo "$board" > "$S/board"
	set_sku "$(sku_byte "$board")"
	if [ "$board" = cambiumnetworks,xv2-2 ]; then
		# 128 MiB NAND: two 52 MiB banks (416 PEBs, 392 usable LEBs).
		printf '%s\n' 'dev:    size   erasesize  name' \
			'mtd0: 03400000 00020000 "rootfs"' 'mtd1: 03400000 00020000 "rootfs_1"' \
			'mtd2: 01000000 00020000 "0:NVRAM"' 'mtd3: 00800000 00020000 "crashlog"' \
			'mtd4: 00080000 00010000 "0:ART"' 'mtd5: 00010000 00010000 "0:APPSBLENV"' > "$S/proc_mtd"
		echo 392 > "$S/bank_lebs"
	elif cheetah_board "$board"; then
		# Cheetah: 256 MiB NAND, two 96 MiB banks after 0:TRAINING.
		printf '%s\n' 'dev:    size   erasesize  name' \
			'mtd0: 06000000 00020000 "rootfs"' 'mtd1: 06000000 00020000 "rootfs_1"' \
			'mtd2: 02f80000 00020000 "0:NVRAM"' 'mtd3: 01000000 00020000 "crashLog"' \
			'mtd4: 00070000 00001000 "0:ART"' 'mtd5: 00010000 00001000 "0:APPSBLENV"' \
			'mtd6: 00080000 00020000 "0:TRAINING"' > "$S/proc_mtd"
	elif [ "$board" = cambiumnetworks,xv3-8 ]; then
		# Thor: two 96 MiB NAND banks; Aquantia firmware and ART on NOR.
		printf '%s\n' 'dev:    size   erasesize  name' \
			'mtd0: 06000000 00020000 "rootfs"' 'mtd1: 06000000 00020000 "rootfs_1"' \
			'mtd2: 00080000 00010000 "0:ETHPHYFW"' 'mtd3: 00950000 00010000 "config"' \
			'mtd4: 00040000 00010000 "0:ART"' 'mtd5: 00010000 00010000 "0:APPSBLENV"' > "$S/proc_mtd"
	else
		printf '%s\n' 'dev:    size   erasesize  name' \
			'mtd0: 06000000 00020000 "rootfs"' 'mtd1: 06000000 00020000 "rootfs_1"' \
			'mtd2: 03000000 00020000 "NVRAM"' 'mtd3: 01000000 00020000 "crashLog"' \
			'mtd4: 00080000 00010000 "0:ART"' 'mtd5: 00010000 00010000 "0:APPSBLENV"' > "$S/proc_mtd"
	fi
	mkdir -p "$S/net" "$S/ieee80211"
	for i in 0 1 2 3 4 5 6; do mkdir -p "$S/sys/mtd/mtd$i"; echo 0x800 > "$S/sys/mtd/mtd$i/flags"; done
	echo 0xc00 > "$S/sys/mtd/mtd0/flags"; echo 0xc00 > "$S/sys/mtd/mtd1/flags"
	echo 0xc00 > "$S/sys/mtd/mtd5/flags"
	echo "ART-of-this-unit" > "$S/dev/mtd4"; echo NVRAM > "$S/dev/mtd2"
	printf 'console=ttyMSM0 ubi.mtd=%s root=/dev/ubiblock0_1\n' "$([ "$active" = 0 ] && echo rootfs || echo rootfs_1)" > "$S/cmdline"
	make_bank "$active" "running-kernel" "running-root"
	if [ "$other" = oem ]; then
		mkdir -p "$S/flash/mtd$((1 - active))"
		echo ubi_rootfs > "$S/flash/mtd$((1 - active))/0.name"
		echo $((200 * LEB)) > "$S/flash/mtd$((1 - active))/0.size"
		echo oem-squashfs > "$S/flash/mtd$((1 - active))/0.data"
		echo "OEM-7.2-BANK" > "$S/dev/mtd$((1 - active))"
		for f in $(oem_bdfs "$board"); do
			mkdir -p "$S/oem_root/$(dirname "${f%:*}")"
			head -c "${f#*:}" /dev/zero | tr '\000' 'B' > "$S/oem_root/${f%:*}"
		done
	else
		make_bank "$((1 - active))" "other-kernel" "other-root" detached
	fi
	mkdir -p "$S/sys/ubi/ubi0"; echo "$active" > "$S/sys/ubi/ubi0/mtd_num"
	(. "$S/bin/_sim"; refresh ubi0 "$active")
	touch "$S/dev/ubiblock0_1"
	echo '/dev/ubi0_2 /overlay ubifs rw,noatime 0 0' > "$S/mounts"
	if [ "$board" = cambiumnetworks,xv3-8 ]; then
		# Thor's stock environment has no image variable.
		printf '%s\n' 'bootcmd=aq_load_fw&&bootipq' 'changing_bootcmd=1' > "$S/env"
	else
		printf '%s\n' 'bootcmd=bootipq' 'image=1' 'changing_bootcmd=1' > "$S/env"
	fi
}
make_bank() { # SLOT KERNEL ROOT
	local m="$S/flash/mtd$1"
	mkdir -p "$m"
	printf 'kernel\n' > "$m/0.name"; echo $((40 * LEB)) > "$m/0.size"; printf '%s' "$2" > "$m/0.data"
	printf 'rootfs\n' > "$m/1.name"; echo $((200 * LEB)) > "$m/1.size"; printf '%s' "$3" > "$m/1.data"
	printf 'rootfs_data\n' > "$m/2.name"; echo $((120 * LEB)) > "$m/2.size"; : > "$m/2.data"
	printf 'cambium_device_data\n' > "$m/3.name"; echo $((8 * LEB)) > "$m/3.size"; : > "$m/3.data"
	echo "OPENWRT-BANK-$1" > "$S/dev/mtd$1"
}
# A converted AP: both banks OpenWrt, vault filled, env in A/B mode.
converted_ap() {
	new_ap "${1:-cambiumnetworks,xv2-2t1}" "${2:-0}" oem
	run_board_data >/dev/null 2>&1
	sh "$ab_pkg/cambium-ab-convert" --oem-sha256 "$(oem_hash)" --allow-untested --yes >/dev/null 2>&1 ||
		{ echo "fixture: conversion failed" >&2; return 1; }
	: > "$S/calls"; rm -f "$S/opcount"
}
oem_hash() { sha256sum < "$S/dev/mtd$(( 1 - $(cat "$S/sys/ubi/ubi0/mtd_num") ))" | cut -d' ' -f1; }
env_get() { sed -n "s/^$1=//p" "$S/env"; }
bank_hash() { (cd "$S/flash/mtd$1" && cat ./* 2>/dev/null) | sha256sum | cut -d' ' -f1; }
run_board_data() { sh "$board_data" "$@"; }

# FIT holding the five Jaguar configuration nodes (or those given).
make_fit() {
	local c
	printf '\320\015\376\355\000\000\000\100'
	for c in ${*:-config@cp01-c1 config@cp01-c1-1 config@cp01-c1-2 config@cp01-c3-xv3-4 config@cp01-c3-2}; do
		printf '\000\000\000\001%s\000' "$c"
	done
	printf 'kernel-payload'
}
# make_image OUT [kernel-file] [root-file] [dir]
make_image() {
	local d=$S/img/${4:-sysupgrade-cambiumnetworks_jaguar}
	rm -rf "$S/img"; mkdir -p "$d"
	if [ -n "${2:-}" ]; then cp "$2" "$d/kernel"; else make_fit > "$d/kernel"; fi
	if [ -n "${3:-}" ]; then cp "$3" "$d/root"; else printf 'hsqs-new-root' > "$d/root"; fi
	(cd "$S/img" && tar -cf "$1" "${4:-sysupgrade-cambiumnetworks_jaguar}")
}

# --- harness --------------------------------------------------------------------
check() { # check DESCRIPTION EXPECTED(0|1) COMMAND...
	local desc=$1 want=$2 got
	shift 2
	( "$@" ) >"$S/out" 2>&1; got=$?
	[ "$got" -ne 0 ] && got=1
	if [ "$got" = "$want" ]; then pass=$((pass + 1)); else
		fail=$((fail + 1)); echo "FAIL: $desc (exit $got, wanted $want)"; sed 's/^/    /' "$S/out"
	fi
}
assert() { # assert DESCRIPTION TEST...
	local desc=$1
	shift
	if "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $desc"; fi
}
in_lib() { # run a function with the libraries loaded
	(. "$S/system.sh"; . "$S/functions.sh"; . "$CAMBIUM_AB_UPGRADE_LIB"
	 nand_restore_config() { echo "restore-config $CI_UBIPART $1" >> "$S/calls"; }
	 "$@")
}
never_wrote() { # never_wrote PATTERN: no simulated write matched
	! grep -E "$1" "$S/calls" >/dev/null
}

# --- board table and identity ---------------------------------------------------
while read -r board fit; do
	new_ap "$board"
	check "$board identity accepted in slot 0" 0 in_lib eval \
		'ab_identity && [ "$AB_ACTIVE:$AB_TARGET:$AB_FIT" = "0:1:'"$fit"'" ]'
done <<'EOF'
cambiumnetworks,xv2-2 config@cp01-c1
cambiumnetworks,xv2-2t0 config@cp01-c1-1
cambiumnetworks,xv2-2t1 config@cp01-c1-2
cambiumnetworks,xe3-4 config@cp01-c3-xv3-4
cambiumnetworks,xe3-4tn config@cp01-c3-2
EOF
new_ap cambiumnetworks,xv2-2; sed -i.bak 's/^mtd0: 03400000/mtd0: 06000000/' "$S/proc_mtd"
check "XV2-2 with a 96 MiB bank refused" 1 in_lib ab_identity
new_ap cambiumnetworks,xv2-2t1; sed -i.bak 's/^mtd1: 06000000/mtd1: 03400000/' "$S/proc_mtd"
check "XV2-2T1 with a 52 MiB bank refused" 1 in_lib ab_identity
new_ap cambiumnetworks,xv2-2; echo 0xc00 > "$S/sys/mtd/mtd3/flags"
check "XV2-2 writable crashlog refused" 1 in_lib ab_identity
new_ap cambiumnetworks,xv2-2t1 1 openwrt
check "identity accepted in slot 1" 0 in_lib eval \
	'ab_identity && [ "$AB_ACTIVE:$AB_TARGET:$AB_TARGET_PART" = "1:0:rootfs" ]'
new_ap; set_sku 024
check "board/SKU mismatch refused" 1 in_lib ab_identity
new_ap; echo 'ubi.mtd=rootfs ubi.mtd=rootfs_1' > "$S/cmdline"
check "conflicting ubi.mtd refused" 1 in_lib ab_identity
new_ap; echo 'console=ttyMSM0 ubi.mtd=rootfs_1' > "$S/cmdline"
check "command line / UBI attachment mismatch refused" 1 in_lib ab_identity
new_ap; echo 0xc00 > "$S/sys/mtd/mtd4/flags"
check "writable ART refused" 1 in_lib ab_identity
new_ap; echo 0xc00 > "$S/sys/mtd/mtd2/flags"
check "writable NVRAM refused" 1 in_lib ab_identity
new_ap; sed -i.bak 's/^mtd0: 06000000/mtd0: 03000000/' "$S/proc_mtd"
check "wrong bank size refused" 1 in_lib ab_identity
new_ap cambiumnetworks,xv2-99
check "unknown board refused" 1 in_lib ab_identity
new_ap cambiumnetworks,xe3-4; rm -rf "$S/dt/cambium-platform"
check "upstream XE3-4 image (no cambium-platform) is not a Jaguar family image" 1 in_lib ab_family
new_ap cambiumnetworks,xe3-4
check "Jaguar family XE3-4 is recognised" 0 in_lib ab_family

# --- boot commands --------------------------------------------------------------
for slot in 0 1; do
	new_ap
	cmd=$(in_lib eval 'ab_board cambiumnetworks,xv2-2t1; ab_boot_command '"$slot")
	case "$slot:$cmd" in
	0:*'@0x0(fs)'*'ubi.mtd=rootfs '*'bootm 0x60000000#config@cp01-c1-2') ok=0 ;;
	1:*'@0x6000000(fs)'*'ubi.mtd=rootfs_1 '*'bootm 0x60000000#config@cp01-c1-2') ok=0 ;;
	*) ok=1 ;;
	esac
	assert "slot $slot boot command selects its bank and FIT" [ "$ok" = 0 ]
done
assert "stable command 0" [ "$(in_lib eval 'ab_board cambiumnetworks,xv2-2t1; ab_stable_command 0 1')" = 'run jaguar_boot0; run jaguar_boot1' ]
assert "stable command 1" [ "$(in_lib eval 'ab_board cambiumnetworks,xv2-2t1; ab_stable_command 1 0')" = 'run jaguar_boot1; run jaguar_boot0' ]
assert "trial 0->1 restores slot 0 first" [ "$(in_lib eval 'ab_board cambiumnetworks,xv2-2t1; ab_trial_command 0 1')" = \
	'setenv bootcmd run jaguar_stable0; setenv image 0; setenv jaguar_ab_state trial-started; saveenv; run jaguar_boot1; run jaguar_boot0' ]
assert "trial 1->0 restores slot 1 first" [ "$(in_lib eval 'ab_board cambiumnetworks,xv2-2t1; ab_trial_command 1 0')" = \
	'setenv bootcmd run jaguar_stable1; setenv image 1; setenv jaguar_ab_state trial-started; saveenv; run jaguar_boot0; run jaguar_boot1' ]
new_ap
assert "no single quotes reach U-Boot" [ -z "$(in_lib eval 'ab_board cambiumnetworks,xv2-2t1; ab_boot_command 1; ab_trial_command 0 1' | tr -dc "'")" ]
check "invalid slot refused" 1 in_lib eval 'ab_board cambiumnetworks,xv2-2t1; ab_boot_command 2'
check "equal stable slots refused" 1 in_lib eval 'ab_board cambiumnetworks,xv2-2t1; ab_stable_command 0 0'

# --- device-data vault ----------------------------------------------------------
new_ap
oem_before=$(bank_hash 1)
check "first boot fills the vault from the OEM slot" 0 run_board_data
assert "status is vault" [ "$(cat "$S/bdstatus")" = vault ]
assert "board file installed" [ -s "$S/fw/ath11k/IPQ6018/hw1.0/board.bin" ]
assert "vault written to the running bank's volume 3" grep -q 'update mtd0 3' "$S/calls"
assert "OEM bank contents unchanged by the import" [ "$(bank_hash 1)" = "$oem_before" ]
assert "OEM bank detached after the import" [ -z "$(in_lib ab_ubi_for_mtd 1)" ]
check "--check-vault accepts this unit's vault" 0 run_board_data --check-vault
rm -rf "$S/fw"; : > "$S/calls"
check "later boot restores from the vault" 0 run_board_data
assert "later boot never attaches the OEM slot" never_wrote 'attach|mount-oem'
assert "board file restored after factory reset" [ -s "$S/fw/ath11k/IPQ6018/hw1.0/board.bin" ]
echo "ART-of-another-unit" > "$S/dev/mtd4"; : > "$S/calls"
check "vault from another unit (ART) refused" 1 run_board_data
assert "status is vault-mismatch" [ "$(cat "$S/bdstatus")" = vault-mismatch ]
assert "another unit's vault is not overwritten" never_wrote 'update mtd0 3'
check "--check-vault refuses another unit's vault" 1 run_board_data --check-vault
new_ap; run_board_data >/dev/null 2>&1
set_sku 026
check "--check-vault refuses a SKU mismatch" 1 run_board_data --check-vault
new_ap; run_board_data >/dev/null 2>&1
# Corrupt the stored board file: the vault is refilled from the OEM slot.
(cd "$S" && mkdir -p x && tar -xf flash/mtd0/3.data -C x && printf 'Z' | dd of="x/files/$BDF" bs=1 count=1 conv=notrunc 2>/dev/null &&
	(cd x && tar -cf ../flash/mtd0/3.data MANIFEST files) && rm -rf x)
check "--check-vault detects a corrupted board file" 1 run_board_data --check-vault
: > "$S/calls"
check "corrupted vault is refilled while the OEM slot exists" 0 run_board_data
assert "refill rewrote the vault" grep -q 'update mtd0 3' "$S/calls"
new_ap cambiumnetworks,xe3-4
check "XE3-4 fills the vault from the OEM slot" 0 run_board_data
assert "XE3-4 IPQ6018 board file installed" [ -s "$S/fw/ath11k/IPQ6018/hw1.0/board.bin" ]
assert "XE3-4 QCN9074 board file installed" [ -s "$S/fw/ath11k/QCN9074/hw1.0/board.bin" ]
check "XE3-4 vault is valid" 0 run_board_data --check-vault
new_ap cambiumnetworks,xe3-4tn
check "XE3-4TN gets a manifest-only vault" 0 run_board_data
assert "XE3-4TN never attaches the OEM slot" never_wrote 'attach|mount-oem'
check "XE3-4TN vault is valid" 0 run_board_data --check-vault
new_ap; rm -rf "$S/oem_root"
check "no OEM board file: radios stay down" 1 run_board_data
assert "status is missing" [ "$(cat "$S/bdstatus")" = missing ]

# --- conversion -----------------------------------------------------------------
new_ap; run_board_data >/dev/null 2>&1; : > "$S/calls"
check "conversion needs --yes" 1 sh "$ab_pkg/cambium-ab-convert" --oem-sha256 "$(oem_hash)"
check "conversion refuses a wrong OEM backup hash" 1 sh "$ab_pkg/cambium-ab-convert" \
	--oem-sha256 0000000000000000000000000000000000000000000000000000000000000000 --yes
assert "a refused conversion wrote nothing" never_wrote 'format|mkvol|update|setenv'
new_ap cambiumnetworks,xv2-2t0; run_board_data >/dev/null 2>&1
check "untested model needs --allow-untested" 1 sh "$ab_pkg/cambium-ab-convert" --oem-sha256 "$(oem_hash)" --yes
new_ap
new_ap cambiumnetworks,xv2-2; run_board_data >/dev/null 2>&1
check "XV2-2 conversion (validated on hardware)" 0 sh "$ab_pkg/cambium-ab-convert" --oem-sha256 "$(oem_hash)" --yes
assert "XV2-2 slot 1 is a copy of slot 0" cmp -s "$S/flash/mtd1/1.data" "$S/flash/mtd0/1.data"
assert "XV2-2 boot command uses its 52 MiB slot 1" [ "$(env_get jaguar_boot1)" = \
	'nand device 0 && setenv mtdids nand0=nand0 && setenv mtdparts "mtdparts=nand0:0x3400000@0x3400000(fs)" && ubi part fs && ubi read 0x60000000 kernel && setenv bootargs "console=ttyMSM0,115200n8 cnss2.bdf_pci0=0xab ubi.mtd=rootfs_1 root=/dev/ubiblock0_1 rootfstype=squashfs rootwait swiotlb=1" && bootm 0x60000000#config@cp01-c1' ]
new_ap
check "conversion refuses an empty vault" 1 sh "$ab_pkg/cambium-ab-convert" --oem-sha256 "$(oem_hash)" --yes
new_ap; run_board_data >/dev/null 2>&1; echo 0x800 > "$S/sys/mtd/mtd1/flags"
check "conversion refuses a read-only target bank (pre-A/B image)" 1 sh "$ab_pkg/cambium-ab-convert" --oem-sha256 "$(oem_hash)" --yes
new_ap; run_board_data >/dev/null 2>&1
active_before=$(bank_hash 0)
check "XV2-2T1 conversion succeeds" 0 sh "$ab_pkg/cambium-ab-convert" --oem-sha256 "$(oem_hash)" --yes
assert "converted: version 1, slot 0 confirmed" [ "$(env_get jaguar_ab_version):$(env_get jaguar_ab_confirmed):$(env_get jaguar_ab_state)" = 1:0:confirmed ]
assert "bootcmd boots slot 0 then slot 1" [ "$(env_get bootcmd)" = 'run jaguar_stable0' ]
assert "changing_bootcmd kept" [ "$(env_get changing_bootcmd)" = 1 ]
assert "OEM image value recorded" [ "$(env_get jaguar_ab_oem_image)" = 1 ]
assert "image follows the running bank" [ "$(env_get image)" = 0 ]
assert "slot 1 holds the running kernel" cmp -s "$S/flash/mtd1/0.data" "$S/flash/mtd0/0.data"
assert "slot 1 holds the running rootfs" cmp -s "$S/flash/mtd1/1.data" "$S/flash/mtd0/1.data"
assert "slot 1 holds the vault" cmp -s "$S/flash/mtd1/3.data" "$S/flash/mtd0/3.data"
assert "slot 1 volume IDs are kernel, rootfs, rootfs_data, vault" \
	[ "$(cat "$S/flash/mtd1/0.name" "$S/flash/mtd1/1.name" "$S/flash/mtd1/2.name" "$S/flash/mtd1/3.name" | tr '\n' ' ')" = 'kernel rootfs rootfs_data cambium_device_data ' ]
assert "running bank untouched" [ "$(bank_hash 0)" = "$active_before" ]
assert "bootcmd written after changing_bootcmd and boot commands" sh -c \
	"grep -n 'setenv bootcmd' '$S/calls' | head -n 1 | cut -d: -f1 | { read b; [ \"\$b\" -gt \"\$(grep -n 'setenv-batch' '$S/calls' | sed -n 2p | cut -d: -f1)\" ]; }"
assert "stable command installed before the OEM bank is formatted" sh -c \
	"[ \$(grep -n 'setenv bootcmd' '$S/calls' | head -n1 | cut -d: -f1) -lt \$(grep -n 'format mtd1' '$S/calls' | cut -d: -f1) ]"
check "second conversion refused" 1 sh "$ab_pkg/cambium-ab-convert" --oem-sha256 x --yes

# Interrupted conversion: stable slot-0 boot survives, --resume finishes it.
new_ap; run_board_data >/dev/null 2>&1; sha=$(oem_hash)
steps=$( (sh "$ab_pkg/cambium-ab-convert" --oem-sha256 "$sha" --yes >/dev/null 2>&1; cat "$S/opcount") )
ok=0
for n in $(seq 1 "$steps"); do
	new_ap; run_board_data >/dev/null 2>&1; rm -f "$S/opcount"; echo "$n" > "$S/fail_at"
	sh "$ab_pkg/cambium-ab-convert" --oem-sha256 "$sha" --yes >/dev/null 2>&1
	rm -f "$S/fail_at"
	case "$(env_get bootcmd)" in
	bootipq|'run jaguar_stable0') ;;
	*) ok=1; echo "    convert interrupted at op $n left bootcmd=$(env_get bootcmd)" ;;
	esac
	[ "$(env_get jaguar_ab_version)" = 1 ] && [ "$n" -lt "$steps" ] && { ok=1; echo "    op $n: converted too early"; }
	if [ "$(env_get jaguar_ab_state)" = convert-failed ] || [ "$(env_get jaguar_ab_state)" = converting ]; then
		sh "$ab_pkg/cambium-ab-convert" --resume --yes >/dev/null 2>&1 ||
			{ ok=1; echo "    op $n: --resume failed"; }
		[ "$(env_get jaguar_ab_version)" = 1 ] || { ok=1; echo "    op $n: not converted after --resume"; }
	fi
done
assert "every interruption of the $steps conversion writes keeps slot 0 booting first and resumes" [ "$ok" = 0 ]

# --- sysupgrade -----------------------------------------------------------------
eval "$(sed -n '/^platform_check_image() {/,/^}/p; /^platform_do_upgrade() {/,/^}/p' "$base/lib/upgrade/platform.sh")"
generic() { echo "generic-nand $*" >> "$S/calls"; }
nand_do_upgrade() { generic nand "$@"; }
default_do_upgrade() { generic default "$@"; }
# platform_do_upgrade runs in sysupgrade stage 2, without hotplug.
dispatch() { (. "$S/system.sh"; . "$S/functions.sh"; . "$CAMBIUM_AB_UPGRADE_LIB"
	nand_restore_config() { echo "restore-config $CI_UBIPART $1" >> "$S/calls"; }
	[ "$1" = platform_do_upgrade ] && touch "$S/no_hotplug"
	"$@"; rc=$?; rm -f "$S/no_hotplug"; exit $rc); }

make_image "$S/good.bin"
new_ap; run_board_data >/dev/null 2>&1
check "unconverted AP refuses sysupgrade (check)" 1 dispatch platform_check_image "$S/good.bin"
check "unconverted AP refuses sysupgrade (do)" 1 dispatch platform_do_upgrade "$S/good.bin"
assert "unconverted AP never reaches a generic path" never_wrote 'generic-nand'
new_ap cambiumnetworks,xe3-4; rm -rf "$S/dt/cambium-platform"
check "upstream XE3-4 keeps its own check" 0 dispatch platform_check_image "$S/good.bin"
dispatch platform_do_upgrade "$S/good.bin" >/dev/null 2>&1
assert "upstream XE3-4 keeps its nand_do_upgrade path" grep -q 'generic-nand nand' "$S/calls"

converted_ap
check "converted AP accepts the family image" 0 dispatch platform_check_image "$S/good.bin"
make_image "$S/nofit.bin" "$S/good.bin"
check "non-FIT kernel refused" 1 dispatch platform_check_image "$S/nofit.bin"
make_fit config@cp01-c1 config@cp01-c1-1 > "$S/fit-partial"
make_image "$S/partial.bin" "$S/fit-partial"
check "FIT without this model's configuration refused" 1 dispatch platform_check_image "$S/partial.bin"
make_fit config@cp01-c1-2x > "$S/fit-similar"
make_image "$S/similar.bin" "$S/fit-similar"
check "similar configuration name not accepted" 1 dispatch platform_check_image "$S/similar.bin"
printf 'not-squashfs' > "$S/root-bad"; make_image "$S/noroot.bin" "" "$S/root-bad"
check "non-SquashFS root refused" 1 dispatch platform_check_image "$S/noroot.bin"
head -c $((700 * LEB)) /dev/zero | sed 's/^/hsqs/' > "$S/root-big"; make_image "$S/big.bin" "" "$S/root-big"
check "image too large for a bank refused" 1 dispatch platform_check_image "$S/big.bin"
make_image "$S/otherdir.bin" "" "" sysupgrade-cambiumnetworks_xe3-4
check "image for another board directory refused" 1 dispatch platform_check_image "$S/otherdir.bin"
converted_ap; echo "ART-of-another-unit" > "$S/dev/mtd4"
check "vault mismatch refuses sysupgrade" 1 dispatch platform_check_image "$S/good.bin"

for case in cambiumnetworks,xv2-2t1:0 cambiumnetworks,xv2-2t1:1 cambiumnetworks,xv2-2:0 cambiumnetworks,xv2-2:1; do
	board=${case%:*} active=${case#*:}
	target=$((1 - active))
	converted_ap "$board" "$active"
	active_before=$(bank_hash "$active")
	check "$board: upgrade slot $active -> $target" 0 dispatch platform_do_upgrade "$S/good.bin"
	assert "slot $target kernel written" [ "$(cat "$S/flash/mtd$target/0.data")" = "$(tar -xOf "$S/good.bin" sysupgrade-cambiumnetworks_jaguar/kernel)" ]
	assert "slot $target rootfs written" [ "$(cat "$S/flash/mtd$target/1.data")" = hsqs-new-root ]
	assert "slot $target vault copied" cmp -s "$S/flash/mtd$target/3.data" "$S/flash/mtd$active/3.data"
	assert "slot $active untouched" [ "$(bank_hash "$active")" = "$active_before" ]
	assert "only slot $target and the environment written" never_wrote "(format|mkvol|update) mtd[^$target]"
	assert "trial of slot $target armed last" [ "$(env_get bootcmd)" = \
		"setenv bootcmd run jaguar_stable$active; setenv image $active; setenv jaguar_ab_state trial-started; saveenv; run jaguar_boot$target; run jaguar_boot$active" ]
	assert "state armed, target $target" [ "$(env_get jaguar_ab_state):$(env_get jaguar_ab_target)" = "armed:$target" ]
	assert "bootcmd is the last environment write" [ "$(grep setenv "$S/calls" | tail -n 1)" = 'setenv bootcmd' ]
	check "$board: a second upgrade waits for the trial" 1 dispatch platform_check_image "$S/good.bin"
done

# Detach must be verified before formatting an inactive bank.
converted_ap
ubiattach -m 1
touch "$S/detach_false_error"
active_before=$(bank_hash 0)
check "detach error with absent sysfs device permits inactive-bank upgrade" 0 dispatch platform_do_upgrade "$S/good.bin"
assert "false detach error leaves active bank intact" [ "$(bank_hash 0)" = "$active_before" ]
rm -f "$S/detach_false_error"
converted_ap
ubiattach -m 1
touch "$S/detach_stays"
check "detach success with device still present refuses formatting" 1 dispatch platform_do_upgrade "$S/good.bin"
assert "still-attached target is never formatted" never_wrote 'format|mkvol|update'
rm -f "$S/detach_stays"

# An image that fits the XV2-2T1's 96 MiB bank but not the XV2-2's 52 MiB one.
{ printf hsqs; head -c $((330 * LEB)) /dev/zero; } > "$S/root-mid"; make_image "$S/mid.bin" "" "$S/root-mid"
converted_ap cambiumnetworks,xv2-2t1
check "330-LEB root fits a 96 MiB bank" 0 dispatch platform_check_image "$S/mid.bin"
converted_ap cambiumnetworks,xv2-2
check "330-LEB root refused for a 52 MiB bank" 1 dispatch platform_check_image "$S/mid.bin"
make_image "$S/good.bin"

converted_ap
UPGRADE_BACKUP=$S/sysupgrade.tgz dispatch platform_do_upgrade "$S/good.bin" >/dev/null 2>&1
assert "settings saved to the target bank's rootfs_data" grep -q 'restore-config rootfs_1 ' "$S/calls"
converted_ap
UPGRADE_BACKUP= dispatch platform_do_upgrade "$S/good.bin" >/dev/null 2>&1
assert "sysupgrade -n skips the settings" never_wrote 'restore-config'
assert "sysupgrade -n still copies the vault" cmp -s "$S/flash/mtd1/3.data" "$S/flash/mtd0/3.data"

converted_ap; echo mtd1/1 > "$S/corrupt"
check "readback mismatch fails the upgrade" 1 dispatch platform_do_upgrade "$S/good.bin"
assert "readback mismatch: not armed" [ "$(env_get bootcmd):$(env_get jaguar_ab_state)" = 'run jaguar_stable0:write-failed' ]
converted_ap; echo 75 > "$S/bank_lebs"
check "too little overlay space fails the upgrade" 1 dispatch platform_do_upgrade "$S/good.bin"
assert "too little space: not armed" [ "$(env_get bootcmd)" = 'run jaguar_stable0' ]
converted_ap; sed -i.bak '/^changing_bootcmd=/d' "$S/env"
check "missing changing_bootcmd refuses the upgrade" 1 dispatch platform_do_upgrade "$S/good.bin"
assert "missing changing_bootcmd: nothing written" never_wrote 'format|mkvol|update'
converted_ap cambiumnetworks,xv2-2 1; echo 4 > "$S/fail_at"
dispatch platform_do_upgrade "$S/good.bin" >/dev/null 2>&1
assert "a failed step records its command, status and error" sh -c \
	"grep -q '^jaguar_ab_last_failure=ubi[a-z]* [^:]*: exit 1: .* failed (injected)\$' '$S/env'"
rm -f "$S/fail_at"

# Interruption at every write and environment step of the upgrade.
converted_ap; rm -f "$S/opcount"
dispatch platform_do_upgrade "$S/good.bin" >/dev/null 2>&1; steps=$(cat "$S/opcount")
ok=0
for n in $(seq 1 "$steps"); do
	converted_ap; echo "$n" > "$S/fail_at"
	dispatch platform_do_upgrade "$S/good.bin" >/dev/null 2>&1; rc=$?
	rm -f "$S/fail_at"
	cmd=$(env_get bootcmd)
	if [ "$n" -lt "$steps" ]; then
		[ "$rc" != 0 ] && [ "$cmd" = 'run jaguar_stable0' ] ||
			{ ok=1; echo "    upgrade interrupted at op $n: rc=$rc bootcmd=$cmd"; }
	fi
	never_wrote '(format|mkvol|update) mtd0' || { ok=1; echo "    op $n wrote the active bank"; }
done
assert "every interruption of the $steps upgrade writes keeps slot 0 the default" [ "$ok" = 0 ]

# --- boot guard -----------------------------------------------------------------
guard() { sh "$ab_pkg/cambium-ab-guard"; }
healthy_ap() { touch "$S/net_ok"; run_board_data >/dev/null 2>&1; }
boot_slot() { # the new kernel came up from slot $1
	printf 'console=ttyMSM0 ubi.mtd=%s root=/dev/ubiblock0_1\n' "$([ "$1" = 0 ] && echo rootfs || echo rootfs_1)" > "$S/cmdline"
	rm -rf "$S/sys/ubi"; mkdir -p "$S/sys/ubi/ubi0"; echo "$1" > "$S/sys/ubi/ubi0/mtd_num"
	(. "$S/bin/_sim"; refresh ubi0 "$1")
}
# U-Boot running the armed trial command up to bootm.
uboot_trial() {
	local old=$(env_get jaguar_ab_confirmed)
	sed -i.bak -e "s/^bootcmd=.*/bootcmd=run jaguar_stable$old/" -e "s/^image=.*/image=$old/" \
		-e 's/^jaguar_ab_state=.*/jaguar_ab_state=trial-started/' "$S/env"
}

converted_ap; dispatch platform_do_upgrade "$S/good.bin" >/dev/null 2>&1
uboot_trial; boot_slot 1; healthy_ap; : > "$S/calls"
echo 'jaguar_ab_last_failure=cannot format slot 1' >> "$S/env"
check "healthy trial of slot 1 committed" 0 guard
assert "a committed trial clears the earlier failure" [ -z "$(env_get jaguar_ab_last_failure)" ]
assert "slot 1 confirmed and default" [ "$(env_get jaguar_ab_confirmed):$(env_get jaguar_ab_state):$(env_get bootcmd):$(env_get image)" = '1:confirmed:run jaguar_stable1:1' ]
assert "trial target cleared" [ -z "$(env_get jaguar_ab_target)" ]
assert "no reboot after a healthy trial" never_wrote reboot
check "reverse upgrade 1 -> 0 accepted after commit" 0 dispatch platform_check_image "$S/good.bin"

converted_ap; dispatch platform_do_upgrade "$S/good.bin" >/dev/null 2>&1
uboot_trial; boot_slot 1; run_board_data >/dev/null 2>&1; : > "$S/calls"
check "unhealthy trial (no DHCP) rolls back" 0 guard
assert "unhealthy trial recorded" [ "$(env_get jaguar_ab_state)" = rolled-back ]
assert "unhealthy trial records the failed predicate" [ "$(env_get jaguar_ab_last_failure)" = \
	'slot 1 failed: management interface br-lan has no IPv4 address' ]
assert "unhealthy trial rebooted" grep -q reboot "$S/calls"
assert "failed trial retains the management predicate" grep -q 'failure=management interface br-lan has no IPv4 address' "$S/health/network-boot.health"
assert "health snapshot is bounded" sh -c '[ "$(wc -c < "$1")" -le 12288 ]' sh "$S/health/network-boot.health"
assert "health snapshot is private" [ "$(stat -c %a "$S/health/network-boot.health")" = 600 ]
assert "unhealthy trial leaves slot 0 the default" [ "$(env_get bootcmd):$(env_get jaguar_ab_confirmed)" = 'run jaguar_stable0:0' ]

converted_ap; dispatch platform_do_upgrade "$S/good.bin" >/dev/null 2>&1
uboot_trial; boot_slot 0; healthy_ap
check "trial that did not boot is recorded" 1 guard
assert "rollback recorded with slot 0 kept" [ "$(env_get jaguar_ab_state):$(env_get bootcmd)" = 'rolled-back:run jaguar_stable0' ]
check "upgrade allowed again after a rollback" 0 dispatch platform_check_image "$S/good.bin"

converted_ap; boot_slot 1; healthy_ap; : > "$S/calls"
check "confirmed bank failing to boot is reported" 0 guard
assert "fallback state recorded once" [ "$(env_get jaguar_ab_state)" = fallback ]
: > "$S/calls"; guard >/dev/null 2>&1
assert "fallback not re-recorded every boot" never_wrote setenv

converted_ap; boot_slot 0; healthy_ap; : > "$S/calls"
check "healthy confirmed boot" 0 guard
assert "healthy confirmed boot writes nothing" never_wrote 'setenv|reboot'

new_ap; healthy_ap; : > "$S/calls"
check "legacy guard re-arms the OEM-fallback one-shot" 0 guard
assert "legacy one-shot is the validated command" [ "$(env_get bootcmd)" = 'setenv bootcmd bootipq; setenv changing_bootcmd; saveenv; nand device 0 && setenv mtdids nand0=nand0 && setenv mtdparts "mtdparts=nand0:0x6000000@0x0(rootfs)" && ubi part rootfs && ubi read 0x60000000 kernel && setenv bootargs "console=ttyMSM0,115200n8 cnss2.bdf_pci0=0xab ubi.mtd=rootfs root=/dev/ubiblock0_1 rootfstype=squashfs rootwait swiotlb=1" && bootm 0x60000000#config@cp01-c1-2; reset' ]
new_ap cambiumnetworks,xv2-2; healthy_ap
check "XV2-2 legacy guard re-arms" 0 guard
assert "XV2-2 legacy one-shot boots its 52 MiB slot 0" [ "$(env_get bootcmd)" = 'setenv bootcmd bootipq; setenv changing_bootcmd; saveenv; nand device 0 && setenv mtdids nand0=nand0 && setenv mtdparts "mtdparts=nand0:0x3400000@0x0(rootfs)" && ubi part rootfs && ubi read 0x60000000 kernel && setenv bootargs "console=ttyMSM0,115200n8 cnss2.bdf_pci0=0xab ubi.mtd=rootfs root=/dev/ubiblock0_1 rootfstype=squashfs rootwait swiotlb=1" && bootm 0x60000000#config@cp01-c1; reset' ]
new_ap cambiumnetworks,xv2-2 1 oem; sed -i.bak 's/^image=.*/image=0/' "$S/env"; healthy_ap
check "XV2-2 legacy guard re-arms OpenWrt in slot 1" 0 guard
assert "slot-1 guarded one-shot uses the booted (fs) form" [ "$(env_get bootcmd)" = 'setenv bootcmd bootipq; setenv changing_bootcmd; saveenv; nand device 0 && setenv mtdids nand0=nand0 && setenv mtdparts "mtdparts=nand0:0x3400000@0x3400000(fs)" && ubi part fs && ubi read 0x60000000 kernel && setenv bootargs "console=ttyMSM0,115200n8 cnss2.bdf_pci0=0xab ubi.mtd=rootfs_1 root=/dev/ubiblock0_1 rootfstype=squashfs rootwait swiotlb=1" && bootm 0x60000000#config@cp01-c1; reset' ]
new_ap cambiumnetworks,xv2-2 1 oem; healthy_ap; : > "$S/calls"
check "slot-1 guard refuses when image is not the stock slot" 1 guard
assert "wrong image: nothing written" never_wrote setenv
new_ap; healthy_ap; : > "$S/calls"; guard >/dev/null 2>&1
assert "legacy writes changing_bootcmd before bootcmd" [ "$(grep setenv "$S/calls" | tr '\n' ' ')" = 'setenv changing_bootcmd setenv bootcmd ' ]
new_ap; healthy_ap; sed -i.bak 's/^bootcmd=.*/bootcmd=something-else/' "$S/env"; : > "$S/calls"
check "legacy guard leaves a changed bootcmd alone" 1 guard
assert "changed bootcmd not overwritten" never_wrote setenv
new_ap; run_board_data >/dev/null 2>&1; : > "$S/calls"
check "legacy guard: unhealthy start returns to OEM" 0 guard
assert "legacy unhealthy start rebooted" grep -q reboot "$S/calls"
assert "legacy unhealthy start wrote no environment" never_wrote setenv
# A single-bank install whose default boot is OpenWrt itself (the XV3-8 on
# 25 Sep): rebooting would only boot OpenWrt again, every few minutes.
new_ap cambiumnetworks,xv3-8; run_board_data >/dev/null 2>&1
sed -i.bak 's/^bootcmd=.*/bootcmd=aq_load_fw; nand device 0; ubi part rootfs; bootm 0x60000000#config@hk02/' "$S/env"; : > "$S/calls"
check "unhealthy committed single-bank install: guard reports failure" 1 guard
assert "unhealthy committed install is not rebooted" never_wrote 'reboot|setenv'
new_ap cambiumnetworks,xe3-4; rm -rf "$S/dt/cambium-platform"; : > "$S/calls"
check "guard ignores upstream XE3-4 images" 0 guard
assert "upstream XE3-4 untouched by the guard" never_wrote 'setenv|reboot'

converted_ap; boot_slot 0; healthy_ap
assert "status reports A/B mode" sh -c "sh '$ab_pkg/cambium-ab-status' | grep -qx 'mode=ab'"
assert "status reports the confirmed slot" sh -c "sh '$ab_pkg/cambium-ab-status' | grep -qx 'confirmed=0'"

# --- Cheetah (cambium-ab-cheetah.sh) --------------------------------------------
C21=cambiumnetworks,xv2-21x
while read -r board fit; do
	new_ap "$board"
	check "Cheetah $board identity" 0 in_lib eval \
		'ab_identity && [ "$AB_FAMILY:$AB_ACTIVE:$AB_TARGET:$AB_FIT" = "cheetah:0:1:'"$fit"'" ]'
done <<'EOF'
cambiumnetworks,xv2-21x config@mp03.3-ocelot
cambiumnetworks,xv2-22h config@mp03.3-cheetah
cambiumnetworks,xv2-23t config@mp03.3-lynx
EOF
new_ap $C21; echo 0xc00 > "$S/sys/mtd/mtd6/flags"
check "Cheetah writable 0:TRAINING refused" 1 in_lib ab_identity
new_ap $C21; set_sku 042
check "Cheetah SKU mismatch refused" 1 in_lib ab_identity
new_ap $C21
assert "Cheetah slot 0 boot command (bank at 0x80000, bootargs set)" [ "$(in_lib eval "ab_board $C21; ab_boot_command 0")" = \
	'nand device 0; setenv mtdids nand0=nand0; setenv mtdparts "mtdparts=nand0:0x6000000@0x80000(fs)"; ubi part fs && ubi read 0x60000000 kernel && setenv bootargs "console=ttyMSM0,115200n8 ubi.mtd=rootfs root=/dev/ubiblock0_1 rootfstype=squashfs rootwait" && bootm 0x60000000#config@mp03.3-ocelot' ]
assert "Cheetah slot 1 boot command (bank at 0x6080000)" [ "$(in_lib eval "ab_board $C21; ab_boot_command 1")" = \
	'nand device 0; setenv mtdids nand0=nand0; setenv mtdparts "mtdparts=nand0:0x6000000@0x6080000(fs)"; ubi part fs && ubi read 0x60000000 kernel && setenv bootargs "console=ttyMSM0,115200n8 ubi.mtd=rootfs_1 root=/dev/ubiblock0_1 rootfstype=squashfs rootwait" && bootm 0x60000000#config@mp03.3-ocelot' ]
assert "Cheetah trial uses the cheetah_ variables" [ "$(in_lib eval "ab_board $C21; ab_trial_command 0 1")" = \
	'setenv bootcmd run cheetah_stable0; setenv image 0; setenv cheetah_ab_state trial-started; saveenv; run cheetah_boot1; run cheetah_boot0' ]

new_ap $C21; oem_before=$(bank_hash 1)
check "Cheetah first boot fills the vault with both board files" 0 run_board_data
assert "Cheetah vault status" [ "$(cat "$S/bdstatus")" = vault ]
assert "Cheetah IPQ5018 and QCN6122 board files installed" [ -s "$S/fw/ath11k/IPQ5018/hw1.0/board.bin" -a -s "$S/fw/ath11k/QCN6122/hw1.0/board.bin" ]
assert "Cheetah OEM bank unchanged by the import" [ "$(bank_hash 1)" = "$oem_before" ]

new_ap $C21; run_board_data >/dev/null 2>&1; : > "$S/calls"
check "Cheetah XV2-21X conversion (validated: no --allow-untested)" 0 sh "$ab_pkg/cambium-ab-convert" --oem-sha256 "$(oem_hash)" --yes
assert "Cheetah converted: cheetah_ variables, slot 0 default" [ "$(env_get cheetah_ab_version):$(env_get cheetah_ab_confirmed):$(env_get bootcmd)" = '1:0:run cheetah_stable0' ]
assert "Cheetah slot 1 boots rootfs_1 at 0x6080000" [ "$(env_get cheetah_boot1)" = \
	'nand device 0; setenv mtdids nand0=nand0; setenv mtdparts "mtdparts=nand0:0x6000000@0x6080000(fs)"; ubi part fs && ubi read 0x60000000 kernel && setenv bootargs "console=ttyMSM0,115200n8 ubi.mtd=rootfs_1 root=/dev/ubiblock0_1 rootfstype=squashfs rootwait" && bootm 0x60000000#config@mp03.3-ocelot' ]
assert "Cheetah slot 1 holds the running rootfs and vault" cmp -s "$S/flash/mtd1/1.data" "$S/flash/mtd0/1.data"

make_fit config@mp03.3-cheetah config@mp03.3-ocelot config@mp03.3-lynx > "$S/cheetah-fit"
make_image "$S/cheetah.bin" "$S/cheetah-fit" "" sysupgrade-cambiumnetworks_cheetah
check "a Jaguar image is refused on a Cheetah" 1 dispatch platform_check_image "$S/good.bin"
for active in 0 1; do
	target=$((1 - active))
	converted_ap $C21 "$active"
	active_before=$(bank_hash "$active")
	check "Cheetah upgrade slot $active -> $target" 0 dispatch platform_do_upgrade "$S/cheetah.bin"
	assert "Cheetah slot $target rootfs written" [ "$(cat "$S/flash/mtd$target/1.data")" = hsqs-new-root ]
	assert "Cheetah slot $target vault copied" cmp -s "$S/flash/mtd$target/3.data" "$S/flash/mtd$active/3.data"
	assert "Cheetah slot $active untouched" [ "$(bank_hash "$active")" = "$active_before" ]
	assert "Cheetah trial of slot $target armed" [ "$(env_get bootcmd)" = \
		"setenv bootcmd run cheetah_stable$active; setenv image $active; setenv cheetah_ab_state trial-started; saveenv; run cheetah_boot$target; run cheetah_boot$active" ]
done

cheetah_trial() {
	local old=$(env_get cheetah_ab_confirmed)
	sed -i.bak -e "s/^bootcmd=.*/bootcmd=run cheetah_stable$old/" -e "s/^image=.*/image=$old/" \
		-e 's/^cheetah_ab_state=.*/cheetah_ab_state=trial-started/' "$S/env"
}
converted_ap $C21; dispatch platform_do_upgrade "$S/cheetah.bin" >/dev/null 2>&1
cheetah_trial; boot_slot 1; healthy_ap; : > "$S/calls"
check "Cheetah trial without its two radios is not committed" 0 guard
assert "no radios: rolled back" [ "$(env_get cheetah_ab_state)" = rolled-back ]
converted_ap $C21; dispatch platform_do_upgrade "$S/cheetah.bin" >/dev/null 2>&1
cheetah_trial; boot_slot 1; healthy_ap; mkdir -p "$S/ieee80211/phy0" "$S/ieee80211/phy1" "$S/net/br-lan.1"; : > "$S/calls"
check "Cheetah healthy trial (two radios, br-lan.1) committed" 0 guard
assert "Cheetah slot 1 confirmed" [ "$(env_get cheetah_ab_confirmed):$(env_get cheetah_ab_state):$(env_get bootcmd)" = '1:confirmed:run cheetah_stable1' ]

new_ap $C21; healthy_ap; mkdir -p "$S/ieee80211/phy0" "$S/ieee80211/phy1"; : > "$S/calls"
check "Cheetah legacy guard re-arms slot 0" 0 guard
assert "Cheetah legacy one-shot is the validated command with bootargs" [ "$(env_get bootcmd)" = \
	'setenv bootcmd bootipq; setenv changing_bootcmd; saveenv; nand device 0; setenv mtdids nand0=nand0; setenv mtdparts "mtdparts=nand0:0x6000000@0x80000(fs)"; ubi part fs && ubi read 0x60000000 kernel && setenv bootargs "console=ttyMSM0,115200n8 ubi.mtd=rootfs root=/dev/ubiblock0_1 rootfstype=squashfs rootwait" && bootm 0x60000000#config@mp03.3-ocelot; bootipq' ]
new_ap cambiumnetworks,xv2-22h; healthy_ap; : > "$S/calls"
check "XV2-22H needs no radios to re-arm" 0 guard
assert "XV2-22H legacy one-shot" grep -q 'bootm 0x60000000#config@mp03.3-cheetah; bootipq$' "$S/env"
assert "status names the Cheetah family" sh -c "sh '$ab_pkg/cambium-ab-status' | grep -qx 'family=cheetah'"

# --- Thor (cambium-ab-thor.sh) -----------------------------------------------------
T=cambiumnetworks,xv3-8
new_ap $T
check "Thor identity" 0 in_lib eval \
	'ab_identity && [ "$AB_FAMILY:$AB_ACTIVE:$AB_TARGET:$AB_FIT:$AB_STOCK_BOOTCMD" = "thor:0:1:config@hk02:aq_load_fw&&bootipq" ]'
new_ap $T; echo 0xc00 > "$S/sys/mtd/mtd2/flags"
check "Thor writable 0:ETHPHYFW refused" 1 in_lib ab_identity
new_ap $T
assert "Thor slot 0 boot command (config@hk02 is rooted in rootfs)" [ "$(in_lib eval "ab_board $T; ab_boot_command 0")" = \
	'aq_load_fw; nand device 0 && setenv mtdids nand0=nand0 && setenv mtdparts "mtdparts=nand0:0x6000000@0x0(rootfs)" && ubi part rootfs && ubi read 0x60000000 kernel && bootm 0x60000000#config@hk02' ]
assert "Thor slot 1 boot command (config@hk02-bank1)" [ "$(in_lib eval "ab_board $T; ab_boot_command 1")" = \
	'aq_load_fw; nand device 0 && setenv mtdids nand0=nand0 && setenv mtdparts "mtdparts=nand0:0x6000000@0x6000000(fs)" && ubi part fs && ubi read 0x60000000 kernel && bootm 0x60000000#config@hk02-bank1' ]
assert "Thor guarded command restores the stock default first" [ "$(in_lib eval "ab_board $T; ab_guarded_command 0")" = \
	'setenv changing_bootcmd; setenv bootcmd "aq_load_fw&&bootipq"; saveenv; aq_load_fw; nand device 0 && setenv mtdids nand0=nand0 && setenv mtdparts "mtdparts=nand0:0x6000000@0x0(rootfs)" && ubi part rootfs && ubi read 0x60000000 kernel && bootm 0x60000000#config@hk02; bootipq' ]

new_ap $T; oem_before=$(bank_hash 1)
check "Thor first boot fills the vault" 0 run_board_data
assert "Thor vault status" [ "$(cat "$S/bdstatus")" = vault ]
assert "Thor IPQ8074 board file installed" [ -s "$S/fw/ath11k/IPQ8074/hw2.0/board.bin" ]
assert "Thor OEM bank unchanged by the import" [ "$(bank_hash 1)" = "$oem_before" ]

# A single-bank install upgraded in place to the A/B image: its bank has no
# vault and the stock bank is writable, yet the board file is still read
# from it (read-only), as on the XV3-8 on 25 Sep.
new_ap $T; rm -f "$S/flash/mtd0/3."*; (. "$S/bin/_sim"; refresh ubi0 0); oem_before=$(bank_hash 1)
check "no vault, writable stock bank: board data imported" 0 run_board_data
assert "no vault: status imported" [ "$(cat "$S/bdstatus")" = imported ]
assert "no vault: IPQ8074 board file installed" [ -s "$S/fw/ath11k/IPQ8074/hw2.0/board.bin" ]
assert "no vault: stock bank unchanged" [ "$(bank_hash 1)" = "$oem_before" ]
# thor_radios N [scanner]: N serving radios of the IPQ8074 Wi-Fi block, and
# the QCA9887 scanning radio on PCIe, as sysfs links them to their devices.
thor_radios() {
	local i=0 soc="$S/sysdev/platform/soc@0"
	mkdir -p "$soc/c000000.wifi" "$soc/10000000.pcie/pci0001:00/0001:00:00.0/0001:01:00.0"
	while [ "$i" -lt "$1" ]; do
		mkdir -p "$S/ieee80211/phy$i"
		ln -sfn "$soc/c000000.wifi" "$S/ieee80211/phy$i/device"
		i=$((i + 1))
	done
	if [ -n "${2:-}" ]; then
		mkdir -p "$S/ieee80211/phy9"
		ln -sfn "$soc/10000000.pcie/pci0001:00/0001:00:00.0/0001:01:00.0" "$S/ieee80211/phy9/device"
	fi
}
new_ap $T; healthy_ap; thor_radios 3; : > "$S/calls"
check "Thor legacy guard re-arms slot 0 (no image variable)" 0 guard
assert "Thor legacy one-shot is the module's guarded command" [ "$(env_get bootcmd)" = "$(in_lib eval "ab_board $T; ab_guarded_command 0")" ]
new_ap $T; healthy_ap; thor_radios 2; : > "$S/calls"
check "Thor with two of its three radios is unhealthy" 0 guard
assert "Thor unhealthy start returns to the stock firmware" grep -q reboot "$S/calls"
# The QCA9887 scanning radio is a phy too, but not a serving radio.
new_ap $T; healthy_ap; thor_radios 2 scanner; : > "$S/calls"
check "two serving radios plus the scanner are still unhealthy" 0 guard
assert "the scanner does not stand in for a serving radio" grep -q reboot "$S/calls"
new_ap $T; healthy_ap; thor_radios 3 scanner; : > "$S/calls"
check "three serving radios plus the scanner: healthy" 0 guard
assert "all three serving radios up re-arms OpenWrt" never_wrote reboot
# single-8x8 mode: 2.4 GHz plus one 8x8 5 GHz radio.
new_ap $T; healthy_ap; thor_radios 2 scanner; mkdir -p "$S/module/ath11k/parameters"
echo single-8x8 > "$S/module/ath11k/parameters/xv3_8_hw_mode"; : > "$S/calls"
check "single-8x8 with its two serving radios: healthy" 0 guard
assert "single-8x8 re-arms OpenWrt" never_wrote reboot
new_ap $T; healthy_ap; thor_radios 1 scanner; mkdir -p "$S/module/ath11k/parameters"
echo single-8x8 > "$S/module/ath11k/parameters/xv3_8_hw_mode"; : > "$S/calls"
check "single-8x8 with one serving radio: unhealthy" 0 guard
assert "single-8x8 missing a radio returns to the stock firmware" grep -q reboot "$S/calls"
# The guard checks the device the lan network is configured on: a missing
# VLAN bridge fails the check rather than passing on br-lan.
new_ap $T; healthy_ap; thor_radios 3
echo br-lan.1 > "$S/lan_device"; : > "$S/calls"
check "configured br-lan.1 missing: unhealthy" 0 guard
assert "missing br-lan.1 returns to the stock firmware" grep -q reboot "$S/calls"
new_ap $T; healthy_ap; thor_radios 3; mkdir -p "$S/net/br-lan.1"
echo br-lan.1 > "$S/lan_device"; : > "$S/calls"
check "configured br-lan.1 present: healthy" 0 guard
assert "present br-lan.1 re-arms OpenWrt" never_wrote reboot
new_ap $T; healthy_ap; thor_radios 3; mkdir -p "$S/net/br-lan.1"
echo br-lan > "$S/lan_device"; : > "$S/calls"
check "a network left on br-lan is checked on br-lan" 0 guard
assert "br-lan configuration re-arms OpenWrt" never_wrote reboot
# Configured management networks may use arbitrary section names. Before
# DHCP has installed a route, the guard must still name/check that tagged
# management device rather than an unrelated raw Ethernet fallback.
new_ap $T; healthy_ap; thor_radios 3; touch "$S/no_default"
echo up0v101 > "$S/management_section"; echo up0v101 > "$S/management_device"; : > "$S/calls"
check "missing configured management VLAN is unhealthy" 0 guard
assert "missing management VLAN returns to stock firmware" grep -q reboot "$S/calls"
new_ap $T; healthy_ap; thor_radios 3; touch "$S/no_default"; mkdir -p "$S/net/up0v101"
echo up0v101 > "$S/management_section"; echo up0v101 > "$S/management_device"; : > "$S/calls"
check "configured management VLAN is checked before its route exists" 0 guard
assert "configured management VLAN without a route remains unhealthy" grep -q reboot "$S/calls"
new_ap $T; healthy_ap; thor_radios 3; mkdir -p "$S/net/up0v101"
echo up0v101 > "$S/default_dev"; : > "$S/calls"
check "default route identifies management without readable UCI" 0 guard
assert "routed management interface re-arms OpenWrt" never_wrote reboot
# A validated single-bank install: OpenWrt is the committed default.
new_ap $T; healthy_ap; thor_radios 3
sed -i.bak 's/^bootcmd=.*/bootcmd=aq_load_fw; nand device 0; ubi part rootfs; bootm 0x60000000#config@hk02/' "$S/env"; : > "$S/calls"
check "Thor guard leaves a committed single-bank install alone" 1 guard
assert "committed single-bank bootcmd kept" never_wrote setenv

new_ap $T; run_board_data >/dev/null 2>&1; : > "$S/calls"
check "Thor conversion (XV3-8 validated: no --allow-untested)" 0 sh "$ab_pkg/cambium-ab-convert" --oem-sha256 "$(oem_hash)" --yes
assert "Thor converted: thor_ variables, slot 0 default" [ "$(env_get thor_ab_version):$(env_get thor_ab_confirmed):$(env_get bootcmd)" = '1:0:run thor_stable0' ]
assert "Thor stable command" [ "$(env_get thor_stable0)" = 'run thor_boot0; run thor_boot1' ]

# The ipq807x platform.sh sends Thor to the A/B writer.
dispatch807x() { (. "$S/system.sh"; . "$S/functions.sh"; . "$CAMBIUM_AB_UPGRADE_LIB"
	eval "$(sed -n '/^platform_check_image() {/,/^}/p; /^platform_do_upgrade() {/,/^}/p' \
		"$top/target/linux/qualcommax/ipq807x/base-files/lib/upgrade/platform.sh")"
	nand_restore_config() { echo "restore-config $CI_UBIPART $1" >> "$S/calls"; }
	[ "$1" = platform_do_upgrade ] && touch "$S/no_hotplug"
	"$@"; rc=$?; rm -f "$S/no_hotplug"; exit $rc); }
make_fit config@hk02 config@hk02-bank1 > "$S/thor-fit"
make_image "$S/thor.bin" "$S/thor-fit" "" sysupgrade-cambiumnetworks_xv3-8
new_ap $T; run_board_data >/dev/null 2>&1
check "unconverted Thor refuses sysupgrade" 1 dispatch807x platform_check_image "$S/thor.bin"
assert "unconverted Thor never reaches nand_do_upgrade" never_wrote 'generic-nand'
converted_ap $T
check "a Jaguar image is refused on a Thor" 1 dispatch807x platform_check_image "$S/good.bin"
check "Thor image check" 0 dispatch807x platform_check_image "$S/thor.bin"
active_before=$(bank_hash 0)
check "Thor upgrade slot 0 -> 1" 0 dispatch807x platform_do_upgrade "$S/thor.bin"
assert "Thor slot 1 rootfs written" [ "$(cat "$S/flash/mtd1/1.data")" = hsqs-new-root ]
assert "Thor slot 1 vault copied" cmp -s "$S/flash/mtd1/3.data" "$S/flash/mtd0/3.data"
assert "Thor slot 0 untouched" [ "$(bank_hash 0)" = "$active_before" ]
assert "Thor trial of slot 1 armed" [ "$(env_get bootcmd)" = \
	'setenv bootcmd run thor_stable0; setenv image 0; setenv thor_ab_state trial-started; saveenv; run thor_boot1; run thor_boot0' ]
sed -i.bak -e 's/^bootcmd=.*/bootcmd=run thor_stable0/' -e 's/^thor_ab_state=.*/thor_ab_state=trial-started/' "$S/env"
boot_slot 1; healthy_ap; thor_radios 3; mkdir -p "$S/net/br-lan.1"; : > "$S/calls"
check "Thor healthy trial committed" 0 guard
assert "Thor slot 1 confirmed" [ "$(env_get thor_ab_confirmed):$(env_get thor_ab_state):$(env_get bootcmd)" = '1:confirmed:run thor_stable1' ]
assert "status names the Thor family" sh -c "sh '$ab_pkg/cambium-ab-status' | grep -qx 'family=thor'"

# --- Sage (cambium-ab-sage.sh) --------------------------------------------------
# One UBI device on the SPI-NAND "fs" partition holds linux0/rootfs0,
# linux1/rootfs1 and nvram; each root is a writable UBIFS.
E=cambium,e410
sage0='setenv image 0; setenv bootargs "mtdparts=spi0.1:128M(fs) ubi.mtd=fs root=ubi0:rootfs0 rootfstype=ubifs rootwait"; nand device 1 && setenv mtdids nand1=nand1 && setenv mtdparts "mtdparts=nand1:0x8000000@0x0(fs)" && ubi part fs && ubi read 0x84000000 linux0 && bootm 0x84000000#config@ap.dk01.1-c2'
sage1='setenv image 1; setenv bootargs "mtdparts=spi0.1:128M(fs) ubi.mtd=fs root=ubi0:rootfs1 rootfstype=ubifs rootwait"; nand device 1 && setenv mtdids nand1=nand1 && setenv mtdparts "mtdparts=nand1:0x8000000@0x0(fs)" && ubi part fs && ubi read 0x84000000 linux1 && bootm 0x84000000#config@ap.dk01.1-c2'
# new_sage_ap [BOARD] [RUNNING-PAIR] [stock|adopted]
new_sage_ap() {
	local board=${1:-cambium,e410} active=${2:-0} kind=${3:-adopted} other i v
	other=$((1 - active))
	rm -rf "$S/sys" "$S/dev" "$S/flash" "$S/dt" "$S/fw" "$S/work" "$S/net" "$S/ieee80211" "$S/newroot"
	rm -f "$S/calls" "$S/opcount" "$S/fail_at" "$S/corrupt" "$S/bdstatus" "$S/net_ok" "$S/lan_device" \
		"$S/default_dev" "$S/no_default" "$S/management_section" "$S/management_device"
	mkdir -p "$S/sys/ubi/ubi0" "$S/dev" "$S/flash/mtd2" "$S/dt/cambium-platform" "$S/fw" "$S/net" "$S/ieee80211"
	touch "$S/calls"
	echo "$board" > "$S/board"
	set_sku "$(sku_byte "$board")"
	printf '%s\n' 'dev:    size   erasesize  name' \
		'mtd0: 00010000 00010000 "0:APPSBLENV"' 'mtd1: 00010000 00010000 "0:ART"' \
		'mtd2: 08000000 00020000 "fs"' > "$S/proc_mtd"
	for i in 0 1 2; do mkdir -p "$S/sys/mtd/mtd$i"; echo 0xc00 > "$S/sys/mtd/mtd$i/flags"; done
	echo 0x800 > "$S/sys/mtd/mtd1/flags"
	i=0
	for v in linux0 rootfs0 linux1 rootfs1 nvram; do
		echo "$v" > "$S/flash/mtd2/$i.name"
		case "$v" in linux*) echo 4317184 ;; rootfs*) echo 47235072 ;; *) echo "$LEB" ;; esac > "$S/flash/mtd2/$i.size"
		printf 'old-%s' "$v" > "$S/flash/mtd2/$i.data"
		i=$((i + 1))
	done
	echo 834 > "$S/bank_lebs"
	echo 2 > "$S/sys/ubi/ubi0/mtd_num"
	(. "$S/bin/_sim"; refresh ubi0 2)
	echo "console=ttyMSM0 root=ubi0:rootfs$active rootfstype=ubifs rootwait" > "$S/cmdline"
	echo "ubi0:rootfs$active / ubifs rw,noatime 0 0" > "$S/mounts"
	case "$kind" in
	stock)
		# The preserved OEM pair remains the fallback until the first upgrade.
		printf '%s\n' "bootcmd=setenv image $active; nand device 1 && bootm 0x84000000#config@ap.dk01.1-c2; setenv image $other; bootipq" \
			"image=$active" "owrt_migration_state=committed" > "$S/env" ;;
	adopted)
		printf '%s\n' "sage_boot0=$sage0" "sage_boot1=$sage1" "sage_stable0=run sage_boot0; run sage_boot1" \
			"sage_stable1=run sage_boot1; run sage_boot0" "bootcmd=run sage_stable$active" "image=$active" \
			"sage_ab_version=1" "sage_ab_confirmed=$active" "sage_ab_state=confirmed" "e410_upgrade_state=migrated" > "$S/env" ;;
	esac
}
healthy_sage() { touch "$S/net_ok"; mkdir -p "$S/ieee80211/phy0" "$S/ieee80211/phy1"; }
# The ipq40xx platform.sh dispatch; platform_do_upgrade runs without hotplug.
dispatch40xx() { (. "$S/system.sh"; . "$S/functions.sh"; . "$CAMBIUM_AB_UPGRADE_LIB"
	eval "$(sed -n '/^platform_check_image() {/,/^}/p; /^platform_do_upgrade() {/,/^}/p' \
		"$top/target/linux/ipq40xx/base-files/lib/upgrade/platform.sh")"
	[ "$1" = platform_do_upgrade ] && touch "$S/no_hotplug"
	"$@"; rc=$?; rm -f "$S/no_hotplug"; exit $rc); }
pair_data() { cat "$S/flash/mtd2/$1.data"; }
{ printf '\061\030\020\006'; printf 'new-ubifs-root'; } > "$S/sage-ubifs-root"
printf 'hsqs-new-root' > "$S/sage-root"
make_fit config@5 config@ap.dk01.1-c2 config@16 config@17 > "$S/sage-fit"
make_image "$S/sage-ubifs.bin" "$S/sage-fit" "$S/sage-ubifs-root" sysupgrade-cambium_e410
make_image "$S/sage.bin" "$S/sage-fit" "$S/sage-root" sysupgrade-cambium_e410

# Board table, identity and boot commands.
new_sage_ap $E 0
check "E410 identity" 0 in_lib eval \
	'ab_identity && [ "$AB_FAMILY:$AB_LAYOUT:$AB_ACTIVE:$AB_TARGET:$AB_FIT:$AB_SKU" = "sage:pair:0:1:config@ap.dk01.1-c2:0000000a" ]'
new_sage_ap $E 1
check "E410 running pair 1 targets pair 0" 0 in_lib eval '[ "$(ab_identity && echo $AB_ACTIVE:$AB_TARGET:$AB_TARGET_PART)" = "1:0:linux0/rootfs0" ]'
new_sage_ap cambiumnetworks,e600 0
check "E600 refused (layout not captured)" 1 in_lib ab_identity
new_sage_ap $E 0; set_sku 020
check "E410 SKU mismatch refused" 1 in_lib ab_identity
new_sage_ap $E 0; echo 0xc00 > "$S/sys/mtd/mtd1/flags"
check "E410 writable ART refused" 1 in_lib ab_identity
assert "Sage slot 0 boot command is the validated E410 command" [ "$(in_lib eval "ab_board $E; ab_boot_command 0")" = "$sage0" ]
assert "Sage slot 1 boot command is the validated E410 command" [ "$(in_lib eval "ab_board $E; ab_boot_command 1")" = "$sage1" ]
assert "E510 boot commands use config@16" in_lib eval "ab_board cambiumnetworks,e510; ab_boot_command 1 | grep -q '#config@16\$'"

# A B-suffix unit running the legacy E410 tree keeps its confirmed pair on
# config@5, and trials config@17 only on the freshly written pair.
new_sage_ap $E 0 adopted
printf '%s\n' 'mtd3: 00010000 00010000 "mfginfo"' >> "$S/proc_mtd"
printf '%s\000' 'PL-E410XXXB-EU' > "$S/dev/mtd3ro"
check "legacy E410B factory marker selects config@17 target" 0 in_lib eval \
	'ab_identity && [ "$AB_FIT:$AB_MODEL:$AB_SKU" = "config@17:E410B:0000000a" ]'
assert "legacy B confirmed pair still boots config@5" in_lib eval \
	'ab_identity && ab_boot_command 0 | grep -q "#config@ap.dk01.1-c2$"'
assert "legacy B target pair trials config@17" in_lib eval \
	'ab_identity && ab_boot_command 1 | grep -q "#config@17$"'
check "legacy B pair upgrade arms the model-specific trial" 0 dispatch40xx platform_do_upgrade "$S/sage.bin"
assert "legacy B fallback boot command remains E410" sh -c "grep -q '^sage_boot0=.*#config@ap.dk01.1-c2$' '$S/env'"
assert "legacy B trial boot command selects E410B" sh -c "grep -q '^sage_boot1=.*#config@17$' '$S/env'"

new_sage_ap $E 0 stock; healthy_sage; : > "$S/calls"
check "stock firmware in the other pair: guard does nothing" 0 guard
assert "stock pair: no environment written, no reboot" never_wrote 'setenv|reboot'
new_sage_ap $E 0 adopted; healthy_sage; : > "$S/calls"
check "adopted Sage: guard has nothing to do" 0 guard
assert "adopted: no environment written" never_wrote 'setenv|reboot'
assert "status names the Sage family in A/B mode" sh -c "sh '$ab_pkg/cambium-ab-status' | grep -q '^mode=ab' && sh '$ab_pkg/cambium-ab-status' | grep -qx 'family=sage'"
check "cambium-ab-convert refuses Sage (no conversion step)" 1 sh "$ab_pkg/cambium-ab-convert" --oem-sha256 0123abcd --yes

# Sysupgrade through the ipq40xx platform.sh and the shared writer.
new_sage_ap $E 0 adopted; echo keep-this-config > "$S/backup.tgz"; : > "$S/calls"
check "Sage image check" 0 dispatch40xx platform_check_image "$S/sage.bin"
export UPGRADE_BACKUP=$S/backup.tgz BACKUP_FILE=sysupgrade.tgz
check "Sage upgrade pair 0 -> 1" 0 dispatch40xx platform_do_upgrade "$S/sage.bin"
unset UPGRADE_BACKUP
assert "pair 1 kernel written" cmp -s "$S/flash/mtd2/2.data" "$S/img/sysupgrade-cambium_e410/kernel"
assert "pair 1 SquashFS root written" cmp -s "$S/flash/mtd2/3.data" "$S/sage-root"
assert "converted rootfs1 keeps UBI ID 3 at 305 LEBs" [ "$(cat "$S/sys/ubi/ubi0_3/name" "$S/sys/ubi/ubi0_3/reserved_ebs" | tr '\n' ':')" = 'rootfs1:305:' ]
assert "pair 1 gets its own 67-LEB overlay" [ "$(cat "$S/sys/ubi/ubi0_5/name" "$S/sys/ubi/ubi0_5/reserved_ebs" | tr '\n' ':')" = 'rootfs_data1:67:' ]
assert "confirmed pair 0 still boots UBIFS" sh -c "grep -q '^sage_boot0=.*root=ubi0:rootfs0 rootfstype=ubifs' '$S/env'"
assert "trial pair 1 boots SquashFS with its own overlay" sh -c "grep -q '^sage_boot1=.*ubi.block=0,rootfs1.*fstools_overlay_name=rootfs_data1' '$S/env'"
assert "shared UBI device was never formatted" never_wrote 'format mtd2'
assert "running pair 0 untouched" [ "$(pair_data 0):$(pair_data 1)" = 'old-linux0:old-rootfs0' ]
assert "nvram untouched" [ "$(pair_data 4)" = old-nvram ]
assert "configuration carried into the new root" cmp -s "$S/newroot/sysupgrade.tgz" "$S/backup.tgz"
assert "trial of pair 1 armed, pair 0 restored first" [ "$(env_get bootcmd)" = \
	'setenv bootcmd run sage_stable0; setenv image 0; setenv sage_ab_state trial-started; saveenv; run sage_boot1; run sage_boot0' ]
assert "no changing_bootcmd written" [ -z "$(env_get changing_bootcmd)" ]
# U-Boot runs the trial; the new pair comes up healthy.
sed -i.bak -e 's/^bootcmd=.*/bootcmd=run sage_stable0/' -e 's/^sage_ab_state=.*/sage_ab_state=trial-started/' "$S/env"
echo 'console=ttyMSM0 ubi.mtd=fs ubi.block=0,rootfs1 root=/dev/ubiblock0_3 rootfstype=squashfs fstools_overlay_name=rootfs_data1 cambium_sage_slot=1' > "$S/cmdline"
printf '%s\n' '/dev/ubiblock0_3 /rom squashfs ro 0 0' 'ubi0:rootfs_data1 /overlay ubifs rw 0 0' 'overlayfs:/overlay / overlay rw 0 0' > "$S/mounts"
healthy_sage; : > "$S/calls"
check "healthy Sage trial committed" 0 guard
assert "pair 1 confirmed and the default" [ "$(env_get sage_ab_confirmed):$(env_get sage_ab_state):$(env_get bootcmd)" = '1:confirmed:run sage_stable1' ]
check "mixed-layout slot 1 is the active pair" 0 in_lib eval 'ab_identity && [ "$AB_ACTIVE:$AB_TARGET" = 1:0 ]'
# An overlay that fell back to tmpfs must never be committed as healthy.
printf '%s\n' '/dev/ubiblock0_3 /rom squashfs ro 0 0' 'tmpfs /overlay tmpfs rw 0 0' 'overlayfs:/overlay / overlay rw 0 0' > "$S/mounts"
check "tmpfs overlay fails the Sage health guard" 1 in_lib eval 'ab_identity && ab_sage_root_healthy'
printf '%s\n' '/dev/ubiblock0_3 /rom squashfs ro 0 0' 'ubi0:rootfs_data1 /overlay ubifs rw 0 0' 'overlayfs:/overlay / overlay rw 0 0' > "$S/mounts"
# The following upgrade converts the remaining UBIFS pair; rollback is now
# SquashFS on slot 1, and neither overlay is shared between the pairs.
check "second upgrade converts pair 0" 0 dispatch40xx platform_do_upgrade "$S/sage.bin"
assert "pair 0 gets its own overlay" [ "$(cat "$S/sys/ubi/ubi0_6/name" "$S/sys/ubi/ubi0_6/reserved_ebs" | tr '\n' ':')" = 'rootfs_data0:67:' ]
assert "pair 1 overlay survives pair 0 conversion" [ "$(cat "$S/sys/ubi/ubi0_5/name")" = rootfs_data1 ]
assert "both pair boot commands now select their own overlays" sh -c "grep -q '^sage_boot0=.*fstools_overlay_name=rootfs_data0' '$S/env' && grep -q '^sage_boot1=.*fstools_overlay_name=rootfs_data1' '$S/env'"
new_sage_ap $E 0 adopted; dispatch40xx platform_do_upgrade "$S/sage.bin" >/dev/null 2>&1
sed -i.bak -e 's/^bootcmd=.*/bootcmd=run sage_stable0/' -e 's/^sage_ab_state=.*/sage_ab_state=trial-started/' "$S/env"
echo 'console=ttyMSM0 ubi.mtd=fs ubi.block=0,rootfs1 root=/dev/ubiblock0_3 rootfstype=squashfs fstools_overlay_name=rootfs_data1 cambium_sage_slot=1' > "$S/cmdline"
printf '%s\n' '/dev/ubiblock0_3 /rom squashfs ro 0 0' 'ubi0:rootfs_data1 /overlay ubifs rw 0 0' 'overlayfs:/overlay / overlay rw 0 0' > "$S/mounts"
touch "$S/net_ok"; : > "$S/calls"
check "Sage trial without its radios" 0 guard
assert "failed Sage trial rolled back to pair 0" [ "$(env_get sage_ab_state):$(env_get bootcmd)" = 'rolled-back:run sage_stable0' ]
assert "failed Sage trial reboots to pair 0" grep -q reboot "$S/calls"

# A Sage with the stock firmware still in its other pair: its first
# sysupgrade replaces it, as it always has, and records both pairs as OpenWrt.
new_sage_ap $E 1 stock
echo 'sage_oem_fallback=0' >> "$S/env"
check "first sysupgrade over the stock pair" 0 dispatch40xx platform_do_upgrade "$S/sage.bin"
assert "stock pair 0 replaced" cmp -s "$S/flash/mtd2/1.data" "$S/sage-root"
assert "replacing the OEM pair clears its fallback marker" [ -z "$(env_get sage_oem_fallback)" ]
assert "both pairs now OpenWrt: A/B recorded, pair 1 confirmed" [ "$(env_get sage_ab_version):$(env_get sage_ab_confirmed)" = '1:1' ]
assert "trial of pair 0 armed" [ "$(env_get bootcmd)" = \
	'setenv bootcmd run sage_stable1; setenv image 1; setenv sage_ab_state trial-started; saveenv; run sage_boot0; run sage_boot1' ]

# The OEM marker is retired before any write, including a write that fails.
new_sage_ap $E 1 stock
echo 'sage_oem_fallback=0' >> "$S/env"
sage_stock_boot=$(env_get bootcmd)
echo mtd2/1 > "$S/corrupt"
check "failed first Sage upgrade refuses damaged OEM pair" 1 dispatch40xx platform_do_upgrade "$S/sage.bin"
assert "failed first upgrade clears OEM fallback marker" [ -z "$(env_get sage_oem_fallback)" ]
assert "failed first upgrade keeps active pair as default" [ "$(env_get image):$(env_get bootcmd)" = "1:$sage_stock_boot" ]
# A recovery FIT shortens data_bytes but not the volume's reserved capacity.
new_sage_ap $E 0 adopted
echo 4 > "$S/sys/ubi/ubi0_3/data_bytes"
check "Sage target fits by reserved capacity after RAM staging" 0 dispatch40xx platform_check_image "$S/sage.bin"
# Refusals: wrong root type, too large, unqualified model, write failures.
new_sage_ap $E 0 adopted; : > "$S/calls"
check "a UBIFS root is refused on new Sage writer" 1 dispatch40xx platform_check_image "$S/sage-ubifs.bin"
echo 10 > "$S/flash/mtd2/2.size"; (. "$S/bin/_sim"; refresh ubi0 2)
check "a kernel larger than linux1 is refused" 1 dispatch40xx platform_check_image "$S/sage.bin"
assert "refusals wrote nothing" never_wrote 'update|setenv'
new_sage_ap cambiumnetworks,e600 0 adopted
check "E600 upgrade refused" 1 dispatch40xx platform_do_upgrade "$S/sage.bin"
new_sage_ap $E 0 adopted; echo mtd2/3 > "$S/corrupt"
check "a Sage readback mismatch fails" 1 dispatch40xx platform_do_upgrade "$S/sage.bin"
assert "readback failure: pair 0 stays the default" [ "$(env_get bootcmd):$(env_get sage_ab_state)" = 'run sage_stable0:write-failed' ]
assert "readback failure is recorded" [ -n "$(env_get sage_ab_last_failure)" ]

# Gambit keeps its kernels outside UBI. Exercise the real module through the
# same writer, platform dispatcher and health guard as the other families.
tool flash_erase <<'EOF'
#!/bin/sh
. "$(dirname "$0")/_sim"
fail_point flash_erase
: > "$1"
echo "erase ${1##*/}" >> "$S/calls"
EOF
tool nandwrite <<'EOF'
#!/bin/sh
. "$(dirname "$0")/_sim"
[ "$1" = -p ] && shift
fail_point nandwrite
cp "$2" "$1" || exit 1
echo "nandwrite ${1##*/}" >> "$S/calls"
EOF
tool nanddump <<'EOF'
#!/bin/sh
. "$(dirname "$0")/_sim"
out= length= dev=
while [ $# -gt 0 ]; do
	case "$1" in -f) out=$2; shift ;; -l) length=$2; shift ;; -*) ;; *) dev=$1 ;; esac
	shift
done
head -c "$length" "$dev" > "$out" || exit 1
[ ! -f "$S/corrupt-raw" ] || printf X | dd of="$out" bs=1 seek=64 conv=notrunc 2>/dev/null
echo "nanddump ${dev##*/}" >> "$S/calls"
EOF
new_gambit_ap() {
	local active=${1:-1} idx=$((2 * ${1:-1} + 1)) n
	new_ap cambiumnetworks,e400
	set_sku 006
	printf '%s\n' 'mtd0: 00400000 00020000 "linux0"' 'mtd1: 02c00000 00020000 "rootfs0"' \
		'mtd2: 00400000 00020000 "linux1"' 'mtd3: 02c00000 00020000 "rootfs1"' \
		'mtd4: 02000000 00020000 "nvram"' 'mtd5: 00040000 00010000 "u-boot"' \
		'mtd6: 00010000 00010000 "u-boot-env"' 'mtd7: 00790000 00010000 "CrashLog"' \
		'mtd8: 00010000 00010000 "mfginfo"' 'mtd9: 00010000 00010000 "ART"' > "$S/proc_mtd"
	for n in 0 1 2 3 4 5 6 7 8 9; do
		mkdir -p "$S/sys/mtd/mtd$n"
		echo 0x800 > "$S/sys/mtd/mtd$n/flags"
	done
	for n in 0 1 2 3 6; do echo 0xc00 > "$S/sys/mtd/mtd$n/flags"; done
	echo 328 > "$S/bank_lebs"
	rm -rf "$S/sys/ubi" "$S/flash"; mkdir -p "$S/sys/ubi/ubi0" "$S/flash"
	make_bank "$idx" unused hsqs-running-root
	echo "$idx" > "$S/sys/ubi/ubi0/mtd_num"
	(. "$S/bin/_sim"; refresh ubi0 "$idx")
	printf 'ubi.mtd=rootfs%s root=/dev/ubiblock0_1\n' "$active" > "$S/cmdline"
	printf '%s\n' '/dev/ubiblock0_1 /rom squashfs ro 0 0' \
		'ubi0:rootfs_data /overlay ubifs rw 0 0' 'overlayfs:/overlay / overlay rw 0 0' > "$S/mounts"
	printf 'bootcmd=nboot 0x81000000 0 0x%08x\ngambit_oem_slot=%s\n' $(((1 - active) * 0x3000000)) "$((1 - active))" > "$S/env"
	printf OEM-kernel0 > "$S/dev/mtd0"; printf OEM-rootfs0 > "$S/dev/mtd1"
	: > "$S/calls"
}
dispatch79() {
	(. "$S/system.sh"; . "$S/functions.sh"; . "$CAMBIUM_AB_UPGRADE_LIB"
	 nand_restore_config() { echo "restore-config $CI_UBIPART $1" >> "$S/calls"; }
	 . "$top/target/linux/ath79/nand/base-files/lib/upgrade/platform.sh"; "$@")
}

new_gambit_ap
check 'E400 4+44 MiB identity, bank 1 active' 0 in_lib eval 'ab_identity && [ "$AB_ACTIVE:$AB_TARGET:$AB_ACTIVE_MTD:$AB_TARGET_MTD" = 1:0:3:1 ]'
check 'E400 uses NOR environment by label' 0 in_lib eval 'unset AB_ENV_CONFIG; ab_board cambiumnetworks,e400; ab_env_config && grep -q "^/dev/mtd6 " "$AB_ENV_CONFIG"'
cmd=$(in_lib eval 'ab_board cambiumnetworks,e400; ab_guarded_command 1')
assert 'E400 restores OEM default before changing runtime bootargs' [ "$cmd" = 'setenv bootcmd nboot 0x81000000 0 0x00000000; saveenv; setenv bootargs console=ttyS0,115200n8 ubi.mtd=rootfs1 root=/dev/ubiblock0_1 rootfstype=squashfs init=/sbin/init panic=5 mem=128M; nboot 0x83000000 0 0x03000000' ]
check 'E400 first install refuses bank 0' 1 in_lib eval 'ab_board cambiumnetworks,e400; ab_guarded_command 0'
new_gambit_ap 0
cmd0=$(in_lib eval 'ab_board cambiumnetworks,e400; ab_guarded_command 0')
assert 'E400 inactive bank 0 restores OEM bank 1 before booting' [ "$cmd0" = 'setenv bootcmd nboot 0x81000000 0 0x03000000; saveenv; setenv bootargs console=ttyS0,115200n8 ubi.mtd=rootfs0 root=/dev/ubiblock0_1 rootfstype=squashfs init=/sbin/init panic=5 mem=128M; nboot 0x83000000 0 0x00000000' ]
healthy_sage
check 'E400 healthy inactive-bank-0 boot rearms shared guard' 0 guard
assert 'E400 shared guard preserves OEM bank 1 fallback' [ "$(env_get bootcmd)" = "$cmd0" ]
new_gambit_ap
sed -i.bak '/^gambit_oem_slot=/d' "$S/env"
check 'E400 missing OEM slot marker refuses guarded boot' 1 in_lib eval 'ab_board cambiumnetworks,e400; ab_guarded_command 1'
new_gambit_ap
echo 0xc00 > "$S/sys/mtd/mtd9/flags"
check 'E400 writable ART refused' 1 in_lib ab_identity
new_gambit_ap
echo 'ubi.mtd=rootfs0 ubi.mtd=rootfs1' > "$S/cmdline"
check 'E400 ambiguous slot refused' 1 in_lib ab_identity
new_gambit_ap
sed -i.bak 's/00400000/00300000/g' "$S/proc_mtd"
check 'E400 old 3 MiB geometry refused' 1 in_lib ab_identity
new_gambit_ap
echo 1 > "$S/sys/ubi/ubi0/mtd_num"
check 'E400 wrong UBI attachment refused' 1 in_lib ab_identity

# Minimal legacy uImage: the shared gate checks type and exact payload size.
dd if=/dev/zero of="$S/e400-kernel" bs=64 count=1 2>/dev/null
printf '\047\005\031\126' | dd of="$S/e400-kernel" conv=notrunc 2>/dev/null
printf '\000\000\000\003' | dd of="$S/e400-kernel" bs=1 seek=12 conv=notrunc 2>/dev/null
printf '\005\005\002\003' | dd of="$S/e400-kernel" bs=1 seek=28 conv=notrunc 2>/dev/null
printf new >> "$S/e400-kernel"
make_image "$S/e400.bin" "$S/e400-kernel" '' sysupgrade-cambiumnetworks_gambit-persistent
new_gambit_ap
check 'E400 sysupgrade cannot overwrite preserved OEM before conversion' 1 dispatch79 platform_check_image "$S/e400.bin"
healthy_sage
check 'E400 healthy legacy boot rearms shared guard' 0 guard
assert 'E400 guarded default selected' [ "$(env_get bootcmd)" = "$cmd" ]
assert 'E400 needs no changing_bootcmd marker' [ -z "$(env_get changing_bootcmd)" ]
assert 'E400 healthy boot clears the OEM boot counter' [ "$(env_get bootcount)" = 0 ]
assert 'E400 guard leaves both OEM partitions intact' [ "$(cat "$S/dev/mtd0")/$(cat "$S/dev/mtd1")" = OEM-kernel0/OEM-rootfs0 ]

new_gambit_ap
printf '%s\n' 'gambit_ab_version=1' 'gambit_ab_confirmed=1' 'gambit_ab_state=confirmed' >> "$S/env"
check 'E400 converted sysupgrade image accepted' 0 dispatch79 platform_check_image "$S/e400.bin"
check 'E400 bank 1 to 0 uses shared upgrade writer' 0 dispatch79 platform_do_upgrade "$S/e400.bin"
assert 'E400 raw target kernel written' cmp -s "$S/dev/mtd0" "$S/e400-kernel"
assert 'E400 target rootfs uses UBI volume ID 1' [ "$(cat "$S/flash/mtd1/1.name")" = rootfs ]
assert 'E400 target overlay uses UBI volume ID 2' [ "$(cat "$S/flash/mtd1/2.name")" = rootfs_data ]
assert 'E400 source kernel and root partition were not erased' never_wrote 'erase mtd2|format mtd3|nandwrite mtd2'
assert 'E400 shared trial restores confirmed bank first' [ "$(env_get bootcmd)" = 'setenv bootcmd run gambit_stable1; setenv image 1; setenv gambit_ab_state trial-started; saveenv; run gambit_boot0; run gambit_boot1' ]
assert 'E400 bank-specific boot command uses raw NAND offset' grep -q '^gambit_boot0=.*ubi.mtd=rootfs0.*nboot 0x83000000 0 0x00000000$' "$S/env"
check 'E400 refuses another upgrade before trial confirmation' 1 dispatch79 platform_check_image "$S/e400.bin"
# Simulate the trial's first durable U-Boot step and a healthy bank 0 boot.
sed -i.bak -e 's/^bootcmd=.*/bootcmd=run gambit_stable1/' -e 's/^gambit_ab_state=.*/gambit_ab_state=trial-started/' "$S/env"
echo 'ubi.mtd=rootfs0 root=/dev/ubiblock0_1' > "$S/cmdline"
echo 1 > "$S/sys/ubi/ubi0/mtd_num"
(. "$S/bin/_sim"; refresh ubi0 1)
healthy_sage
check 'E400 shared guard confirms a healthy trial' 0 guard
assert 'E400 trial bank 0 becomes the stable default' [ "$(env_get gambit_ab_confirmed):$(env_get bootcmd)" = '0:run gambit_stable0' ]

new_gambit_ap
printf '%s\n' 'gambit_ab_version=1' 'gambit_ab_confirmed=1' 'gambit_ab_state=trial-started' 'gambit_ab_target=0' >> "$S/env"
check 'E400 failed trial returns to the confirmed bank' 1 guard
assert 'E400 shared guard records rollback' [ "$(env_get gambit_ab_state)" = rolled-back ]

new_gambit_ap
printf '%s\n' 'gambit_ab_version=1' 'gambit_ab_confirmed=1' 'gambit_ab_state=confirmed' >> "$S/env"
touch "$S/corrupt-raw"
check 'E400 raw NAND readback corruption refuses the upgrade' 1 dispatch79 platform_do_upgrade "$S/e400.bin"
assert 'E400 raw mismatch never arms a trial or formats rootfs' never_wrote 'format|setenv bootcmd'
assert 'E400 raw mismatch records a write failure' [ "$(env_get gambit_ab_state)" = write-failed ]
rm -f "$S/corrupt-raw"

new_gambit_ap
printf '%s\n' 'gambit_ab_version=1' 'gambit_ab_confirmed=1' 'gambit_ab_state=confirmed' >> "$S/env"
echo 1 > "$S/fail_at"
check 'E400 failed environment write stops before flash writes' 1 dispatch79 platform_do_upgrade "$S/e400.bin"
assert 'E400 failed pre-write never erases kernel/root' never_wrote 'erase|format'
new_gambit_ap
check 'E400 oversized kernel refused' 1 in_lib eval 'ab_identity && ab_gambit_image_fits 4194304 1024'
check 'E400 oversized root leaves overlay intact' 1 in_lib eval 'ab_identity && ab_gambit_image_fits 1024 44000000'

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
