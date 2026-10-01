#!/bin/sh
# cambium-install.sh: RAM-boot or install Cambium OpenWrt from the access
# point's stock firmware root shell, for every built family (Sage, Thor,
# Jaguar, Cheetah, Gambit E400). It encodes the procedures on
# https://m0vse.github.io/cambium-openwrt/#install.
#
#   sh cambium-install.sh [options] ram       RAM-boot the recovery image
#   sh cambium-install.sh [options] install   install the persistent image
#   sh cambium-install.sh [options] stock     installed OpenWrt, not yet
#                                             converted to A/B: make the
#                                             stock firmware the default boot
#   sh cambium-install.sh [options] update-upgrader
#                                             installed A/B OpenWrt: install
#                                             the release's upgrade scripts
#
# Options:
#   --from SRC      where the release files come from: a directory holding
#                   them, an http(s) URL of such a directory, or tftp:SERVER
#   --release TAG   download from the GitHub release TAG (needs https wget)
#   --tftp SERVER   TFTP server for backup uploads on non-Sage families
#   --backed-up     you have copied the backups off the access point
#                   (not needed when --from is http served by cambium-serve.py:
#                   the backups are then uploaded to it and checked)
#   --trial         hardware trial of a persistent image that is not yet
#                   validated on this model (only on a unit you can recover)
#   --persistent-test  Jaguar: RAM-boot the A/B persistent trees instead
#                   (test-only image), with no firmware bank attached
#   --format-inactive  let ram erase the inactive slot (after backing it up)
#                   when its stock firmware copy leaves too little free space
#                   for the RAM image
#   --no-reboot     arm everything but do not reboot
#   --yes           make the changes; without it only checks and backs up
#   --overwrite-inactive-rootfs  Sage RAM: confirm replacing the inactive
#                   OEM rootfs after it has been backed up and hash-verified
#                   off-AP through cambium-serve.py
#
# Nothing is written until every check has passed and --yes is given. Each
# step that writes stops at the first error and names the command, its exit
# status and its error; the full log is /tmp/cambium-install/install.log.

VERSION=1
R=${CAMBIUM_ROOT:-}
CURL=${CAMBIUM_CURL:-curl}  # a test hook
WORK=$R/tmp/cambium-install
LOG=$WORK/install.log
GITHUB=https://github.com/m0vse/cambium-openwrt/releases/download
cmd= src= tftp= backed_up= trial= yes= reboot=1 ptest= format_inactive= overwrite_inactive_rootfs=
while [ $# -gt 0 ]; do
	case "$1" in
	ram|install|stock|update-upgrader) cmd=$1 ;;
	--from) src=${2:-}; shift ;;
	--release) src=$GITHUB/${2:-}; shift ;;
	--backed-up) backed_up=1 ;;
	--tftp) tftp=${2:-}; shift ;;
	--trial) trial=1 ;;
	--persistent-test) ptest=1 ;;
	--format-inactive) format_inactive=1 ;;
	--overwrite-inactive-rootfs) overwrite_inactive_rootfs=1 ;;
	--no-reboot) reboot= ;;
	--yes) yes=1 ;;
	-h|--help) sed -n '2,38p' "$0"; exit 0 ;;
	*) echo "cambium-install: unknown argument '$1' (see --help)" >&2; exit 2 ;;
	esac
	shift
done
[ -n "$cmd" ] || { sed -n '2,38p' "$0"; exit 2; }
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
# mtd_idx NAME: the flash partition NAME. The stock firmware can also list a
# UBI volume under the same name (gluebi, sysfs type "ubi", e.g. a second
# "rootfs"); only the first real partition counts.
mtd_idx() {
	local i
	for i in $(sed -n "s/^mtd\([0-9]*\): [0-9a-f]* [0-9a-f]* \"$1\"\$/\1/p" "$R/proc/mtd"); do
		[ "$(cat "$R/sys/class/mtd/mtd$i/type" 2>/dev/null)" = ubi ] && continue
		echo "$i"
		return 0
	done
}
mtd_size() {
	local i
	i=$(mtd_idx "$1")
	[ -n "$i" ] && sed -n "s/^mtd$i: \([0-9a-f]*\) .*/\1/p" "$R/proc/mtd"
}
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
				die "cannot download ${src%/}/$name (wget exit $rc: $(grep . "$WORK/err" | tail -n 1)). If this firmware's wget has no https, serve the release files over http from your computer (python3 cambium-serve.py 8000, in the folder holding them) and use --from http://COMPUTER_IP:8000" ;;
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
	# Bank 1 follows bank 0 directly.
	bank_offset "$R0" 0 rootfs
	bank_offset "$R1" $((0x$S0)) rootfs_1
}
# bank_offset MTD WANT NAME: the partition must start at NAND offset WANT
# (bytes) where the kernel reports offsets.
bank_offset() {
	local off
	off=$(cat "$R/sys/class/mtd/mtd$1/offset" 2>/dev/null)
	[ -z "$off" ] || [ "$off" = "$2" ] ||
		die "$MODEL $3 starts at NAND offset $off, not $(printf '0x%x' "$2"): not the captured $FAMILY layout. Run cambium-report.sh and open an issue"
}
layout_thor() {
	slots
	[ "$S0:$S1" = 06000000:06000000 ] || die "$MODEL rootfs is $S0 and rootfs_1 $S1 bytes (hex), not 06000000 each: this layout has not been captured. Run cambium-report.sh and open an issue"
	bank_offset "$R0" 0 rootfs
	bank_offset "$R1" 100663296 rootfs_1
	require_stock_on_rootfs_1
}
layout_cheetah() {
	local t
	slots
	[ "$S0:$S1" = 06000000:06000000 ] || die "$MODEL rootfs is $S0 and rootfs_1 $S1 bytes (hex), not 06000000 each: not the captured Cheetah layout. Run cambium-report.sh and open an issue"
	# 0:TRAINING (512 KiB at the start of the NAND) comes before rootfs.
	t=$(mtd_idx 0:TRAINING)
	[ -n "$t" ] && [ "$(mtd_size 0:TRAINING)" = 00080000 ] ||
		die "$MODEL has no 512 KiB 0:TRAINING partition: not the captured Cheetah layout. Run cambium-report.sh and open an issue"
	bank_offset "$t" 0 0:TRAINING
	bank_offset "$R0" 524288 rootfs
	bank_offset "$R1" 101187584 rootfs_1
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
	local cur want=bootipq slot addr
	[ "$FAMILY" = thor ] && want='aq_load_fw&&bootipq'
	if [ "$FAMILY" = gambit ]; then
		slot=$(gambit_oem_slot)
		case "$slot" in 0) want='nboot 0x81000000 0 0x00000000' ;; 1) want='nboot 0x81000000 0 0x03000000' ;; *) die 'cannot determine the running OEM Gambit bank' ;; esac
	fi
	need fw_printenv fw_setenv
	cur=$(getenv bootcmd) || die "cannot read the U-Boot environment (fw_printenv failed)"
	if [ "$FAMILY" = gambit ] && [ "$cur" = 'nboot 0x81000000 0 ${load_addr}' ]; then
		addr=$(getenv load_addr)
		case "$slot:$addr" in 0:0x00000000|0:0x0|1:0x03000000|1:0x3000000) return 0 ;; esac
	fi
	[ "$cur" = "$want" ] || die "bootcmd is '$cur', not the stock '$want': a one-shot or install is already armed. Reboot once (a one-shot restores itself) and run this again"
}

