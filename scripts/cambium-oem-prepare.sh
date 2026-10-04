#!/bin/sh
# Shared read-only dispatcher. Successful checks establish captured layout only.
set -eu
die() { echo "cambium-oem-prepare: $*" >&2; exit 1; }
[ "$#" -ge 1 ] || die 'usage: script check | inspect-capture ROOT | backup NEW_PRIVATE_DIRECTORY'
mode=$1; shift
root=; live=1
case "$mode" in
check) [ "$#" = 0 ] || die 'check takes no arguments' ;;
inspect-capture) [ "$#" = 1 ] || die 'capture root required'; root=$1; live=0 ;;
backup) [ "$#" = 1 ] || die 'private destination required' ;;
*) die 'unsupported operation; this preparation tool cannot install or boot firmware' ;;
esac
directory=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
dt="$root/sys/firmware/devicetree/base/cambium-platform/board-sku"
if [ ! -r "$dt" ]; then
	# Sage legacy captures may identify hardware only through mfginfo.
	exec sh "$directory/cambium-oem-sage-prepare.sh" "$mode" "$@"
fi
sku=$(od -An -tx1 "$dt" | tr -d ' \n')
[ -r "$directory/cambium-oem-models.tsv" ] || die 'missing schema1 model manifest'
entry=$(awk -F '\t' -v sku="$sku" '$1 == sku {print}' "$directory/cambium-oem-models.tsv")
[ -n "$entry" ] || die "unknown unsupported SKU $sku; no family inference permitted"
[ "$(printf '%s\n' "$entry" | wc -l | tr -d ' ')" = 1 ] || die 'duplicate manifest SKU'
IFS="$(printf '\t')" read -r manifest_sku family model layout size compatible assets status production <<EOF
$entry
EOF
[ "$production" != unsupported ] || die "$model: known model is currently unsupported for production OEM migration; no changes permitted"
if [ "$mode" = backup ]; then
	[ "$production" = qualified ] || die "$model: production OEM migration is not qualified; no backup/staging changes permitted"
fi
case "$family:$sku" in
sage:0000000a|sage:00000015) exec sh "$directory/cambium-oem-sage-prepare.sh" "$mode" "$@" ;;
esac
case "$family" in
sage) die "$model: exact OEM layout/tool/root identity capture required; E410 geometry is not inherited" ;;
esac
[ "$size" != - ] || die "$model: profile exists but OEM bank geometry/radio assets/guard are not qualified"
[ "$mode" != backup ] || die "$model: critical capture adapter not qualified; collect exact private named assets from family recovery manifest"
[ ! -f "$root/etc/openwrt_release" ] || die 'OEM preflight refuses already-converted OpenWrt'
read_value() { [ -r "$root$1" ] || die "missing evidence $1"; cat "$root$1"; }
partition() {
	value=$(awk -v label="\"$1\"" '$4 == label {print $1, $2, $3}' "$root/proc/mtd")
	[ -n "$value" ] && [ "$(printf '%s\n' "$value" | wc -l | tr -d ' ')" = 1 ] || die "missing/duplicate partition $1"
	printf '%s\n' "$value"
}
index() { entry=$(partition "$1") || return 1; printf '%s\n' "$entry" | awk '{gsub(/mtd|:/, "", $1); print $1}'; }
geometry() { [ "$(partition "$1" | awk '{print $2, $3}')" = "$2" ] || die "unexpected OEM geometry $1"; }
envname=0:APPSBLENV
[ "$family" != gambit ] || envname=u-boot-env
env=$(index "$envname")
# OEMs can generate /tmp/fw_env.config. Reject ambiguous competing configs.
config=; config_file=
for file in /etc/fw_env.config /tmp/fw_env.config; do
	[ -r "$root$file" ] || continue
	next=$(awk '!/^#/ && NF {sub(/[[:space:]]*#.*/, ""); if (NF) print $0}' "$root$file")
	[ -z "$config" ] || [ "$config" = "$next" ] || die 'competing OEM environment configurations'
	config=$next; config_file=$file
