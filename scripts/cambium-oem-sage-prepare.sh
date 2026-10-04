#!/bin/sh
# Controller-neutral OEM inspection and essential recovery capture only.
# No firmware/environment writer or boot selector is invoked here.
set -eu
umask 077

die() { echo "cambium-oem-sage-prepare: $*" >&2; exit 1; }
usage() { die 'usage: script check | backup NEW_PRIVATE_DIRECTORY | inspect-capture CAPTURE_ROOT'; }
[ "$#" -ge 1 ] || usage
mode=$1; shift
root=; live=1
case "$mode" in
check) [ "$#" = 0 ] || usage ;;
backup) [ "$#" = 1 ] || usage; destination=$1 ;;
inspect-capture)
	[ "$#" = 1 ] || usage
	root=$1; live=0
	[ -d "$root" ] || die 'capture root is missing'
	;;
*) usage ;;
esac
for tool in awk cat od tr sed wc; do
	command -v "$tool" >/dev/null 2>&1 || die "required reader $tool is missing"
done
read_value() { [ -r "$root$1" ] || die "missing evidence $1"; cat "$root$1"; }
number() { case "$1" in ''|*[!0-9]*) die "invalid numeric evidence: $1" ;; esac; }
partition() {
	# Match complete labels, reject duplicates; never assume MTD indices.
	result=$(awk -v label="\"$1\"" '$4 == label {print $1, $2, $3}' "$root/proc/mtd")
	[ "$(printf '%s\n' "$result" | wc -l | tr -d ' ')" = 1 ] && [ -n "$result" ] || die "missing/duplicate MTD label $1"
	printf '%s\n' "$result"
}
partition_index() { entry=$(partition "$1") || return 1; printf '%s\n' "$entry" | awk '{gsub(/mtd|:/, "", $1); print $1}'; }
partition_geometry() {
	actual=$(partition "$1" | awk '{print $2, $3}')
	[ "$actual" = "$2" ] || die "unexpected geometry for $1: $actual"
}
environment() {
	if [ "$live" = 1 ]; then fw_printenv -c "$config_file" -n "$1"
	else read_value "/environment/$1"; fi
}
[ ! -f "$root/etc/openwrt_release" ] || die 'OEM preparation refuses an OpenWrt installation'
[ -r "$root/proc/mtd" ] || die 'missing MTD table'
if [ "$live" = 1 ]; then
	[ "$(id -u)" = 0 ] || die 'OEM root access is required'
	command -v fw_printenv >/dev/null 2>&1 || die 'OEM fw_printenv is missing'
fi
partition_geometry fs '08000000 00020000'
for label in 0:APPSBLENV 0:ART mfginfo; do
	partition_geometry "$label" '00010000 00010000'
done
fs=$(partition_index fs)
env=$(partition_index 0:APPSBLENV)
art=$(partition_index 0:ART)
mfg=$(partition_index mfginfo)
# A stale fw_env.config can read the wrong bank of NOR. Validate before use.
config=; config_file=
for file in /etc/fw_env.config /tmp/fw_env.config; do
	[ -r "$root$file" ] || continue
	next=$(awk '!/^#/ && NF {sub(/[[:space:]]*#.*/, ""); if (NF) print $0}' "$root$file")
	[ -z "$config" ] || [ "$config" = "$next" ] || die 'competing OEM environment configurations'
	config=$next; config_file=$file
done
[ -n "$config" ] || die 'missing OEM fw_env.config; establish explicit reader configuration'
set -- $config
[ "$#" = 4 ] || [ "$#" = 5 ] || die 'unexpected fw_env.config fields'
[ "$1" = "/dev/mtd$env" ] || die 'fw_env.config does not target named APPSBLENV'
case "$2:$3:$4:${5:-1}" in
0x0:0x10000:0x10000:1|0x0:0x00010000:0x00010000:1|0x0000:0x10000:0x10000:1) ;;
*) die 'unqualified environment offset/geometry; capture exact OEM configuration' ;;
esac
mfgpath="$root/dev/mtd${mfg}ro"
[ -r "$mfgpath" ] || die 'manufacturing read-only device is unavailable'
if [ "$live" = 1 ]; then
	for idx in "$env" "$art" "$mfg"; do [ -c "/dev/mtd${idx}ro" ] || die "missing read-only MTD $idx"; done
