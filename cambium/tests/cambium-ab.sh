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
		echo "251:$v" > "$S/sys/ubi/$1_$v/dev"
		hotplug && ln -sf "$S/flash/mtd$2/$v.data" "$S/dev/$1_$v"
	done
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
for d in "$S"/sys/ubi/ubi[0-9]*; do
	case "${d##*/}" in *_*) continue ;; esac
	[ "$(cat "$d/mtd_num")" = "$2" ] || continue
	k=${d##*/}; rm -rf "$S/sys/ubi/$k" "$S/sys/ubi/$k"_*; rm -f "$S/dev/$k" "$S/dev/$k"_*
	echo "detach mtd$2" >> "$S/calls"; exit 0
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
tool ubiupdatevol <<'EOF'
#!/bin/sh
. "$(dirname "$0")/_sim"
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
[ "$dev" = br-lan ] || [ -d "$S/net/$dev" ] || exit 0
case "$*" in
*address*) echo '    inet 192.0.2.10/24 brd 192.0.2.255 scope global br-lan' ;;
*route*) echo 'default via 192.0.2.1 dev br-lan' ;;
esac
EOF
command -v sha256sum >/dev/null 2>&1 || tool sha256sum <<'EOF'
#!/bin/sh
exec shasum -a 256 "$@"
EOF
# uci: network.lan.device from $S/lan_device, when a test sets one.
tool uci <<'EOF'
#!/bin/sh
. "$(dirname "$0")/_sim"
[ "$*" = "-q get network.lan.device" ] && [ -f "$S/lan_device" ] || exit 1
cat "$S/lan_device"
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
export CAMBIUM_SAGE_LIB=$top/target/linux/ipq40xx/base-files/lib/functions/cambium-sage.sh
export AB_NEWROOT=$S/newroot
export CAMBIUM_AB_LIB=$ab_pkg/cambium-ab.sh CAMBIUM_AB_MODULES=$S/modules
export AB_SYS_NET=$S/net AB_SYS_IEEE80211=$S/ieee80211
export CAMBIUM_AB_UPGRADE_LIB=${CAMBIUM_AB_UPGRADE_LIB:-$ab_pkg/cambium-ab-upgrade.sh}
export CAMBIUM_FUNCTIONS=$S/functions.sh CAMBIUM_SYSTEM_FUNCTIONS=$S/system.sh
export CAMBIUM_BDF_FW_DIR=$S/fw CAMBIUM_BDF_WORK=$S/bdwork CAMBIUM_BDF_STATUS=$S/bdstatus
export AB_BOARD_DATA=$S/bin/board-data AB_WORK=$S/work
export AB_GUARD_TRIES=2 AB_GUARD_PAUSE=0

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
	cambiumnetworks,xv3-8) echo lib/firmware/IPQ8074/WIFI_FW/bdwlan.b215.accton:131072 ;;
	esac
}
set_sku() { printf "\\000\\000\\000\\$1" > "$S/dt/cambium-platform/board-sku"; }