# --- backups -------------------------------------------------------------------------

# backup NAME SOURCE...: raw copies of what this run may write, plus the
# U-Boot environment and ART, into ${BACKUP_DIR:-$WORK/backup}.
backup() {
	local b=${BACKUP_DIR:-$WORK/backup} f n i protected='0:APPSBLENV 0:ART'
	[ "$FAMILY" != gambit ] || protected='u-boot-env ART'
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
	for n in $protected; do
		i=$(mtd_idx "$n")
		[ -n "$i" ] || die "no $n partition in /proc/mtd to back up"
		[ -s "$b/${n#0:}.bin" ] || step "back up $n" dd if="$R/dev/mtd${i}ro" of="$b/${n#0:}.bin"
	done
	(cd "$b" && sha256sum *.bin > SHA256SUMS) || die "cannot hash the backups (out of space in /tmp?)"
	[ -f "$b/uploaded" ] && cmp -s "$b/SHA256SUMS" "$b/uploaded" && {
		say "backups already uploaded to your computer and checked"
		return 0
	}
	case "$src" in
	http://*|https://*)
		upload_http "$b"
		cp "$b/SHA256SUMS" "$b/uploaded"
		return 0 ;;
	esac
	if [ -n "$tftp" ]; then
		for f in "$b"/*; do
			step "upload ${f##*/} to TFTP server $tftp (it must accept uploads)" \
				tftp -b 8192 -p -l "$f" -r "${BACKUP_PREFIX:-cambium-backup-sku$SKU}-${f##*/}" "$tftp"
		done
		say "backups uploaded to $tftp as ${BACKUP_PREFIX:-cambium-backup-sku$SKU}-*; check them against SHA256SUMS"
		return 0
	fi
	say "backups are in $b; copy them off the access point, e.g. from your computer:"
	say "  scp -O 'root@AP_IP:$b/*' ."
	[ -n "$yes" ] && die "copy the backups off the access point first, then run this again with --backed-up (or serve the release with cambium-serve.py, or give --tftp SERVER, to upload them)"
}

# hexenc FILE: the file as hex text (no zero bytes), with hexdump or od.
hexenc() {
	if have hexdump; then
		hexdump -v -e '1/1 "%02x"' "$1"
	else
		od -An -v -tx1 "$1"
	fi
}

# upload_http DIR: send each backup to cambium-serve.py on the release server
# in hex-encoded 256 KiB chunks (BusyBox wget stops a posted file at its
# first zero byte). Every chunk and the whole file must come back with the
# SHA-256 they have here. A wget that cannot post (the E410/E410B stock
# firmware's) hands over to curl, which sends each whole file.
upload_http() {
	local f name size off got want chunk=262144 url
	if ! wget --help 2>&1 | grep -q -- '--post-file'; then
		have "$CURL" ||
			die "this firmware's wget cannot upload files (no --post-file) and it has no curl: copy $1 off the access point yourself and use --backed-up, or give --tftp SERVER"
		upload_curl "$1"
		return
	fi
	have hexdump || have od || die "this firmware has neither hexdump nor od to encode the backups for upload"
	for f in "$1"/*; do
		name=${BACKUP_PREFIX:-cambium-backup-sku$SKU}-${f##*/}
		url=${src%/}/upload/$name
		size=$(wc -c < "$f")
		say "uploading ${f##*/} ($size bytes) to your computer as uploads/$name"
		off=0
		while [ "$off" -lt "$size" ]; do
			dd if="$f" of="$WORK/chunk" bs="$chunk" skip=$((off / chunk)) count=1 2> /dev/null ||
				die "cannot read ${f##*/} at byte $off"
			hexenc "$WORK/chunk" > "$WORK/chunk.hex" || die "cannot encode ${f##*/} at byte $off"
			got=$(wget -q -O - --post-file "$WORK/chunk.hex" "$url?offset=$off" 2> "$WORK/err") || {
				grep -q '50[01]' "$WORK/err" &&
					die "the server does not accept uploads: serve the release files with 'python3 cambium-serve.py 8000' instead of python3 -m http.server"
				die "cannot upload ${f##*/} at byte $off to $url ($(grep . "$WORK/err" | tail -n 1))"
			}
			want=$(sha256sum < "$WORK/chunk" | cut -d' ' -f1)
			[ "${got%% *}" = "$want" ] ||
				die "your computer stored the chunk of ${f##*/} at byte $off with SHA-256 '${got%% *}' but it is $want here: the upload is damaged"
			off=$((off + chunk))
		done
		got=$(wget -q -O - --post-data done "$url?done" 2> "$WORK/err") ||
			die "cannot finish the upload of ${f##*/} ($(grep . "$WORK/err" | tail -n 1))"
		want=$(sha256sum < "$f" | cut -d' ' -f1)
		[ "${got%% *}" = "$want" ] ||
			die "your computer stored ${f##*/} with SHA-256 '${got%% *}' but it is $want here: the upload is damaged"
	done
	rm -f "$WORK/chunk" "$WORK/chunk.hex"
	say "backups uploaded to the uploads folder beside the release files, and their SHA-256 checked"
}

