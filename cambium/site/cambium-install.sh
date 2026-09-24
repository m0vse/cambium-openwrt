#!/bin/sh
# cambium-install.sh: RAM-boot or install Cambium OpenWrt from the access
# point's stock firmware root shell, for every built family (Sage, Thor,
# Jaguar, Cheetah). It encodes the procedures on
# https://m0vse.github.io/cambium-openwrt/#install.
#
#   sh cambium-install.sh [options] ram       RAM-boot the recovery image
#   sh cambium-install.sh [options] install   install the persistent image
#   sh cambium-install.sh [options] boot      Thor: trial boot the installed image
#   sh cambium-install.sh [options] commit    Thor: keep the installed image
#
# Options:
#   --from SRC      where the release files come from: a directory holding
#                   them, an http(s) URL of such a directory, or tftp:SERVER
#   --release TAG   download from the GitHub release TAG (needs https wget)
#   --tftp SERVER   TFTP server: Sage RAM boot (U-Boot loads the image from
#                   it) and, if it accepts uploads, the backups
#   --ap-ip IP      the access point's address for the Sage TFTP boot
#   --backed-up     you have copied the backups off the access point
#   --trial         hardware trial of a persistent image that is not yet
#                   validated on this model (only on a unit you can recover)
#   --persistent-test  Jaguar: RAM-boot the A/B persistent trees instead
#                   (test-only image), with no firmware bank attached
#   --no-reboot     arm everything but do not reboot
#   --yes           make the changes; without it only checks and backs up
#
# Nothing is written until every check has passed and --yes is given. Each
# step that writes stops at the first error and names the command, its exit
# status and its error; the full log is /tmp/cambium-install/install.log.

VERSION=1
R=${CAMBIUM_ROOT:-}
WORK=$R/tmp/cambium-install
LOG=$WORK/install.log
GITHUB=https://github.com/m0vse/cambium-openwrt/releases/download

cmd= src= tftp= ap_ip= backed_up= trial= yes= reboot=1 ptest=
while [ $# -gt 0 ]; do
	case "$1" in
	ram|install|boot|commit) cmd=$1 ;;
	--from) src=${2:-}; shift ;;
	--release) src=$GITHUB/${2:-}; shift ;;
	--tftp) tftp=${2:-}; shift ;;
	--ap-ip) ap_ip=${2:-}; shift ;;
	--backed-up) backed_up=1 ;;
	--trial) trial=1 ;;
	--persistent-test) ptest=1 ;;
	--no-reboot) reboot= ;;
	--yes) yes=1 ;;
	-h|--help) sed -n '2,31p' "$0"; exit 0 ;;
	*) echo "cambium-install: unknown argument '$1' (see --help)" >&2; exit 2 ;;
	esac
	shift
done
[ -n "$cmd" ] || { sed -n '2,31p' "$0"; exit 2; }
[ -z "$src" ] && [ -n "$tftp" ] && src=tftp:$tftp

mkdir -p "$WORK" || { echo "cambium-install: cannot create $WORK" >&2; exit 1; }
echo "=== cambium-install $VERSION $cmd $(date)" >> "$LOG"

# Messages go to stderr, so $(...) captures only results.
say() { echo "cambium-install: $*" >&2; echo "$*" >> "$LOG"; }
die() {
	echo "cambium-install: FAILED: $*" >&2
	echo "FAILED: $*" >> "$LOG"
	echo "cambium-install: nothing after this point was done; log: $LOG" >&2
	exit 1
}
# step DESCRIPTION COMMAND...: run one command; on failure stop, naming the
# step, its exit status and the command's last error line.
step() {
	local desc=$1 rc err
	shift
	echo "+ $*" >> "$LOG"
	"$@" >> "$LOG" 2> "$WORK/err"; rc=$?
	cat "$WORK/err" >> "$LOG"
	[ "$rc" = 0 ] && return 0
	err=$(grep . "$WORK/err" | tail -n 1)
	die "$desc (exit $rc${err:+: $err})"
}
have() { command -v "$1" >/dev/null 2>&1; }
need() {
	local t
	for t; do have "$t" || die "this firmware has no '$t' command, which this step needs"; done
}

# --- the running system ------------------------------------------------------