fi
products=$(tr '\000' '\n' < "$mfgpath" | sed -n 's/.*\(PL-E410XXX[A-B]-[A-Z][A-Z]\).*/\1/p')
[ "$(printf '%s\n' "$products" | wc -l | tr -d ' ')" = 1 ] || die 'ambiguous manufacturing product'
case "$products" in
PL-E410XXXB-??) model=E410B; sku=00000015 ;;
PL-E410XXXA-??) model=E410; sku=0000000a ;;
*) die 'unsupported manufacturing product; exact E410/E410B identity required' ;;
esac
if [ "$mode" = backup ]; then
	directory=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
	[ -r "$directory/cambium-oem-models.tsv" ] || die 'missing production admission manifest'
	admission=$(awk -F '\t' -v sku="$sku" -v model="$model" '$1 == sku && $3 == model {print $9}' "$directory/cambium-oem-models.tsv")
	[ "$admission" = qualified ] || die "$model: production OEM migration is not qualified; no backup/staging changes permitted"
fi
dt="$root/sys/firmware/devicetree/base/cambium-platform/board-sku"
if [ -r "$dt" ]; then
	actual=$(od -An -tx1 "$dt" | tr -d ' \n')
	[ "$actual" = "$sku" ] || die 'manufacturing identity and running board SKU disagree'
fi
cmdline=$(read_value /proc/cmdline)
running=; ubiarg=
for arg in $cmdline; do
	case "$arg" in
	root=*) [ -z "$running" ] || die 'duplicate root arguments'; running=${arg#root=} ;;
	ubi.mtd=*) [ -z "$ubiarg" ] || die 'duplicate ubi.mtd arguments'; ubiarg=${arg#ubi.mtd=} ;;
	esac
done
case "$running" in ubi0:rootfs0) active=0 ;; ubi0:rootfs1) active=1 ;; *) die 'unsupported OEM running root; expected ubi0:rootfs0/1' ;; esac
[ "$ubiarg" = fs ] || die 'running UBI attachment is not the named fs partition'
[ "$(read_value /sys/class/ubi/ubi0/mtd_num)" = "$fs" ] || die 'running UBI MTD and partition map disagree'
[ "$(read_value /sys/class/ubi/ubi0/eraseblock_size)" = 126976 ] || die 'unexpected UBI logical eraseblock size'
[ "$(read_value /sys/class/ubi/ubi0/min_io_size)" = 2048 ] || die 'unexpected UBI minimum I/O size'
# Reject multiple attachments of fs as ambiguous rather than choosing one.
for node in "$root"/sys/class/ubi/ubi[0-9]*/mtd_num; do
	[ -r "$node" ] || continue
	[ "$node" = "$root/sys/class/ubi/ubi0/mtd_num" ] && continue
	[ "$(cat "$node")" != "$fs" ] || die 'multiple UBI attachments to fs'
done
for pair in '0 linux0' '1 rootfs0' '2 linux1' '3 rootfs1'; do
	set -- $pair; id=$1; name=$2
	base="/sys/class/ubi/ubi0_$id"
	[ "$(read_value "$base/name")" = "$name" ] || die "unexpected volume ID $id"
	[ "$(read_value "$base/usable_eb_size")" = 126976 ] || die "unexpected usable eraseblock size in $name"
	lebs=$(read_value "$base/reserved_ebs"); number "$lebs"
	case "$name:$lebs" in linux?:34|rootfs?:372|rootfs?:305) ;; *) die "unqualified capacity $name:$lebs" ;; esac
	if [ "$live" = 1 ]; then [ -c "/dev/ubi0_$id" ] || die "missing volume device $id"; fi