# upload_curl DIR: send each whole backup with curl (an HTTP PUT); the answer
# must be the SHA-256 it has here.
upload_curl() {
	local f name url got want
	for f in "$1"/*; do
		name=${BACKUP_PREFIX:-cambium-backup-sku$SKU}-${f##*/}
		url=${src%/}/upload/$name
		say "uploading ${f##*/} ($(wc -c < "$f") bytes) with curl to your computer as uploads/$name"
		got=$("$CURL" -sS -f -T "$f" "$url" 2> "$WORK/err") || {
			grep -q '50[01]' "$WORK/err" &&
				die "the server does not accept uploads: serve the release files with 'python3 cambium-serve.py 8000' instead of python3 -m http.server"
			die "cannot upload ${f##*/} to $url ($(grep . "$WORK/err" | tail -n 1))"
		}
		want=$(sha256sum < "$f" | cut -d' ' -f1)
		[ "${got%% *}" = "$want" ] ||
			die "your computer stored ${f##*/} with SHA-256 '${got%% *}' but it is $want here: the upload is damaged"
	done
	say "backups uploaded to the uploads folder beside the release files, and their SHA-256 checked"
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
	local image=$1 mtd=$2 ubi vol bytes want leb free
	need ubiattach ubimkvol ubirmvol ubiupdatevol
	[ -z "$format_inactive" ] || need ubiformat ubidetach
	bytes=$(wc -c < "$image")
	want=$(sha256sum "$image" | cut -d' ' -f1)
	attach "$mtd"; ubi=$UBI
	[ -n "$(vol_of "$ubi" openwrt)" ] && step "remove the old staging volume" ubirmvol "$R/dev/$ubi" -N openwrt
	leb=$(cat "$R/sys/class/ubi/$ubi/eraseblock_size" 2>/dev/null)
	free=$(cat "$R/sys/class/ubi/$ubi/avail_eraseblocks" 2>/dev/null)
	if [ -n "$leb" ] && [ -n "$free" ] && [ "$free" -lt $(( (bytes + leb - 1) / leb )) ]; then
		[ -n "$format_inactive" ] ||
			die "the inactive slot (mtd$mtd) has $free free UBI eraseblocks but the RAM image needs $(( (bytes + leb - 1) / leb )): its stock firmware copy fills it. Run again with --format-inactive to erase that slot (it is backed up) and stage the image there"
		say "erasing the inactive slot mtd$mtd (--format-inactive; its backup is off the access point)"
		step "ubidetach mtd$mtd" ubidetach -m "$mtd"
		step "ubiformat mtd$mtd" ubiformat "$R/dev/mtd$mtd" -y
		attach "$mtd"; ubi=$UBI
	fi
	step "ubimkvol openwrt ($bytes bytes) on $ubi" \
		ubimkvol "$R/dev/$ubi" -N openwrt -s "$bytes"
	vol=$(vol_of "$ubi" openwrt)
	[ -n "$vol" ] || die "the openwrt volume was created but does not show in /sys/class/ubi"
	step "ubiupdatevol $vol" ubiupdatevol "$R/dev/$vol" "$image"
	sync
	[ "$(head -c "$bytes" "$R/dev/$vol" | sha256sum | cut -d' ' -f1)" = "$want" ] ||
		die "the staged image does not read back correctly from $vol"
	say "staged ${image##*/} in $vol on mtd$mtd and read it back"
}

# verify_factory UBI CONTENTS: hash the kernel and rootfs content of a
# written factory image. CONTENTS lists "volume bytes sha256" as built: the
# FIT's own size and the SquashFS bytes_used, without the UBI padding.
verify_factory() {
	local ubi=$1 contents=$2 name bytes want vol
	while read -r name bytes want; do
		vol=$(vol_of "$ubi" "$name")
		[ -n "$vol" ] || die "the written image has no $name volume"
		[ "$(head -c "$bytes" "$R/dev/$vol" | sha256sum | cut -d' ' -f1)" = "$want" ] ||
			die "the $name volume does not read back as built (first $bytes bytes)"
		say "$name volume reads back as built ($bytes bytes)"
	done < "$contents"
}