on_openwrt() { [ -f "$R/etc/openwrt_release" ]; }
mtd_idx() { sed -n "s/^mtd\([0-9]*\): [0-9a-f]* [0-9a-f]* \"$1\"\$/\1/p" "$R/proc/mtd"; }
mtd_size() { sed -n "s/^mtd[0-9]*: \([0-9a-f]*\) [0-9a-f]* \"$1\"\$/\1/p" "$R/proc/mtd"; }
ubi_of_mtd() { grep -lx "$1" "$R"/sys/class/ubi/ubi*/mtd_num 2>/dev/null | sed -n 's|.*/\(ubi[0-9]*\)/mtd_num$|\1|p' | head -n 1; }
vol_of() { grep -lx "$2" "$R"/sys/class/ubi/"$1"_*/name 2>/dev/null | sed -n 's|.*/\(ubi[0-9]*_[0-9]*\)/name$|\1|p' | head -n 1; }
getenv() { fw_printenv -n "$1" 2>/dev/null; }

# setenv_checked NAME VALUE: write one U-Boot variable and read it back.
setenv_checked() {
	step "fw_setenv $1" fw_setenv "$1" "$2"
	[ "$(getenv "$1")" = "$2" ] || die "U-Boot variable $1 did not read back after writing it"
}

# --- release files -------------------------------------------------------------

# fetch NAME: copy NAME from the source into $WORK.
fetch() {
	local name=$1 out=$WORK/$1 rc
	[ -n "$src" ] || die "no source for the release files: use --from DIR|URL|tftp:SERVER or --release TAG"
	rm -f "$out" "$out.part"
	case "$src" in
	http://*|https://*)
		need wget
		wget -q -O "$out.part" "${src%/}/$name" 2> "$WORK/err"; rc=$?
		[ "$rc" = 0 ] || {
			rm -f "$out.part"
			case "$src" in https://*)
				die "cannot download ${src%/}/$name (wget exit $rc: $(grep . "$WORK/err" | tail -n 1)). If this firmware's wget has no https, serve the release files over http from your computer (python3 -m http.server 8000) and use --from http://COMPUTER_IP:8000" ;;
			esac
			die "cannot download ${src%/}/$name (wget exit $rc: $(grep . "$WORK/err" | tail -n 1))"
		} ;;
	tftp:*)
		need tftp
		tftp -b 8192 -g -l "$out.part" -r "$name" "${src#tftp:}" 2> "$WORK/err" ||
			{ rm -f "$out.part"; die "cannot fetch $name from TFTP server ${src#tftp:}: $(grep . "$WORK/err" | tail -n 1)"; } ;;
	*)
		[ -f "$src/$name" ] || die "$src/$name does not exist"
		cp "$src/$name" "$out.part" || die "cannot copy $src/$name to $WORK (out of space?)" ;;
	esac
	mv "$out.part" "$out"
}

sums() { cat "$WORK"/SHA256SUMS "$WORK"/test-only-SHA256SUMS 2>/dev/null; }
# asset SUFFIX: the release file name ending in SUFFIX.
asset() {
	sums | awk -v s="$1" '{ n = $2; sub(/^\*/, "", n); if (length(n) >= length(s) && substr(n, length(n) - length(s) + 1) == s) print n }' | head -n 1
}
# get_image SUFFIX: fetch and verify the image; prints its path.
get_image() {
	local name want got
	name=$(asset "$1")
	[ -n "$name" ] || die "the release checksums list no file ending in $1: wrong release or source?"
	want=$(sums | awk -v n="$name" '{ f = $2; sub(/^\*/, "", f); if (f == n) print $1 }' | head -n 1)
	say "fetching $name"
	fetch "$name"
	got=$(sha256sum "$WORK/$name" | cut -d' ' -f1)
	[ "$got" = "$want" ] || die "$name has SHA-256 $got but the release lists $want: download again"
	echo "$WORK/$name"
}

load_release() {
	need sha256sum
	say "fetching the release checksums and select-config.sh from $src"
	fetch SHA256SUMS
	[ -n "$ptest" ] && fetch test-only-SHA256SUMS
	fetch select-config.sh
}