# new_ap [BOARD] [ACTIVE-SLOT] [oem|openwrt]: the other bank's contents.
new_ap() {
	local board=${1:-cambiumnetworks,xv2-2t1} active=${2:-0} other=${3:-oem} i
	rm -rf "$S/sys" "$S/dev" "$S/flash" "$S/dt" "$S/fw" "$S/bdwork"* "$S/work" "$S/oem_root" "$S/net" "$S/ieee80211"
	rm -f "$S/calls" "$S/opcount" "$S/fail_at" "$S/corrupt" "$S/bank_lebs" "$S/bdstatus" "$S/net_ok" "$S/lan_device"
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
check "XE3-4 gets a manifest-only vault" 0 run_board_data
assert "XE3-4 never attaches the OEM slot" never_wrote 'attach|mount-oem'
check "XE3-4 vault is valid" 0 run_board_data --check-vault
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
assert "unhealthy trial rebooted" grep -q reboot "$S/calls"
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
new_ap $T; healthy_ap; mkdir -p "$S/ieee80211/phy0" "$S/ieee80211/phy1" "$S/ieee80211/phy2"; : > "$S/calls"
check "Thor legacy guard re-arms slot 0 (no image variable)" 0 guard
assert "Thor legacy one-shot is the module's guarded command" [ "$(env_get bootcmd)" = "$(in_lib eval "ab_board $T; ab_guarded_command 0")" ]
new_ap $T; healthy_ap; mkdir -p "$S/ieee80211/phy0" "$S/ieee80211/phy1"; : > "$S/calls"
check "Thor with two of its three radios is unhealthy" 0 guard
assert "Thor unhealthy start returns to the stock firmware" grep -q reboot "$S/calls"
# The guard checks the device the lan network is configured on: a missing
# VLAN bridge fails the check rather than passing on br-lan.
new_ap $T; healthy_ap; mkdir -p "$S/ieee80211/phy0" "$S/ieee80211/phy1" "$S/ieee80211/phy2"
echo br-lan.1 > "$S/lan_device"; : > "$S/calls"
check "configured br-lan.1 missing: unhealthy" 0 guard
assert "missing br-lan.1 returns to the stock firmware" grep -q reboot "$S/calls"
new_ap $T; healthy_ap; mkdir -p "$S/ieee80211/phy0" "$S/ieee80211/phy1" "$S/ieee80211/phy2" "$S/net/br-lan.1"
echo br-lan.1 > "$S/lan_device"; : > "$S/calls"
check "configured br-lan.1 present: healthy" 0 guard
assert "present br-lan.1 re-arms OpenWrt" never_wrote reboot
new_ap $T; healthy_ap; mkdir -p "$S/ieee80211/phy0" "$S/ieee80211/phy1" "$S/ieee80211/phy2" "$S/net/br-lan.1"
echo br-lan > "$S/lan_device"; : > "$S/calls"
check "a network left on br-lan is checked on br-lan" 0 guard
assert "br-lan configuration re-arms OpenWrt" never_wrote reboot
# A validated single-bank install: OpenWrt is the committed default.
new_ap $T; healthy_ap; mkdir -p "$S/ieee80211/phy0" "$S/ieee80211/phy1" "$S/ieee80211/phy2"
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
boot_slot 1; healthy_ap; mkdir -p "$S/ieee80211/phy0" "$S/ieee80211/phy1" "$S/ieee80211/phy2" "$S/net/br-lan.1"; : > "$S/calls"
check "Thor healthy trial committed" 0 guard
assert "Thor slot 1 confirmed" [ "$(env_get thor_ab_confirmed):$(env_get thor_ab_state):$(env_get bootcmd)" = '1:confirmed:run thor_stable1' ]
assert "status names the Thor family" sh -c "sh '$ab_pkg/cambium-ab-status' | grep -qx 'family=thor'"

# --- Sage (cambium-ab-sage.sh) --------------------------------------------------
# One UBI device on the SPI-NAND "fs" partition holds linux0/rootfs0,
# linux1/rootfs1 and nvram; each root is a writable UBIFS.
E=cambium,e410
sage0='setenv image 0; setenv bootargs "mtdparts=spi0.1:128M(fs) ubi.mtd=fs root=ubi0:rootfs0 rootfstype=ubifs rootwait"; nand device 1 && setenv mtdids nand1=nand1 && setenv mtdparts "mtdparts=nand1:0x8000000@0x0(fs)" && ubi part fs && ubi read 0x84000000 linux0 && bootm 0x84000000#config@ap.dk01.1-c2'
sage1='setenv image 1; setenv bootargs "mtdparts=spi0.1:128M(fs) ubi.mtd=fs root=ubi0:rootfs1 rootfstype=ubifs rootwait"; nand device 1 && setenv mtdids nand1=nand1 && setenv mtdparts "mtdparts=nand1:0x8000000@0x0(fs)" && ubi part fs && ubi read 0x84000000 linux1 && bootm 0x84000000#config@ap.dk01.1-c2'
# new_sage_ap [BOARD] [RUNNING-PAIR] [stock|upgraded|trial|adopted]
new_sage_ap() {
	local board=${1:-cambium,e410} active=${2:-0} kind=${3:-upgraded} other i v
	other=$((1 - active))
	rm -rf "$S/sys" "$S/dev" "$S/flash" "$S/dt" "$S/fw" "$S/work" "$S/net" "$S/ieee80211" "$S/newroot"
	rm -f "$S/calls" "$S/opcount" "$S/fail_at" "$S/corrupt" "$S/bdstatus" "$S/net_ok" "$S/lan_device"
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
	echo 2 > "$S/sys/ubi/ubi0/mtd_num"
	(. "$S/bin/_sim"; refresh ubi0 2)
	echo "console=ttyMSM0 root=ubi0:rootfs$active rootfstype=ubifs rootwait" > "$S/cmdline"
	echo "ubi0:rootfs$active / ubifs rw,noatime 0 0" > "$S/mounts"
	case "$kind" in
	stock)
		# Committed by sage-migration-mark-good: the stock firmware is the fallback.
		printf '%s\n' "bootcmd=setenv image $active; nand device 1 && bootm 0x84000000#config@ap.dk01.1-c2; setenv image $other; bootipq" \
			"image=$active" "owrt_migration_state=committed" > "$S/env" ;;
	upgraded)
		printf '%s\n' "owrt_boot0=$sage0" "owrt_boot1=$sage1" "bootcmd=run owrt_boot$active; run owrt_boot$other" \
			"image=$active" "e410_upgrade_state=committed" "e410_upgrade_target=$active" "e410_upgrade_fallback=$other" > "$S/env" ;;
	trial)
		# The earlier Sage code has trial-booted this pair: the old pair is
		# the default again and e410_upgrade_state is fallback-restored.
		printf '%s\n' "owrt_boot0=$sage0" "owrt_boot1=$sage1" "bootcmd=run owrt_boot$other; run owrt_boot$active" \
			"image=$other" "e410_upgrade_state=fallback-restored" "e410_upgrade_target=$active" "e410_upgrade_fallback=$other" > "$S/env" ;;
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
{ printf '\061\030\020\006'; printf 'new-ubifs-root'; } > "$S/sage-root"
make_fit config@5 config@ap.dk01.1-c2 config@16 config@17 > "$S/sage-fit"
make_image "$S/sage.bin" "$S/sage-fit" "$S/sage-root" sysupgrade-cambium_e410
cp "$S/sage.bin" "$S/sage-good.bin"
make_image "$S/sage-squashfs.bin" "$S/sage-fit" "" sysupgrade-cambium_e410
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