# arm BOOTCMD: arm a one-shot (changing_bootcmd first, as this U-Boot needs).
arm() {
	if [ "$FAMILY" != sage ] && [ "$FAMILY" != gambit ]; then
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
	local flavour=recovery image off tpart upart t bootargs= vol bytes lebs lebsize capacity magic want hexbytes art
	on_openwrt && die "this is already OpenWrt: run it from the stock firmware's root shell"
	load_release
	[ -n "$ptest" ] && flavour=persistent
	identify "$flavour"
	check_stock_bootcmd
	case "$FAMILY" in
	gambit)
		[ -z "$ptest" ] || die '--persistent-test is for Jaguar'
		gambit_stage_ram recovery
		;;
	sage)
		[ -n "$ptest" ] && die "--persistent-test is for Jaguar"
		[ -z "$backed_up" ] || die "Sage RAM recovery's off-AP backup must be hash-verified; --backed-up is not sufficient"
		case "$src" in http://*|https://*) ;; *) die "Sage RAM recovery needs --from http://COMPUTER_IP:PORT served by cambium-serve.py, to verify the off-AP backup" ;; esac
		layout_sage
		image=$(get_image cambiumnetworks_sage-recovery-initramfs-zImage.itb) || exit 1
		vol=$(vol_of ubi0 "rootfs$T")
		[ -n "$vol" ] || die "inactive Sage rootfs$T volume is missing"
		bytes=$(wc -c < "$image" | tr -d ' ')
		lebs=$(cat "$R/sys/class/ubi/$vol/reserved_ebs" 2>/dev/null)
		lebsize=$(cat "$R/sys/class/ubi/$vol/usable_eb_size" 2>/dev/null)
		case "$lebs:$lebsize" in *[!0-9:]*|:*|*:) die "cannot determine the capacity of $vol" ;; esac
		need od
		capacity=$((lebs * lebsize))
		[ -n "$capacity" ] || die "cannot determine the capacity of $vol"
		[ "$bytes" -le "$capacity" ] || die "recovery image is $bytes bytes, larger than $vol ($capacity bytes)"
		magic=$(head -c 4 "$R/dev/$vol" | od -An -tx1 | tr -d ' \n')
		[ "$magic" != d00dfeed ] || die "$vol already contains a FIT image; refusing to replace the previous OEM backup"
		[ -z "$yes" ] || [ -n "$overwrite_inactive_rootfs" ] ||
			die "Sage RAM recovery overwrites inactive rootfs$T: confirm with --overwrite-inactive-rootfs"
		# Fingerprint the AP and the pre-write rootfs, so an interrupted write
		# can never overwrite the verified OEM backup on a later retry.
		art=$(mtd_idx 0:ART)
		[ -n "$art" ] || die "no 0:ART partition in /proc/mtd"
		BACKUP_DIR=$WORK/backup-sage
		BACKUP_PREFIX=cambium-backup-sku$SKU-$(sha256sum < "$R/dev/mtd${art}ro" | cut -c1-12)-$(sha256sum < "$R/dev/$vol" | cut -c1-12)
		rm -f "$BACKUP_DIR/$vol.bin" "$BACKUP_DIR/APPSBLENV.bin" "$BACKUP_DIR/ART.bin" "$BACKUP_DIR/uploaded"
		backup "$R/dev/$vol"
		if [ -z "$yes" ]; then
			say "all checks passed. Nothing has been written to flash. Run again with --yes --overwrite-inactive-rootfs to stage the recovery image"
			exit 0
		fi
		need ubiupdatevol
		want=$(sha256sum "$image" | cut -d' ' -f1)
		step "stage recovery image in $vol" ubiupdatevol "$R/dev/$vol" "$image"
		sync
		[ "$(head -c "$bytes" "$R/dev/$vol" | sha256sum | cut -d' ' -f1)" = "$want" ] ||
			die "the staged recovery image does not read back correctly from $vol"
		say "staged recovery image in inactive $vol and verified its SHA-256"
		hexbytes=$(printf '%x' "$bytes")
		arm "setenv bootcmd bootipq; saveenv; nand device 1 && setenv mtdids nand1=nand1 && setenv mtdparts \"mtdparts=nand1:0x8000000@0x0(fs)\" && ubi part fs && ubi read 0x84000000 rootfs$T 0x$hexbytes && bootm 0x84000000#$CONFIG; bootipq"
		;;
	jaguar)
		layout_jaguar
		# Slot 0: the XV2-2T1's validated "(rootfs)" form; slot 1: the "(fs)"
		# form that RAM-booted the XV2-2 from its slot 1.
		if [ "$RUN" = "$R1" ]; then t=$R0 tpart=rootfs upart=rootfs off=0x0; else t=$R1 tpart=rootfs_1 upart=fs off=$BANK; fi
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
		arm "setenv bootcmd bootipq; setenv changing_bootcmd; saveenv; nand device 0 && setenv mtdids nand0=nand0 && setenv mtdparts \"mtdparts=nand0:$BANK@$off($upart)\" && ubi part $upart && ubi read 0x60000000 openwrt && ${bootargs}bootm 0x60000000#$CONFIG; reset"
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
# The cambium-ab Thor module's guarded boot of slot 0 (config@hk02 is rooted
# in rootfs).
thor_guarded() {
	echo "setenv changing_bootcmd; setenv bootcmd \"aq_load_fw&&bootipq\"; saveenv; aq_load_fw; nand device 0 && setenv mtdids nand0=nand0 && setenv mtdparts \"mtdparts=nand0:0x6000000@0x0(rootfs)\" && ubi part rootfs && ubi read 0x60000000 kernel && bootm 0x60000000#$CONFIG; bootipq"
}

install_jaguar() {
	local image contents ubi v t tslot
	layout_jaguar
	# OpenWrt goes into whichever slot the stock firmware is not running from.
	if [ "$RUN" = "$R1" ]; then t=$R0 tslot=0; else t=$R1 tslot=1; fi
	image=$(get_image cambiumnetworks_jaguar-persistent-squashfs-factory.ubi) || exit 1
	contents=$(get_image cambiumnetworks_jaguar-persistent-squashfs-factory.ubi.contents) || exit 1
	need ubiformat ubiattach ubidetach
	backup "$R/dev/mtd${t}ro"
	dry_run_stop "write the persistent image over $([ "$tslot" = 0 ] && echo rootfs || echo rootfs_1) (mtd$t) and boot it once"
	ubi=$(ubi_of_mtd "$t")
	[ -n "$ubi" ] && step "ubidetach mtd$t" ubidetach -m "$t"
	step "ubiformat mtd$t with ${image##*/}" ubiformat "$R/dev/mtd$t" -y -f "$image"
	attach "$t"; ubi=$UBI
	for v in kernel rootfs rootfs_data cambium_device_data; do
		[ -n "$(vol_of "$ubi" "$v")" ] || die "the written image has no $v volume on mtd$t"
	done
	verify_factory "$ubi" "$contents"
	say "slot $tslot (mtd$t) holds kernel, rootfs, rootfs_data and cambium_device_data"
	case "$tslot" in
	0) arm "setenv bootcmd bootipq; setenv changing_bootcmd; saveenv; nand device 0 && setenv mtdids nand0=nand0 && setenv mtdparts \"mtdparts=nand0:$BANK@0x0(rootfs)\" && ubi part rootfs && ubi read 0x60000000 kernel && setenv bootargs \"console=ttyMSM0,115200n8 cnss2.bdf_pci0=0xab ubi.mtd=rootfs root=/dev/ubiblock0_1 rootfstype=squashfs rootwait swiotlb=1\" && bootm 0x60000000#$CONFIG; reset" ;;
	1) arm "setenv bootcmd bootipq; setenv changing_bootcmd; saveenv; nand device 0 && setenv mtdids nand0=nand0 && setenv mtdparts \"mtdparts=nand0:$BANK@$BANK(fs)\" && ubi part fs && ubi read 0x60000000 kernel && setenv bootargs \"console=ttyMSM0,115200n8 cnss2.bdf_pci0=0xab ubi.mtd=rootfs_1 root=/dev/ubiblock0_1 rootfstype=squashfs rootwait swiotlb=1\" && bootm 0x60000000#$CONFIG; reset" ;;
	esac
	say "guarded first boot of slot $tslot armed: after a healthy start OpenWrt re-arms its boot; otherwise the next boot returns to the stock firmware."
	say "in OpenWrt: set a root password (passwd); cat /tmp/cambium-board-data.status should say vault"
}