# identify FLAVOUR: FAMILY, MODEL, SKU, CONFIG, STATUS for this access point.
identify() {
	local out
	out=$(CAMBIUM_HARDWARE_TRIAL=${trial:-} sh "$WORK/select-config.sh" "$1" 2> "$WORK/sel.err") ||
		die "$(tr '\n' ' ' < "$WORK/sel.err")"
	[ -s "$WORK/sel.err" ] && sed 's/^/cambium-install: /' "$WORK/sel.err" >&2
	FAMILY= MODEL= SKU= CONFIG= STATUS=
	eval "$out"
	[ -n "$CONFIG" ] || die "select-config.sh gave no configuration"
	say "$MODEL (SKU $SKU, $FAMILY): $1 configuration $CONFIG ($STATUS)"
}

# --- layout checks -----------------------------------------------------------------

# Firmware slots: R0/R1 (rootfs, rootfs_1 MTD numbers), S0/S1 sizes, RUN the
# MTD the stock firmware runs from, BANK the bank size as U-Boot writes it.
slots() {
	R0=$(mtd_idx rootfs); R1=$(mtd_idx rootfs_1)
	S0=$(mtd_size rootfs); S1=$(mtd_size rootfs_1)
	[ -n "$R0" ] && [ -n "$R1" ] || die "no \"rootfs\" and \"rootfs_1\" partitions in /proc/mtd: not a supported layout (run cambium-report.sh and open an issue)"
	RUN=$(cat "$R/sys/class/ubi/ubi0/mtd_num" 2>/dev/null)
	[ -n "$RUN" ] || die "cannot tell which slot the stock firmware runs from (no /sys/class/ubi/ubi0)"
	[ "$RUN" = "$R0" ] || [ "$RUN" = "$R1" ] || die "the stock firmware runs from mtd$RUN, which is neither rootfs nor rootfs_1"
	BANK=$(printf '0x%x' "0x$S0")
	say "slots: rootfs=mtd$R0 ($S0), rootfs_1=mtd$R1 ($S1); stock firmware on mtd$RUN"
}
require_stock_on_rootfs_1() {
	[ "$RUN" = "$R1" ] || die "the stock firmware runs from rootfs, but OpenWrt must go into rootfs: upgrade the stock firmware once more (it then runs from rootfs_1) and run this again"
}

layout_jaguar() {
	slots
	case "$MODEL:$S0:$S1" in
	XV2-2:03400000:03400000|XV2-2T0:06000000:06000000|XV2-2T1:06000000:06000000|\
	XE3-4:06000000:06000000|XE3-4TN:06000000:06000000) ;;
	*) die "$MODEL with rootfs $S0 and rootfs_1 $S1 bytes (hex) is not a known Jaguar layout (XV2-2: 03400000; others: 06000000). Run cambium-report.sh and open an issue" ;;
	esac
}
layout_thor() {
	slots
	[ "$S0" = 06000000 ] || die "$MODEL rootfs is $S0 bytes (hex), not 06000000: this layout has not been captured. Run cambium-report.sh and open an issue"
	require_stock_on_rootfs_1
}
layout_cheetah() {
	local off
	slots
	[ "$S0" = 06000000 ] || die "$MODEL rootfs is $S0 bytes (hex), not 06000000: not the captured Cheetah layout. Run cambium-report.sh and open an issue"
	off=$(cat "$R/sys/class/mtd/mtd$R0/offset" 2>/dev/null)
	[ -z "$off" ] || [ "$off" = 524288 ] || die "$MODEL rootfs starts at NAND offset $off, not 0x80000: not the captured Cheetah layout"
	require_stock_on_rootfs_1
}
# Sage: one UBI device with linux0/rootfs0 and linux1/rootfs1; I is the
# running (stock) pair, T the other one.
layout_sage() {
	local v
	I=$(sed -n 's/.*root=ubi0:rootfs\([01]\).*/\1/p' "$R/proc/cmdline")
	[ -n "$I" ] || die "cannot tell the running Sage slot: /proc/cmdline has no root=ubi0:rootfs0/1"
	[ "$(getenv image)" = "$I" ] || die "U-Boot image=$(getenv image) but the stock firmware runs from rootfs$I"
	T=$((1 - I))
	for v in linux0 rootfs0 linux1 rootfs1; do
		[ -n "$(vol_of ubi0 "$v")" ] || die "no UBI volume $v on ubi0: not the captured Sage layout"
	done
	say "Sage slots: stock firmware on pair $I, OpenWrt goes into pair $T"
}