# First boot of the new image after the earlier Sage code upgraded to it.
new_sage_ap $E 1 trial; healthy_sage; : > "$S/calls"
check "takeover of an earlier Sage trial" 0 guard
assert "takeover: A/B state adopted with pair 1 confirmed" [ "$(env_get sage_ab_version):$(env_get sage_ab_confirmed):$(env_get sage_ab_state):$(env_get image)" = '1:1:confirmed:1' ]
assert "takeover: default boot is pair 1, then pair 0" [ "$(env_get bootcmd):$(env_get sage_stable1)" = 'run sage_stable1:run sage_boot1; run sage_boot0' ]
assert "takeover: boot commands are the validated ones" [ "$(env_get sage_boot0)" = "$sage0" -a "$(env_get sage_boot1)" = "$sage1" ]
assert "takeover: the earlier state is marked migrated" [ "$(env_get e410_upgrade_state)" = migrated ]
assert "takeover writes no changing_bootcmd (Sage U-Boot has none)" [ -z "$(env_get changing_bootcmd)" ]
new_sage_ap $E 1 trial; touch "$S/net_ok"; : > "$S/calls"
check "takeover: unhealthy trial (radios down)" 0 guard
assert "unhealthy takeover reboots to the old pair, still the default" grep -q reboot "$S/calls"
assert "unhealthy takeover leaves the earlier state for the old image" [ "$(env_get e410_upgrade_state):$(env_get bootcmd)" = 'fallback-restored:run owrt_boot0; run owrt_boot1' ]
assert "unhealthy takeover adopts nothing" [ -z "$(env_get sage_ab_version)" ]
new_sage_ap $E 0 upgraded; : > "$S/calls"
check "takeover of a committed earlier upgrade" 0 guard
assert "committed takeover: pair 0 is the default" [ "$(env_get sage_ab_confirmed):$(env_get bootcmd)" = '0:run sage_stable0' ]
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
assert "pair 1 UBIFS root written" cmp -s "$S/flash/mtd2/3.data" "$S/sage-root"
assert "running pair 0 untouched" [ "$(pair_data 0):$(pair_data 1)" = 'old-linux0:old-rootfs0' ]
assert "nvram untouched" [ "$(pair_data 4)" = old-nvram ]
assert "configuration carried into the new root" cmp -s "$S/newroot/sysupgrade.tgz" "$S/backup.tgz"
assert "trial of pair 1 armed, pair 0 restored first" [ "$(env_get bootcmd)" = \
	'setenv bootcmd run sage_stable0; setenv image 0; setenv sage_ab_state trial-started; saveenv; run sage_boot1; run sage_boot0' ]