install_cheetah() {
	local image contents ubi v
	layout_cheetah
	image=$(get_image cambiumnetworks_cheetah-persistent-squashfs-factory.ubi) || exit 1
	contents=$(get_image cambiumnetworks_cheetah-persistent-squashfs-factory.ubi.contents) || exit 1
	need ubiformat ubiattach ubidetach
	backup "$R/dev/mtd${R0}ro"
	dry_run_stop "write the persistent image over rootfs (mtd$R0) and boot it once"
	[ -n "$(ubi_of_mtd "$R0")" ] && step "ubidetach mtd$R0" ubidetach -m "$R0"
	step "ubiformat mtd$R0 with ${image##*/}" ubiformat "$R/dev/mtd$R0" -y -f "$image"
	attach "$R0"; ubi=$UBI
	for v in kernel rootfs rootfs_data cambium_device_data; do
		[ -n "$(vol_of "$ubi" "$v")" ] || die "the written image has no $v volume on mtd$R0"
	done
	verify_factory "$ubi" "$contents"
	# The cambium-ab Cheetah module's guarded boot of slot 0.
	arm "setenv bootcmd bootipq; setenv changing_bootcmd; saveenv; nand device 0; setenv mtdids nand0=nand0; setenv mtdparts \"mtdparts=nand0:0x6000000@0x80000(fs)\"; ubi part fs && ubi read 0x60000000 kernel && setenv bootargs \"console=ttyMSM0,115200n8 ubi.mtd=rootfs root=/dev/ubiblock0_1 rootfstype=squashfs rootwait\" && bootm 0x60000000#$CONFIG; bootipq"
	say "guarded first boot armed: after a healthy start OpenWrt re-arms its boot; otherwise the next boot returns to the stock firmware."
}

# The stock firmware has no OpenWrt board-sku node, so identify the pair with
# layout_sage and select-config first, then use the same family writer and
# trial arming functions that sysupgrade uses on a running OpenWrt system.
install_sage_ab() {
	local kernel root core writer module boardlib board lk lr f
	layout_sage
	kernel=$(get_image cambiumnetworks_sage-persistent-squashfs-kernel.itb) || exit 1
	root=$(get_image cambiumnetworks_sage-persistent-squashfs-rootfs.ubifs) || exit 1
	core=$(get_image cambium-ab.sh) || exit 1
	writer=$(get_image cambium-ab-upgrade.sh) || exit 1
	module=$(get_image cambium-ab-sage.sh) || exit 1
	boardlib=$(get_image cambium-sage.sh) || exit 1
	for f in "$core" "$writer" "$module" "$boardlib"; do
		step "syntax check of ${f##*/}" sh -n "$f"
	done
	need fw_printenv fw_setenv ubiupdatevol
	mkdir -p "$WORK/ab-modules" || die "cannot stage the Sage A/B module"
	step "stage Sage A/B module" cp "$module" "$WORK/ab-modules/cambium-ab-sage.sh"
	CAMBIUM_AB_LIB=$core CAMBIUM_AB_MODULES=$WORK/ab-modules CAMBIUM_SAGE_LIB=$boardlib
	AB_DEV=$R/dev AB_UBI_SYS=$R/sys/class/ubi AB_PROC_MTD=$R/proc/mtd AB_MTD_SYS=$R/sys/class/mtd
	AB_LOG=$WORK/ab-write.log
	. "$writer"
	board=cambiumnetworks,$(printf '%s' "$MODEL" | tr '[:upper:]' '[:lower:]')
	ab_board "$board" || die "the shared A/B writer has no Sage board $board"
	[ "$AB_QUALIFIED" = 1 ] || die "the shared A/B writer has not qualified $MODEL for persistent install"
	[ "$CONFIG" = "$AB_FIT" ] || [ "$AB_SAGE_LEGACY_B" = 1 ] ||
		die "release selects $CONFIG but the Sage A/B module selects $AB_FIT"
	AB_ACTIVE=$I AB_TARGET=$T AB_ACTIVE_UBI=ubi0
	AB_KERNEL=$kernel AB_ROOT=$root
	AB_KERNEL_SIZE=$(wc -c < "$kernel") AB_ROOT_SIZE=$(wc -c < "$root")
	ab_sage_image_fits "$AB_KERNEL_SIZE" "$AB_ROOT_SIZE" ||
		die "the persistent image does not fit the inactive Sage pair"
	lk=$(vol_of ubi0 "linux$T"); lr=$(vol_of ubi0 "rootfs$T")
	backup "$R/dev/$lk" "$R/dev/$lr"
	dry_run_stop "write the persistent image into pair $T and arm its guarded A/B trial"
	ab_sage_write_target || die "the shared A/B writer could not write and verify pair $T"
	ab_setenv sage_oem_fallback "$I" ||
		die "cannot record the preserved OEM pair $I"
	sync
	ab_arm_trial || die "the shared A/B writer could not arm pair $T"
	say "guarded A/B trial of pair $T armed; pair $I remains the boot default until health checks pass."
	say "in OpenWrt: check the LAN, radios, root password and OpenWISP management."
}