check_stock_bootcmd() {
	local cur want=bootipq
	[ "$FAMILY" = thor ] && want='aq_load_fw&&bootipq'
	need fw_printenv fw_setenv
	cur=$(getenv bootcmd) || die "cannot read the U-Boot environment (fw_printenv failed)"
	[ "$cur" = "$want" ] || die "bootcmd is '$cur', not the stock '$want': a one-shot or install is already armed. Reboot once (a one-shot restores itself) and run this again"
}

# --- backups -------------------------------------------------------------------------

# backup NAME SOURCE...: raw copies of what this run may write, plus the
# U-Boot environment and ART, into $WORK/backup.
backup() {
	local b=$WORK/backup f n i
	if [ -n "$backed_up" ]; then
		say "--backed-up: you have copied the backups off the access point"
		return 0
	fi
	mkdir -p "$b"
	for f in "$@"; do
		n=${f##*/}
		[ -s "$b/$n.bin" ] && continue
		say "backing up $f"
		step "back up $f" dd if="$f" of="$b/$n.bin" bs=131072
	done
	for n in 0:APPSBLENV 0:ART; do
		i=$(mtd_idx "$n")
		[ -n "$i" ] || die "no $n partition in /proc/mtd to back up"
		[ -s "$b/${n#0:}.bin" ] || step "back up $n" dd if="$R/dev/mtd${i}ro" of="$b/${n#0:}.bin"
	done
	(cd "$b" && sha256sum *.bin > SHA256SUMS) || die "cannot hash the backups (out of space in /tmp?)"
	if [ -n "$tftp" ]; then
		for f in "$b"/*; do
			step "upload ${f##*/} to TFTP server $tftp (it must accept uploads)" \
				tftp -b 8192 -p -l "$f" -r "cambium-backup-sku$SKU-${f##*/}" "$tftp"
		done
		say "backups uploaded to $tftp as cambium-backup-sku$SKU-*; check them against SHA256SUMS"
		return 0
	fi
	say "backups are in $b; copy them off the access point, e.g. from your computer:"
	say "  scp -O 'root@AP_IP:$b/*' ."
	[ -n "$yes" ] && die "copy the backups off the access point first, then run this again with --backed-up (or give --tftp SERVER to upload them)"
}

# --- staging a RAM image in the inactive firmware slot -----------------------------

# attach MTD: attach it to UBI unless it is already, the way this family's
# stock firmware was validated (Jaguar: ubiattach -m; Thor and Cheetah:
# ubiattach /dev/ubi_ctrl -m). Sets UBI.
attach() {
	UBI=$(ubi_of_mtd "$1")
	[ -n "$UBI" ] && return 0
	if [ "$FAMILY" = jaguar ]; then
		step "ubiattach mtd$1" ubiattach -m "$1"
	else
		step "ubiattach mtd$1" ubiattach /dev/ubi_ctrl -m "$1"
	fi
	UBI=$(ubi_of_mtd "$1")
	[ -n "$UBI" ] || die "mtd$1 attached, but no UBI device shows it"
}

# stage_ram IMAGE MTD: put IMAGE in an "openwrt" UBI volume on MTD and read it back.
stage_ram() {
	local image=$1 mtd=$2 ubi vol bytes want
	need ubiattach ubimkvol ubirmvol ubiupdatevol
	bytes=$(wc -c < "$image")
	want=$(sha256sum "$image" | cut -d' ' -f1)
	attach "$mtd"; ubi=$UBI
	[ -n "$(vol_of "$ubi" openwrt)" ] && step "remove the old staging volume" ubirmvol "$R/dev/$ubi" -N openwrt
	step "ubimkvol openwrt ($bytes bytes) on $ubi (not enough free space in the inactive slot?)" \
		ubimkvol "$R/dev/$ubi" -N openwrt -s "$bytes"
	vol=$(vol_of "$ubi" openwrt)
	[ -n "$vol" ] || die "the openwrt volume was created but does not show in /sys/class/ubi"
	step "ubiupdatevol $vol" ubiupdatevol "$R/dev/$vol" "$image"
	sync
	[ "$(head -c "$bytes" "$R/dev/$vol" | sha256sum | cut -d' ' -f1)" = "$want" ] ||
		die "the staged image does not read back correctly from $vol"
	say "staged ${image##*/} in $vol on mtd$mtd and read it back"
}

# arm BOOTCMD: arm a one-shot (changing_bootcmd first, as this U-Boot needs).
arm() {
	if [ "$FAMILY" != sage ]; then
		setenv_checked changing_bootcmd 1
	fi
	setenv_checked bootcmd "$1"
	say "armed: bootcmd=$1"
}

finish() {
	sync
	if [ -n "$reboot" ]; then
		say "rebooting"
		reboot
	else
		say "--no-reboot: reboot when ready"
	fi
}

dry_run_stop() {
	[ -n "$yes" ] && return 0
	say "all checks passed. Nothing has been written. Run again with --yes${backed_up:+ --backed-up} to $1"
	exit 0
}

# --- commands --------------------------------------------------------------------------

cmd_ram() {
	local flavour=recovery image off tpart t bootargs=
	on_openwrt && die "this is already OpenWrt: run it from the stock firmware's root shell"
	load_release
	[ -n "$ptest" ] && flavour=persistent
	identify "$flavour"
	check_stock_bootcmd
	case "$FAMILY" in
	sage)
		[ -n "$ptest" ] && die "--persistent-test is for Jaguar"
		[ -n "$tftp" ] || die "Sage U-Boot loads the RAM image over TFTP: give --tftp SERVER, with the recovery image on it as sage-recovery.itb"
		image=$(get_image cambiumnetworks_sage-recovery-initramfs-zImage.itb) || exit 1
		need tftp
		say "checking that $tftp serves sage-recovery.itb"
		tftp -b 8192 -g -l "$WORK/tftp-check.itb" -r sage-recovery.itb "$tftp" 2> "$WORK/err" ||
			die "cannot fetch sage-recovery.itb from $tftp: $(grep . "$WORK/err" | tail -n 1)"
		cmp -s "$WORK/tftp-check.itb" "$image" ||
			die "sage-recovery.itb on $tftp is not the release's recovery image"
		rm -f "$WORK/tftp-check.itb"
		[ -n "$ap_ip" ] || ap_ip=$(ip route get "$tftp" 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')
		[ -n "$ap_ip" ] || die "cannot work out this access point's address: give --ap-ip IP"
		backup
		dry_run_stop "RAM-boot the recovery image from $tftp"
		setenv_checked ipaddr "$ap_ip"
		setenv_checked serverip "$tftp"
		arm "setenv bootcmd bootipq; saveenv; tftpboot 0x84000000 sage-recovery.itb && bootm 0x84000000#$CONFIG; bootipq"
		;;
	jaguar)
		layout_jaguar
		if [ "$RUN" = "$R1" ]; then t=$R0 tpart=rootfs off=0x0; else t=$R1 tpart=rootfs_1 off=$BANK; fi
		if [ -n "$ptest" ]; then
			image=$(get_image cambiumnetworks_jaguar-persistent-initramfs-uImage.itb) || exit 1
			# The A/B trees leave both banks writable: attach none.
			bootargs='setenv bootargs "console=ttyMSM0,115200n8 cnss2.bdf_pci0=0xab swiotlb=1" && '
		else
			image=$(get_image cambiumnetworks_jaguar-recovery-initramfs-uImage.itb) || exit 1
		fi
		backup "$R/dev/mtd${t}ro"
		dry_run_stop "stage the RAM image in $tpart (mtd$t) and boot it once"
		stage_ram "$image" "$t"
		arm "setenv bootcmd bootipq; setenv changing_bootcmd; saveenv; nand device 0 && setenv mtdids nand0=nand0 && setenv mtdparts \"mtdparts=nand0:$BANK@$off($tpart)\" && ubi part $tpart && ubi read 0x60000000 openwrt && ${bootargs}bootm 0x60000000#$CONFIG; reset"
		;;
	thor)
		[ -n "$ptest" ] && die "--persistent-test is for Jaguar"
		layout_thor
		image=$(get_image cambiumnetworks_thor-recovery-initramfs-uImage.itb) || exit 1
		backup "$R/dev/mtd${R0}ro"
		dry_run_stop "stage the RAM image in rootfs (mtd$R0) and boot it once"
		stage_ram "$image" "$R0"
		arm "$(thor_oneshot openwrt)"
		;;
	cheetah)
		[ -n "$ptest" ] && die "--persistent-test is for Jaguar"
		layout_cheetah
		image=$(get_image cambiumnetworks_cheetah-recovery-initramfs-uImage.itb) || exit 1
		backup "$R/dev/mtd${R0}ro"
		dry_run_stop "stage the RAM image in rootfs (mtd$R0) and boot it once"
		stage_ram "$image" "$R0"
		arm "setenv bootcmd bootipq; setenv changing_bootcmd; saveenv; nand device 0; setenv mtdids nand0=nand0; setenv mtdparts \"mtdparts=nand0:0x6000000@0x80000(fs)\"; ubi part fs && ubi read 0x60000000 openwrt && bootm 0x60000000#$CONFIG; reset"
		;;
	*) die "no RAM boot procedure for family $FAMILY" ;;
	esac
	say "one-shot armed: this boot only. Any later reboot or power cycle returns to the stock firmware."
	say "in OpenWrt (DHCP on the LAN port, root without a password) you can run cambium-report.sh"
	finish
}