done
image=$(environment image) || die 'cannot read selected OEM image with explicit -c configuration; qualify OEM reader'
[ "$image" = "$active" ] || die 'running root and selected OEM image disagree'
bootcmd=$(environment bootcmd) || die 'cannot read OEM bootcmd'
[ "$bootcmd" = bootipq ] || die 'nonstandard/trial bootcmd; resolve boot state before migration'
candidate=$((1 - active))
rootlebs=$(read_value "/sys/class/ubi/ubi0_$((candidate * 2 + 1))/reserved_ebs")
printf 'evidence=%s\nmodel=%s\nproduct=%s\nrunning_bank=%s\ninactive_bank=%s\nkernel_capacity=4317184\nroot_capacity=%s\n' \
	"$(if [ "$live" = 1 ]; then echo live; else echo offline; fi)" "$model" "$products" "$active" "$candidate" "$((rootlebs * 126976))"
printf 'write_enabled=no\nqualification=layout-only\n'
printf 'remaining=OEM release/updater qualification, authenticated image, boot guard/watchdog, recovery access\n'
for tool in fw_setenv ubiupdatevol sha256sum openssl; do
	if command -v "$tool" >/dev/null 2>&1; then printf 'tool_%s=present-unqualified\n' "$tool"
	else printf 'tool_%s=missing\n' "$tool"; fi
done
[ "$mode" = backup ] || exit 0
# Critical-only capture. No firmware, bootloader, whole NVRAM or crash dump.
for tool in dd sha256sum df mkdir cp sync dirname; do
	command -v "$tool" >/dev/null 2>&1 || die "backup reader $tool is missing"
done
for idx in "$env" "$art" "$mfg"; do [ -c "/dev/mtd${idx}ro" ] || die "missing read-only MTD $idx"; done
[ ! -e "$destination" ] && [ ! -L "$destination" ] || die 'backup destination already exists'
parent=$(dirname "$destination")
[ -d "$parent" ] || die 'backup parent directory is missing'
space=$(df -Pk "$parent" | awk 'END {print $4}'); number "$space"
[ "$space" -ge 1024 ] || die 'at least 1 MiB free space is required for critical capture'
mkdir -m 0700 "$destination"
# Leave incomplete capture for diagnosis; never emit complete marker on failure.
for entry in "$env appsblenv" "$art art" "$mfg manufacturing"; do
	set -- $entry
	dd if="/dev/mtd${1}ro" of="$destination/$2.bin" bs=65536 count=1
	[ "$(wc -c < "$destination/$2.bin" | tr -d ' ')" = 65536 ] || die "short critical-data read $2"
done
cp /proc/mtd "$destination/proc-mtd.txt"
cp /proc/cmdline "$destination/proc-cmdline.txt"
cp "$config_file" "$destination/fw_env.config"
if [ -r "$dt" ]; then cp "$dt" "$destination/board-sku.bin"; fi
fw_printenv -c "$config_file" > "$destination/environment.txt"
printf 'schema=1\nmodel=%s\nproduct=%s\npreserved_oem_bank=%s\ninactive_bank=%s\n' "$model" "$products" "$active" "$candidate" > "$destination/recovery.txt"
for entry in "$env appsblenv" "$art art" "$mfg manufacturing"; do
	set -- $entry
	case "$2" in appsblenv) label=0:APPSBLENV ;; art) label=0:ART ;; manufacturing) label=mfginfo ;; esac
	printf 'asset=%s.bin capture_source=/dev/mtd%sro label=%s size=65536\n' "$2" "$1" "$label" >> "$destination/recovery.txt"
done
(cd "$destination" && sha256sum *.bin *.txt fw_env.config > SHA256SUMS && sha256sum -c SHA256SUMS)
# Detect boot-state changes during capture before declaring complete.
[ "$(environment image)" = "$active" ] && [ "$(environment bootcmd)" = "$bootcmd" ] || die 'boot state changed during capture'
sync
printf 'critical capture complete; copy privately off-device and verify SHA256SUMS before any installation\n' > "$destination/CAPTURE_COMPLETE"
echo "Critical recovery capture: $destination (not authorization to write flash)."