# Thor: write the factory image into rootfs (mtd $1), check it and arm its
# guarded first boot.
thor_write() {
	local image contents v
	image=$(get_image cambiumnetworks_thor-persistent-squashfs-factory.ubi) || exit 1
	contents=$(get_image cambiumnetworks_thor-persistent-squashfs-factory.ubi.contents) || exit 1
	[ -n "$(ubi_of_mtd "$1")" ] && step "ubidetach mtd$1" ubidetach -m "$1"
	step "ubiformat mtd$1 with ${image##*/}" ubiformat "$R/dev/mtd$1" -y -f "$image"
	attach "$1"
	for v in kernel rootfs rootfs_data cambium_device_data; do
		[ -n "$(vol_of "$UBI" "$v")" ] || die "the written image has no $v volume on mtd$1"
	done
	verify_factory "$UBI" "$contents"
	arm "$(thor_guarded)"
	say "guarded first boot armed: after a healthy start OpenWrt re-arms its boot; otherwise the next boot returns to the stock firmware."
	say "in OpenWrt: set a root password (passwd); cat /tmp/cambium-board-data.status should say vault"
}

# Thor from the stock firmware: install directly when it has ubiformat,
# otherwise RAM-boot the installer, in which install is run again.
install_thor() {
	local image
	layout_thor
	if have ubiformat && have ubidetach; then
		backup "$R/dev/mtd${R0}ro"
		dry_run_stop "write the persistent image over rootfs (mtd$R0) and boot it once"
		thor_write "$R0"
		return
	fi
	say "this stock firmware has no ubiformat: the Thor RAM installer writes the image instead"
	identify installer
	image=$(get_image cambiumnetworks_thor-installer-initramfs-uImage.itb) || exit 1
	backup "$R/dev/mtd${R0}ro"
	dry_run_stop "stage the installer in rootfs (mtd$R0) and boot it once"
	stage_ram "$image" "$R0"
	arm "$(thor_oneshot openwrt)"
	say "the installer boots once. In it (SSH root@AP_IP), run this script again: sh cambium-install.sh --from ... install --yes"
}

# Thor RAM installer: write the persistent image and arm its first boot.
install_thor_installer() {
	local r0
	grep -q 'ubi.mtd=' "$R/proc/cmdline" && die "this OpenWrt runs from flash, not the Thor installer in RAM"
	r0=$(mtd_idx rootfs)
	[ -n "$r0" ] || die "no rootfs partition in /proc/mtd"
	[ "$(mtd_size rootfs)" = 06000000 ] || die "rootfs is not 96 MiB"
	[ $(( $(cat "$R/sys/class/mtd/mtd$r0/flags") & 0x400 )) -ne 0 ] || die "rootfs is read-only: this is not the Thor installer"
	need ubiformat ubiattach ubidetach
	check_stock_bootcmd
	dry_run_stop "write the persistent image over rootfs (mtd$r0) and boot it once"
	thor_write "$r0"
}

cmd_install() {
	load_release
	if on_openwrt; then
		identify installer
		case "$FAMILY" in
		thor) install_thor_installer ;;
		gambit) install_gambit_installer ;;
		*) die 'run install from the stock firmware or the family RAM installer' ;;
		esac
		finish
		return
	fi
	identify persistent
	[ -n "$ptest" ] && die "--persistent-test belongs to ram"
	check_stock_bootcmd
	case "$FAMILY" in
	gambit) gambit_stage_ram installer ;;
	jaguar) install_jaguar ;;
	cheetah) install_cheetah ;;
	sage) install_sage_ab ;;
	thor) install_thor ;;
	*) die "no install procedure for family $FAMILY" ;;
	esac
	finish
}

# Determine OEM's running bank from its root argument. In the RAM installer,
# use the marker recorded and read back before the guarded RAM boot.
gambit_oem_slot() {
	local slot idx found=
	if on_openwrt; then
		getenv gambit_oem_slot
		return
	fi
	for slot in 0 1; do
		idx=$(mtd_idx rootfs$slot)
		[ -n "$idx" ] || return 1
		if grep -q "root=/dev/mtdblock$idx\([[:space:]]\|$\)" "$R/proc/cmdline"; then
			[ -z "$found" ] || return 1
			found=$slot
		fi
	done
	[ -n "$found" ] || return 1
	echo "$found"
}