# Thor one-shot reading volume $1 of rootfs (validated with openwrt).
thor_oneshot() {
	echo "setenv changing_bootcmd; setenv bootcmd \"aq_load_fw&&bootipq\"; saveenv; aq_load_fw; nand device 0; setenv mtdids nand0=nand0; setenv mtdparts \"mtdparts=nand0:0x6000000@0x0(rootfs)\"; ubi part rootfs; ubi read 0x60000000 $1; bootm 0x60000000#$CONFIG; bootipq"
}

install_jaguar() {
	local image ubi v
	layout_jaguar
	require_stock_on_rootfs_1
	image=$(get_image cambiumnetworks_jaguar-persistent-squashfs-factory.ubi) || exit 1
	need ubiformat ubiattach ubidetach
	backup "$R/dev/mtd${R0}ro"
	dry_run_stop "write the persistent image over rootfs (mtd$R0) and boot it once"
	ubi=$(ubi_of_mtd "$R0")
	[ -n "$ubi" ] && step "ubidetach mtd$R0" ubidetach -m "$R0"
	step "ubiformat mtd$R0 with ${image##*/}" ubiformat "$R/dev/mtd$R0" -y -f "$image"
	attach "$R0"; ubi=$UBI
	for v in kernel rootfs rootfs_data cambium_device_data; do
		[ -n "$(vol_of "$ubi" "$v")" ] || die "the written image has no $v volume on mtd$R0"
	done
	say "rootfs (mtd$R0) holds kernel, rootfs, rootfs_data and cambium_device_data"
	arm "setenv bootcmd bootipq; setenv changing_bootcmd; saveenv; nand device 0 && setenv mtdids nand0=nand0 && setenv mtdparts \"mtdparts=nand0:$BANK@0x0(rootfs)\" && ubi part rootfs && ubi read 0x60000000 kernel && setenv bootargs \"console=ttyMSM0,115200n8 cnss2.bdf_pci0=0xab ubi.mtd=rootfs root=/dev/ubiblock0_1 rootfstype=squashfs rootwait swiotlb=1\" && bootm 0x60000000#$CONFIG; reset"
	say "guarded first boot armed: after a healthy start OpenWrt re-arms its boot; otherwise the next boot returns to the stock firmware."
	say "in OpenWrt: set a root password (passwd); cat /tmp/cambium-board-data.status should say vault"
}