assert "no changing_bootcmd written" [ -z "$(env_get changing_bootcmd)" ]
# U-Boot runs the trial; the new pair comes up healthy.
sed -i.bak -e 's/^bootcmd=.*/bootcmd=run sage_stable0/' -e 's/^sage_ab_state=.*/sage_ab_state=trial-started/' "$S/env"
echo 'console=ttyMSM0 root=ubi0:rootfs1 rootfstype=ubifs rootwait' > "$S/cmdline"
echo 'ubi0:rootfs1 / ubifs rw,noatime 0 0' > "$S/mounts"
healthy_sage; : > "$S/calls"
check "healthy Sage trial committed" 0 guard
assert "pair 1 confirmed and the default" [ "$(env_get sage_ab_confirmed):$(env_get sage_ab_state):$(env_get bootcmd)" = '1:confirmed:run sage_stable1' ]
new_sage_ap $E 0 adopted; dispatch40xx platform_do_upgrade "$S/sage.bin" >/dev/null 2>&1
sed -i.bak -e 's/^bootcmd=.*/bootcmd=run sage_stable0/' -e 's/^sage_ab_state=.*/sage_ab_state=trial-started/' "$S/env"
echo 'console=ttyMSM0 root=ubi0:rootfs1 rootfstype=ubifs rootwait' > "$S/cmdline"
echo 'ubi0:rootfs1 / ubifs rw,noatime 0 0' > "$S/mounts"
touch "$S/net_ok"; : > "$S/calls"
check "Sage trial without its radios" 0 guard
assert "failed Sage trial rolled back to pair 0" [ "$(env_get sage_ab_state):$(env_get bootcmd)" = 'rolled-back:run sage_stable0' ]
assert "failed Sage trial reboots to pair 0" grep -q reboot "$S/calls"

# A Sage with the stock firmware still in its other pair: its first
# sysupgrade replaces it, as it always has, and records both pairs as OpenWrt.
new_sage_ap $E 1 stock
check "first sysupgrade over the stock pair" 0 dispatch40xx platform_do_upgrade "$S/sage.bin"
assert "stock pair 0 replaced" cmp -s "$S/flash/mtd2/1.data" "$S/sage-root"
assert "both pairs now OpenWrt: A/B recorded, pair 1 confirmed" [ "$(env_get sage_ab_version):$(env_get sage_ab_confirmed)" = '1:1' ]
assert "trial of pair 0 armed" [ "$(env_get bootcmd)" = \
	'setenv bootcmd run sage_stable1; setenv image 1; setenv sage_ab_state trial-started; saveenv; run sage_boot0; run sage_boot1' ]

# Refusals: wrong root type, too large, unqualified model, write failures.
new_sage_ap $E 0 adopted; : > "$S/calls"
check "a SquashFS root is refused on Sage" 1 dispatch40xx platform_check_image "$S/sage-squashfs.bin"
echo 10 > "$S/flash/mtd2/2.size"; (. "$S/bin/_sim"; refresh ubi0 2)
check "a kernel larger than linux1 is refused" 1 dispatch40xx platform_check_image "$S/sage.bin"
assert "refusals wrote nothing" never_wrote 'update|setenv'
new_sage_ap cambiumnetworks,e600 0 adopted
check "E600 upgrade refused" 1 dispatch40xx platform_do_upgrade "$S/sage.bin"
new_sage_ap $E 0 adopted; echo mtd2/3 > "$S/corrupt"
check "a Sage readback mismatch fails" 1 dispatch40xx platform_do_upgrade "$S/sage.bin"
assert "readback failure: pair 0 stays the default" [ "$(env_get bootcmd):$(env_get sage_ab_state)" = 'run sage_stable0:write-failed' ]
assert "readback failure is recorded" [ -n "$(env_get sage_ab_last_failure)" ]

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