# Gambit OEM U-Boot cannot boot UBI kernels. Stage RAM in the inactive OEM
# rootfs, then let the RAM installer write its 4 MiB kernel / 44 MiB UBI pair.
gambit_stage_ram() {
	local flavour=$1 image idx active target bytes padded check want got off stock slot
	need nanddump nandwrite flash_erase
	active=$(gambit_oem_slot)
	case "$active" in 0|1) ;; *) die 'cannot identify the running OEM Gambit bank' ;; esac
	target=$((1 - active)); idx=$(mtd_idx rootfs$target)
	for slot in 0 1; do
		[ "$(mtd_size linux$slot):$(mtd_size rootfs$slot)" = 00300000:02d00000 ] || die 'unexpected OEM Gambit bank geometry'
		bank_offset "$(mtd_idx linux$slot)" $((slot * 0x3000000)) linux$slot
		bank_offset "$(mtd_idx rootfs$slot)" $((slot * 0x3000000 + 0x300000)) rootfs$slot
	done
	off=$(printf '0x%08x' $((target * 0x3000000 + 0x300000)))
	stock=$(printf 'nboot 0x81000000 0 0x%08x' $((active * 0x3000000)))
	[ "$flavour" = recovery ] || identify installer
	backup "$R/dev/mtd$(mtd_idx linux$target)ro" "$R/dev/mtd${idx}ro"
	if [ "$flavour" = recovery ]; then
		image=$(get_image cambiumnetworks_e400-recovery-initramfs-kernel.bin) || exit 1
	else
		image=$(get_image cambiumnetworks_gambit-installer-initramfs-kernel.bin) || exit 1
	fi
	bytes=$(wc -c < "$image")
	[ "$bytes" -gt 64 ] && [ "$bytes" -le $((0x2b00000)) ] || die 'RAM image is empty or too large'
	[ "$(hexenc "$image" | head -c 8)" = 27051956 ] || die 'RAM image is not a uImage'
	want=$(sha256sum "$image" | cut -d' ' -f1)
	dry_run_stop "erase inactive OEM rootfs$target, stage the RAM image and boot it once"
	step "erase inactive rootfs$target" flash_erase "$R/dev/mtd$idx" 0 0
	step 'stage Gambit RAM image' nandwrite -p "$R/dev/mtd$idx" "$image"
	padded=$(( (bytes + 2047) / 2048 * 2048 ))
	check=$WORK/gambit-ram-readback
	step 'read back Gambit RAM image' nanddump -q --omitoob --bb=skipbad -l "$padded" -f "$check" "$R/dev/mtd$idx"
	got=$(head -c "$bytes" "$check" | sha256sum | cut -d' ' -f1)
	[ "$got" = "$want" ] || die 'Gambit RAM image readback mismatch'
	rm -f "$check"
	setenv_checked gambit_oem_slot "$active"
	arm "setenv bootcmd $stock; saveenv; nboot 0x83000000 0 $off"
	[ "$flavour" = recovery ] || say 'After RAM boot, run install again with the same source and --trial --backed-up --yes.'
}

install_gambit_installer() {
	local core module writer image board batch oem idx
	[ "$(cat "$R/tmp/sysinfo/board_name")" = cambiumnetworks,e400 ] || die 'not an E400 installer'
	grep -q 'ubi.mtd=' "$R/proc/cmdline" && die 'this is persistent OpenWrt: use sysupgrade, not install'
	check_stock_bootcmd
	oem=$(gambit_oem_slot)
	case "$oem" in 0|1) ;; *) die 'missing recorded OEM Gambit bank: stage the installer from OEM first' ;; esac
	# Never infer that this RAM boot proves the off-device OEM backups.
	[ -n "$backed_up" ] || die 'Gambit requires verified off-device OEM bank and environment backups; pass --backed-up once checked'
	core=$(get_image cambium-ab.sh) || exit 1
	module=$(get_image cambium-ab-gambit.sh) || exit 1
	writer=$(get_image cambium-ab-upgrade.sh) || exit 1
	# Only family modules belong in the core's cambium-ab-*.sh scan.
	# The downloaded writer matches that glob too and sources the core:
	# scanning the download folder would recurse until ash runs out of FDs.
	step 'create Gambit family module directory' mkdir -p "$WORK/ab-modules"
	step 'isolate Gambit family module' cp "$module" "$WORK/ab-modules/cambium-ab-gambit.sh"
	CAMBIUM_AB_MODULES=$WORK/ab-modules CAMBIUM_AB_LIB=$core
	. "$core"
	. "$writer"
	ab_board cambiumnetworks,e400 && [ "$(ab_dt_sku)" = "$AB_SKU" ] &&
		ab_gambit_layout || die 'the E400 SKU or 4+44 MiB installer layout does not match'
	AB_ACTIVE=$oem AB_TARGET=$((1 - oem)) AB_TARGET_PART=rootfs$((1 - oem))
	eval "AB_TARGET_MTD=\$AB_MTD$AB_TARGET"
	image=$(get_image cambiumnetworks_gambit-persistent-squashfs-sysupgrade.bin) || exit 1
	ab_image_extract "$image" || die 'invalid persistent image'
	eval "idx=\$AB_KERNEL_MTD$AB_TARGET"
	[ "$(cat "$R/sys/class/mtd/mtd$idx/ecc_strength" 2>/dev/null)" = 1 ] &&
		[ "$(cat "$R/sys/class/mtd/mtd$idx/ecc_step_size" 2>/dev/null)" = 256 ] ||
		die 'RAM installer NAND ECC is incompatible with OEM/U-Boot; boot the corrected software-Hamming installer first'
	ab_mtd_writable "$idx" && ab_mtd_writable "$AB_TARGET_MTD" || die 'boot the writable Gambit RAM installer first'
	# A marker accidentally left by an earlier conversion must never make the
	# boot guard treat the preserved OEM bank as an OpenWrt bank.
	[ -z "$(ab_getenv gambit_ab_version)" ] || die 'Gambit already has A/B metadata; use its upgrade/recovery path'
	dry_run_stop "write and verify only linux$AB_TARGET/rootfs$AB_TARGET and arm their guarded first boot"
	ab_gambit_write_target || die "Gambit inactive-bank write or readback failed; OEM bank $oem is unchanged"
	sync
	ab_setenv bootcmd "$(ab_gambit_guarded_command "$AB_TARGET")" || die 'cannot arm guarded persistent boot'
	say "Persistent inactive bank $AB_TARGET verified and armed. The shared health guard will rearm it; failed boots return to OEM bank $oem."
}