install_cheetah() {
	local kernel root ubi id ksize rsize
	layout_cheetah
	kernel=$(get_image cambiumnetworks_cheetah-persistent-squashfs-kernel.itb) || exit 1
	root=$(get_image cambiumnetworks_cheetah-persistent-squashfs-rootfs.squashfs) || exit 1
	need ubiattach ubimkvol ubirmvol ubiupdatevol
	backup "$R/dev/mtd${R0}ro"
	dry_run_stop "replace the volumes in rootfs (mtd$R0) with the persistent image and boot it once"
	attach "$R0"; ubi=$UBI
	for id in $(ls "$R/sys/class/ubi" | sed -n "s/^${ubi}_\([0-9]*\)\$/\1/p" | sort -rn); do
		step "ubirmvol $ubi volume $id" ubirmvol "$R/dev/$ubi" -n "$id"
	done
	ksize=$(wc -c < "$kernel"); rsize=$(wc -c < "$root")
	step "ubimkvol kernel" ubimkvol "$R/dev/$ubi" -N kernel -s "$ksize"
	step "ubiupdatevol kernel" ubiupdatevol "$R/dev/$(vol_of "$ubi" kernel)" "$kernel"
	step "ubimkvol rootfs" ubimkvol "$R/dev/$ubi" -N rootfs -s "$rsize"
	step "ubiupdatevol rootfs" ubiupdatevol "$R/dev/$(vol_of "$ubi" rootfs)" "$root"
	step "ubimkvol rootfs_data" ubimkvol "$R/dev/$ubi" -N rootfs_data -m
	sync
	[ "$(head -c "$ksize" "$R/dev/$(vol_of "$ubi" kernel)" | sha256sum | cut -d' ' -f1)" = "$(sha256sum < "$kernel" | cut -d' ' -f1)" ] ||
		die "the kernel volume does not read back correctly"
	[ "$(head -c "$rsize" "$R/dev/$(vol_of "$ubi" rootfs)" | sha256sum | cut -d' ' -f1)" = "$(sha256sum < "$root" | cut -d' ' -f1)" ] ||
		die "the rootfs volume does not read back correctly"
	say "kernel and rootfs written to mtd$R0 and read back"
	arm "setenv bootcmd bootipq; setenv changing_bootcmd; saveenv; nand device 0; setenv mtdids nand0=nand0; setenv mtdparts \"mtdparts=nand0:0x6000000@0x80000(fs)\"; ubi part fs && ubi read 0x60000000 kernel && bootm 0x60000000#$CONFIG; bootipq"
	say "guarded first boot armed: OpenWrt re-arms its boot after each healthy start."
}