done
[ -n "$config" ] || die 'OEM environment reader location unverified; capture tool access without guessing offsets'
set -- $config
[ "$#" = 4 ] || [ "$#" = 5 ] || die 'unexpected environment configuration'
[ "$1" = "/dev/mtd$env" ] || die 'environment config disagrees with named partition'
case "$2:$3:$4:${5:-1}" in
0x0:0x10000:0x10000:1|0x0:0x00010000:0x00010000:1) ;;
*) die 'unqualified environment configuration geometry' ;;
esac
environment() {
	if [ "$live" = 1 ]; then fw_printenv -c "$config_file" -n "$1"
	else read_value "/environment/$1"; fi
}
if [ "$live" = 1 ]; then
	[ "$(id -u)" = 0 ] || die 'OEM root access required'
	command -v fw_printenv >/dev/null 2>&1 || die 'fw_printenv missing'
fi
cmdline=$(read_value /proc/cmdline)
bootcmd=$(environment bootcmd) || die 'OEM boot command unreadable'
if [ "$family" = gambit ]; then
	# OEM YAFFS 3+45 MiB differs from converted OpenWrt 4+44 MiB.
	for slot in 0 1; do
		geometry "linux$slot" '00300000 00020000'
		geometry "rootfs$slot" '02d00000 00020000'
	done
	rootarg=
	for arg in $cmdline; do
		case "$arg" in root=*) [ -z "$rootarg" ] || die 'duplicate root arguments'; rootarg=${arg#root=} ;; esac
	done
	case "$rootarg" in
	"/dev/mtdblock$(index rootfs0)") active=0 ;;
	"/dev/mtdblock$(index rootfs1)") active=1 ;;
	*) die 'OEM YAFFS running bank unresolved' ;;
	esac
	[ "$bootcmd" = 'nboot 0x81000000 0 ${load_addr}' ] || die 'unqualified OEM nboot command'
	load=$(environment load_addr) || die 'load_addr missing'
	case "$active:$load" in 0:0x00000000|0:0x0|1:0x03000000) ;; *) die 'OEM kernel/root banks disagree' ;; esac
	geometry ART '00010000 00010000'
	geometry mfginfo '00010000 00010000'
	remaining='raw NAND/OOB updater, 3+45 to4+44MiB geometry, MRAM purpose, boot guard/watchdog/recovery'
else
	geometry rootfs "$size 00020000"
	geometry rootfs_1 "$size 00020000"
	part=; rootarg=
	for arg in $cmdline; do
		case "$arg" in
		ubi.mtd=*) [ -z "$part" ] || die 'duplicate ubi.mtd'; part=${arg#ubi.mtd=} ;;
		root=*) [ -z "$rootarg" ] || die 'duplicate root'; rootarg=${arg#root=} ;;
		esac
	done
	case "$part" in rootfs) active=0 ;; rootfs_1) active=1 ;; *) die 'OEM bank name unresolved' ;; esac
	case "$rootarg" in mtd:ubi_rootfs|ubi0:ubi_rootfs|/dev/ubiblock0_1) ;; *) die 'unqualified OEM root source' ;; esac
	[ "$(read_value /sys/class/ubi/ubi0/mtd_num)" = "$(index "$part")" ] || die 'running UBI attachment and bank disagree'
	[ "$(read_value /sys/class/ubi/ubi0/eraseblock_size)" = 126976 ] || die 'unexpected UBI LEB'
	[ "$(read_value /sys/class/ubi/ubi0/min_io_size)" = 2048 ] || die 'unexpected UBI minimum I/O'
	for pair in '0 kernel' '1 ubi_rootfs'; do
		set -- $pair
		[ "$(read_value "/sys/class/ubi/ubi0_$1/name")" = "$2" ] || die 'OEM UBI volume identity mismatch'
	done
	[ "$(environment image)" = "$active" ] || die 'selected/running bank disagreement'
	case "$family:$bootcmd" in thor:'aq_load_fw&&bootipq'|jaguar:bootipq|cheetah:bootipq) ;; *) die 'nonstandard/trial OEM boot command' ;; esac
	# Do not modify changing_bootcmd, attach inactive UBI or inspect it by mounting.
	remaining='exact OEM offsets/protected assets, inactive UBI inventory, updater/authentication, boot guard/watchdog/recovery'
fi
printf 'evidence=%s\nfamily=%s\nmodel=%s\nsku_hex=%s\nrunning_bank=%s\ninactive_bank=%s\nwrite_enabled=no\nqualification=layout-only\nremaining=%s\n' \
	"$(if [ "$live" = 1 ]; then echo live; else echo offline; fi)" "$family" "$model" "$sku" "$active" "$((1 - active))" "$remaining"