# Installed OpenWrt that still has the stock firmware in its other slot:
# make the stock firmware the default again, e.g. to reinstall with the
# current layout. Refused once both banks run OpenWrt.
cmd_stock() {
	local board env want fallback running
	on_openwrt || die "stock runs in an installed OpenWrt; the stock firmware is already running"
	grep -q 'ubi.mtd=' "$R/proc/cmdline" || die "this OpenWrt does not run from flash"
	need fw_printenv fw_setenv
	board=$(cat "$R/tmp/sysinfo/board_name" 2>/dev/null)
	case "$board" in
	cambiumnetworks,e400)
		env=gambit fallback=$(getenv gambit_oem_slot)
		case "$fallback" in 0|1) want=$(printf 'nboot 0x81000000 0 0x%08x' $((fallback * 0x3000000))) ;; *) die 'no recorded Gambit OEM fallback bank' ;; esac
		;;
	cambiumnetworks,xv3-8) env=thor want='aq_load_fw&&bootipq' ;;
	cambiumnetworks,xv2-2*|cambiumnetworks,xe3-4*) env=jaguar want=bootipq ;;
	cambiumnetworks,xv2-21x|cambiumnetworks,xv2-22h|cambiumnetworks,xv2-23t) env=cheetah want=bootipq ;;
	cambium,e410|cambiumnetworks,e410|cambiumnetworks,e410b|cambiumnetworks,e510) env=sage want=bootipq ;;
	*) die "$board is not a Cambium family this script knows" ;;
	esac
	if [ "$env" = sage ]; then
		fallback=$(getenv sage_oem_fallback)
		case "$fallback" in 0|1) ;; *) die "there is no recorded OEM fallback pair on this Sage AP" ;; esac
		running=$(sed -n 's/.*root=ubi0:rootfs\([01]\).*/\1/p' "$R/proc/cmdline")
		[ "$running" = "$((1 - fallback))" ] ||
			die "running Sage pair $running does not match OEM fallback pair $fallback"
		getenv bootcmd > /dev/null || die "cannot read the U-Boot environment (fw_printenv failed)"
		dry_run_stop "make OEM pair $fallback the default boot"
		setenv_checked bootcmd bootipq
		setenv_checked image "$fallback"
		say "OEM pair $fallback is the default boot again; the OpenWrt pair is untouched."
		finish
		return
	fi
	[ "$(getenv "${env}_ab_version")" = 1 ] &&
		die "both firmware banks run OpenWrt (converted to A/B): there is no stock firmware to return to"
	getenv bootcmd > /dev/null || die "cannot read the U-Boot environment (fw_printenv failed)"
	dry_run_stop "make the stock firmware the default boot"
	# The default bootcmd first: U-Boot accepts it with or without the marker.
	setenv_checked bootcmd "$want"
	if [ "$env" != gambit ]; then
		step "fw_setenv changing_bootcmd" fw_setenv changing_bootcmd
		[ -z "$(getenv changing_bootcmd)" ] || die "changing_bootcmd did not clear"
	fi
	say "the stock firmware is the default boot again; this OpenWrt stays in its slot until it is overwritten."
	say "from the stock firmware: sh cambium-install.sh --from ... install"
	finish
}

# Installed OpenWrt with A/B banks: sysupgrade runs the upgrade scripts of
# the running system, not of the new image, so a fixed writer must be
# installed on the running system before it can be used. Installs the
# release's cambium-ab core, writer and family module.
cmd_update_upgrader() {
	local f dst new n=0 old=$WORK/upgrader-before
	on_openwrt || die "update-upgrader runs in an installed OpenWrt"
	grep -q 'ubi.mtd=' "$R/proc/cmdline" || die "this OpenWrt does not run from flash"
	[ -f "$R/lib/upgrade/cambium-ab.sh" ] ||
		die "this image predates the shared A/B scripts (cambium-ab): upgrade it with sysupgrade instead (a Jaguar from snapshot 2026.09.24 needs a reinstall from the stock firmware)"
	load_release
	identify recovery
	# Each entry: the release file's name suffix, then where it is installed.
	set -- "cambium-ab.sh:/lib/functions/cambium-ab.sh" \
		"cambium-ab-upgrade.sh:/lib/upgrade/cambium-ab.sh" \
		"cambium-ab-$FAMILY.sh:/lib/functions/cambium-ab-$FAMILY.sh"
	if [ "$FAMILY" = sage ]; then
		need ubirsvol ubimkvol
		set -- "$@" "cambium-sage.sh:/lib/functions/cambium-sage.sh"
	fi
	for f; do
		new=$(get_image "${f%%:*}") || exit 1
		step "syntax check of ${new##*/}" sh -n "$new"
		cmp -s "$new" "$R${f#*:}" || n=$((n + 1))
	done
	if [ "$n" = 0 ]; then
		say "the running upgrade scripts are already the release's"
		return 0
	fi
	dry_run_stop "replace the running A/B scripts with the release's copies (the old ones are kept in $old)"
	mkdir -p "$old"
	for f; do
		dst=$R${f#*:}
		[ -f "$dst" ] && step "keep the old ${f#*:}" cp "$dst" "$old/${f%%:*}"
		step "install ${f#*:}" cp "$WORK/$(asset "${f%%:*}")" "$dst"
	done
	(board_name() { cat "$R/tmp/sysinfo/board_name"; }
	 CAMBIUM_SAGE_LIB=$R/lib/functions/cambium-sage.sh CAMBIUM_AB_LIB=$R/lib/functions/cambium-ab.sh CAMBIUM_AB_MODULES=$R/lib/functions \
		. "$R/lib/upgrade/cambium-ab.sh" && command -v ab_ubi_node && command -v ab_step &&
		command -v cambium_ab_do_upgrade && ab_board "$(board_name)") > /dev/null 2>&1 || {
		for f; do [ -f "$old/${f%%:*}" ] && cp "$old/${f%%:*}" "$R${f#*:}"; done
		die "the installed scripts do not load; the old ones are restored"
	}
	say "the running system now uses the release's A/B scripts (old copies in $old)."
	say "next: sysupgrade -T IMAGE, then sysupgrade [-n] IMAGE"
}

[ "$(id -u 2>/dev/null)" = 0 ] || [ -n "$R" ] || die "run this as root"
case "$cmd" in
ram) cmd_ram ;;
install) cmd_install ;;
stock) cmd_stock ;;
update-upgrader) cmd_update_upgrader ;;
esac