install_sage() {
	local kernel root lk lr ksize rsize
	layout_sage
	kernel=$(get_image cambiumnetworks_sage-persistent-squashfs-kernel.itb) || exit 1
	root=$(get_image cambiumnetworks_sage-persistent-squashfs-rootfs.ubifs) || exit 1
	need ubiupdatevol
	lk=$(vol_of ubi0 "linux$T"); lr=$(vol_of ubi0 "rootfs$T")
	ksize=$(wc -c < "$kernel"); rsize=$(wc -c < "$root")
	[ "$ksize" -le "$(cat "$R/sys/class/ubi/$lk/data_bytes")" ] || die "the kernel ($ksize bytes) does not fit linux$T"
	[ "$rsize" -le "$(cat "$R/sys/class/ubi/$lr/data_bytes")" ] || die "the root filesystem ($rsize bytes) does not fit rootfs$T"
	backup "$R/dev/$lk" "$R/dev/$lr"
	dry_run_stop "write the persistent image into pair $T (linux$T, rootfs$T) and trial it once"
	step "ubiupdatevol linux$T" ubiupdatevol "$R/dev/$lk" "$kernel"
	step "ubiupdatevol rootfs$T" ubiupdatevol "$R/dev/$lr" "$root"
	sync
	[ "$(head -c "$ksize" "$R/dev/$lk" | sha256sum | cut -d' ' -f1)" = "$(sha256sum < "$kernel" | cut -d' ' -f1)" ] ||
		die "linux$T does not read back correctly"
	[ "$(head -c "$rsize" "$R/dev/$lr" | sha256sum | cut -d' ' -f1)" = "$(sha256sum < "$root" | cut -d' ' -f1)" ] ||
		die "rootfs$T does not read back correctly"
	setenv_checked owrt_trial_slot "$T"
	setenv_checked owrt_fallback_slot "$I"
	arm "setenv bootcmd bootipq; setenv image $I; setenv bootcount 0; saveenv; setenv image $T; setenv bootargs \"mtdparts=spi0.1:128M(fs) ubi.mtd=fs root=ubi0:rootfs\${image} rootfstype=ubifs rootwait\"; nand device 1 && setenv mtdids nand1=nand1 && setenv mtdparts \"mtdparts=nand1:0x8000000@0x0(fs)\" && ubi part fs && ubi read 0x84000000 linux\${image} && bootm 0x84000000#$CONFIG; setenv image $I; bootipq"
	setenv_checked image "$I"
	setenv_checked bootcount 0
	say "one-shot trial of pair $T armed; the stock firmware stays the default."
	say "in OpenWrt: passwd, check the LAN and both radios, then: sage-migration-mark-good --confirm"
}

# Thor, stage 1 (stock firmware): RAM-boot the installer.
install_thor_stock() {
	local image
	layout_thor
	image=$(get_image cambiumnetworks_thor-installer-initramfs-uImage.itb) || exit 1
	backup "$R/dev/mtd${R0}ro"
	dry_run_stop "stage the installer in rootfs (mtd$R0) and boot it once"
	stage_ram "$image" "$R0"
	arm "$(thor_oneshot openwrt)"
	say "the installer boots once. In it (SSH root@AP_IP), run this script again: sh cambium-install.sh --from ... install --yes"
}

# Thor, stage 2 (OpenWrt installer in RAM): write the persistent image.
install_thor_installer() {
	local image r0
	grep -q 'ubi.mtd=' "$R/proc/cmdline" && die "this OpenWrt runs from flash, not the Thor installer in RAM"
	r0=$(mtd_idx rootfs)
	[ -n "$r0" ] || die "no rootfs partition in /proc/mtd"
	[ "$(mtd_size rootfs)" = 06000000 ] || die "rootfs is not 96 MiB"
	[ $(( $(cat "$R/sys/class/mtd/mtd$r0/flags") & 0x400 )) -ne 0 ] || die "rootfs is read-only: this is not the Thor installer"
	image=$(get_image cambiumnetworks_thor-persistent-squashfs-factory.ubi) || exit 1
	need ubiformat
	dry_run_stop "write the persistent image over rootfs (mtd$r0)"
	[ -n "$(ubi_of_mtd "$r0")" ] && step "ubidetach mtd$r0" ubidetach -m "$r0"
	step "ubiformat mtd$r0 with ${image##*/}" ubiformat "$R/dev/mtd$r0" -y -f "$image"
	say "installed. Rebooting to the stock firmware; there, run: sh cambium-install.sh --from ... boot --yes"
}

cmd_install() {
	load_release
	if on_openwrt; then
		identify installer
		[ "$FAMILY" = thor ] || die "run install from the stock firmware; on OpenWrt only the Thor installer uses it"
		install_thor_installer
		finish
		return
	fi
	identify persistent
	[ -n "$ptest" ] && die "--persistent-test belongs to ram"
	check_stock_bootcmd
	case "$FAMILY" in
	jaguar) install_jaguar ;;
	cheetah) install_cheetah ;;
	sage) install_sage ;;
	thor) identify installer; install_thor_stock ;;
	*) die "no install procedure for family $FAMILY" ;;
	esac
	finish
}

# Thor, stage 3 (stock firmware): trial boot the installed image once.
cmd_boot() {
	local ubi
	on_openwrt && die "run boot from the stock firmware"
	load_release
	identify persistent
	[ "$FAMILY" = thor ] || die "boot is only for Thor; other families arm their first boot during install"
	check_stock_bootcmd
	layout_thor
	attach "$R0"; ubi=$UBI
	[ -n "$(vol_of "$ubi" kernel)" ] && [ -n "$(vol_of "$ubi" rootfs)" ] ||
		die "rootfs (mtd$R0) has no installed kernel and rootfs: run install first"
	dry_run_stop "boot the installed image once"
	arm "$(thor_oneshot kernel)"
	say "trial boot armed. When OpenWrt, its LAN and radios are healthy, run in OpenWrt: sh cambium-install.sh --from ... commit --yes"
	finish
}

# Thor, stage 4 (installed OpenWrt): make it the default.
cmd_commit() {
	on_openwrt || die "run commit in the installed OpenWrt"
	grep -q 'ubi.mtd=rootfs ' "$R/proc/cmdline" || grep -q 'ubi.mtd=rootfs$' "$R/proc/cmdline" ||
		die "this OpenWrt is not running from rootfs"
	load_release
	identify persistent
	[ "$FAMILY" = thor ] || die "commit is only for Thor; Jaguar and Cheetah re-arm their own boot, Sage uses sage-migration-mark-good"
	need fw_setenv fw_printenv
	dry_run_stop "make the installed image the default boot"
	setenv_checked changing_bootcmd 1
	setenv_checked bootcmd "aq_load_fw; nand device 0; setenv mtdids nand0=nand0; setenv mtdparts \"mtdparts=nand0:0x6000000@0x0(rootfs)\"; ubi part rootfs; ubi read 0x60000000 kernel; bootm 0x60000000#$CONFIG"
	say "OpenWrt is now the default boot; rootfs_1 keeps the stock firmware for a manual return."
}

[ "$(id -u 2>/dev/null)" = 0 ] || [ -n "$R" ] || die "run this as root"
case "$cmd" in
ram) cmd_ram ;;
install) cmd_install ;;
boot) cmd_boot ;;
commit) cmd_commit ;;
esac
