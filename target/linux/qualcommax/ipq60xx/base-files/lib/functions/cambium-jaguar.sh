#!/bin/sh
# Cambium Jaguar family (IPQ6018) board table, A/B identity preflight and
# U-Boot boot commands. Shared by sysupgrade, the boot guard, the device-data
# vault and the one-time conversion. Callers provide board_name().
#
# Each Jaguar has two NAND firmware banks, rootfs (slot 0) and rootfs_1
# (slot 1), whose size depends on the NAND: two 96 MiB banks on the 256 MiB
# models (captured on the XV2-2T1, OEM 7.2-r1) and two 52 MiB banks on the
# XV2-2's 128 MiB NAND. The preflight re-checks the layout on every unit
# instead of assuming it.
#
# Test hooks: JAGUAR_PROC_MTD, JAGUAR_CMDLINE, JAGUAR_DT, JAGUAR_UBI_SYS,
# JAGUAR_MTD_SYS.

JAGUAR_BANK_ERASE=00020000
JAGUAR_LEB=126976

# jaguar_board BOARD: set JAGUAR_MODEL, JAGUAR_SKU (8 hex digits, as read
# from the device tree), JAGUAR_FIT, JAGUAR_QUALIFIED (hardware-tested) and
# the bank layout: JAGUAR_BANK_SIZE (as in /proc/mtd), JAGUAR_SLOT1_OFFSET,
# JAGUAR_BANK_LEBS (usable LEBs: the bank's PEBs less UBI's bad-block
# reserve of 20 per 1024 PEBs of the whole NAND and 4 PEBs for the volume
# table and wear levelling) and the names of the NVRAM and crash-log
# partitions, which must stay read-only.
jaguar_board() {
	JAGUAR_QUALIFIED=0
	JAGUAR_BANK_SIZE=06000000
	JAGUAR_SLOT1_OFFSET=0x6000000
	JAGUAR_BANK_LEBS=724
	JAGUAR_NVRAM=NVRAM
	JAGUAR_CRASHLOG=crashLog
	case "$1" in
	cambiumnetworks,xv2-2)
		# 128 MiB Winbond NAND: 416-PEB banks, 20 reserved + 4.
		JAGUAR_MODEL=XV2-2; JAGUAR_SKU=00000014; JAGUAR_FIT=config@cp01-c1
		JAGUAR_BANK_SIZE=03400000
		JAGUAR_SLOT1_OFFSET=0x3400000
		JAGUAR_BANK_LEBS=392
		JAGUAR_NVRAM=0:NVRAM
		JAGUAR_CRASHLOG=crashlog
		;;
	cambiumnetworks,xv2-2t0) JAGUAR_MODEL=XV2-2T0; JAGUAR_SKU=00000016; JAGUAR_FIT=config@cp01-c1-1 ;;
	cambiumnetworks,xv2-2t1) JAGUAR_MODEL=XV2-2T1; JAGUAR_SKU=0000001f; JAGUAR_FIT=config@cp01-c1-2; JAGUAR_QUALIFIED=1 ;;
	cambiumnetworks,xe3-4) JAGUAR_MODEL=XE3-4; JAGUAR_SKU=00000020; JAGUAR_FIT=config@cp01-c3-xv3-4 ;;
	cambiumnetworks,xe3-4tn) JAGUAR_MODEL=XE3-4TN; JAGUAR_SKU=00000021; JAGUAR_FIT=config@cp01-c3-2 ;;
	*) return 1 ;;
	esac
}

# True when this system runs a Cambium Jaguar family image. Upstream
# OpenWrt's own cambiumnetworks,xe3-4 image shares the XE3-4 board name but
# has no cambium-platform node, and keeps its upstream upgrade path.
jaguar_family() {
	jaguar_board "$(board_name)" &&
		[ -e "${JAGUAR_DT:-/proc/device-tree}/cambium-platform/board-sku" ]
}

jaguar_dt_sku() {
	hexdump -v -e '1/1 "%02x"' "${JAGUAR_DT:-/proc/device-tree}/cambium-platform/board-sku"
}

jaguar_mtd_index() {
	awk -v wanted="\"$1\"" '$4 == wanted { sub(/^mtd/, "", $1); sub(/:$/, "", $1); print $1 }' \
		"${JAGUAR_PROC_MTD:-/proc/mtd}"
}

jaguar_mtd_geometry() {
	awk -v wanted="\"$1\"" '$4 == wanted { print $2, $3 }' "${JAGUAR_PROC_MTD:-/proc/mtd}"
}

jaguar_mtd_writable() {
	local flags
	flags=$(cat "${JAGUAR_MTD_SYS:-/sys/class/mtd}/mtd$1/flags") || return 1
	[ $(( flags & 0x400 )) -ne 0 ]
}

jaguar_bank_name() {
	case "$1" in
	0) echo rootfs ;;
	1) echo rootfs_1 ;;
	*) return 1 ;;
	esac
}

# The slot named by ubi.mtd= on the kernel command line.
jaguar_running_slot() {
	local arg found slot=
	for arg in $(cat "${JAGUAR_CMDLINE:-/proc/cmdline}"); do
		case "$arg" in
		ubi.mtd=rootfs) found=0 ;;
		ubi.mtd=rootfs_1) found=1 ;;
		ubi.mtd=*) echo "Jaguar: unexpected $arg" >&2; return 1 ;;
		*) continue ;;
		esac
		[ -z "$slot" ] || [ "$slot" = "$found" ] || {
			echo 'Jaguar: conflicting ubi.mtd arguments' >&2
			return 1
		}
		slot=$found
	done
	[ -n "$slot" ] || { echo 'Jaguar: no ubi.mtd slot' >&2; return 1; }
	echo "$slot"
}

# The UBI device attached to MTD number $1.
jaguar_ubi_for_mtd() {
	local dev
	for dev in "${JAGUAR_UBI_SYS:-/sys/class/ubi}"/ubi[0-9]*; do
		case "${dev##*/}" in *_*) continue ;; esac
		[ -f "$dev/mtd_num" ] || continue
		[ "$(cat "$dev/mtd_num")" = "$1" ] && { echo "${dev##*/}"; return 0; }
	done
	return 1
}

# Make sure /dev/$1 exists for a UBI device or volume (ubiN or ubiN_M).
# Sysupgrade stage 2 runs without procd's hotplug handling, so a device
# attached or a volume created there gets no node by itself (nand.sh's
# ubi_mknod exists for the same reason).
jaguar_ubi_node() {
	local node=${JAGUAR_DEV:-/dev}/$1 devid
	[ -e "$node" ] && return 0
	devid=$(cat "${JAGUAR_UBI_SYS:-/sys/class/ubi}/$1/dev") || return 1
	mknod "$node" c "${devid%%:*}" "${devid##*:}"
}

# The volume node (ubiN_M) named $2 on UBI device $1.
jaguar_ubi_volume() {
	local vol
	for vol in "${JAGUAR_UBI_SYS:-/sys/class/ubi}/$1"_*; do
		[ -f "$vol/name" ] || continue
		[ "$(cat "$vol/name")" = "$2" ] && { echo "${vol##*/}"; return 0; }
	done
	return 1
}

# Read-only preflight. On success sets JAGUAR_BOARD and the board table
# values, JAGUAR_ACTIVE / JAGUAR_TARGET (slots), JAGUAR_ACTIVE_MTD /
# JAGUAR_TARGET_MTD, JAGUAR_TARGET_PART and JAGUAR_ACTIVE_UBI. Refuses an
# unknown board or SKU, a changed bank layout, a command line that disagrees
# with the attached UBI device, and any writable calibration or log partition.
jaguar_identity() {
	local board sku name idx slot flags
	board=$(board_name)
	jaguar_board "$board" || { echo "Jaguar: unknown board $board" >&2; return 1; }
	sku=$(jaguar_dt_sku) || { echo 'Jaguar: no board-sku in the device tree' >&2; return 1; }
	[ "$sku" = "$JAGUAR_SKU" ] || {
		echo "Jaguar: $board has board-sku $sku, expected $JAGUAR_SKU" >&2
		return 1
	}
	for slot in 0 1; do
		name=$(jaguar_bank_name "$slot")
		idx=$(jaguar_mtd_index "$name")
		case "$idx" in
		''|*[!0-9]*) echo "Jaguar: missing or duplicate $name" >&2; return 1 ;;
		esac
		[ "$(jaguar_mtd_geometry "$name")" = "$JAGUAR_BANK_SIZE $JAGUAR_BANK_ERASE" ] || {
			echo "Jaguar: unexpected $name geometry: $(jaguar_mtd_geometry "$name")" >&2
			return 1
		}
		eval "JAGUAR_MTD$slot=$idx"
	done
	slot=$(jaguar_running_slot) || return 1
	JAGUAR_ACTIVE=$slot
	JAGUAR_TARGET=$((1 - slot))
	eval "JAGUAR_ACTIVE_MTD=\$JAGUAR_MTD$JAGUAR_ACTIVE"
	eval "JAGUAR_TARGET_MTD=\$JAGUAR_MTD$JAGUAR_TARGET"
	JAGUAR_TARGET_PART=$(jaguar_bank_name "$JAGUAR_TARGET")
	JAGUAR_ACTIVE_UBI=$(jaguar_ubi_for_mtd "$JAGUAR_ACTIVE_MTD") || {
		echo 'Jaguar: no UBI device is attached to the command-line active slot' >&2
		return 1
	}
	jaguar_ubi_volume "$JAGUAR_ACTIVE_UBI" kernel >/dev/null &&
		jaguar_ubi_volume "$JAGUAR_ACTIVE_UBI" rootfs >/dev/null || {
		echo 'Jaguar: the active slot lacks kernel/rootfs volumes' >&2
		return 1
	}
	for name in "$JAGUAR_NVRAM" "$JAGUAR_CRASHLOG" 0:ART; do
		idx=$(jaguar_mtd_index "$name")
		[ -n "$idx" ] || { echo "Jaguar: missing protected $name" >&2; return 1; }
		flags=$(cat "${JAGUAR_MTD_SYS:-/sys/class/mtd}/mtd$idx/flags") || return 1
		[ $(( flags & 0x400 )) -eq 0 ] || {
			echo "Jaguar: protected $name is writable" >&2
			return 1
		}
	done
	JAGUAR_BOARD=$board
}

# The bank size as U-Boot writes it, e.g. 0x6000000.
jaguar_bank_hex() {
	printf '0x%x\n' $((0x$JAGUAR_BANK_SIZE))
}

# U-Boot command booting slot $1 with this board's FIT configuration. It
# matches the validated slot-0 guard command apart from the bank.
jaguar_boot_command() {
	local part offset
	[ -n "${JAGUAR_FIT:-}" ] || { echo 'Jaguar: FIT configuration not selected' >&2; return 1; }
	case "$1" in
	0) part=rootfs; offset=0x0 ;;
	1) part=rootfs_1; offset=$JAGUAR_SLOT1_OFFSET ;;
	*) echo "Jaguar: invalid slot $1" >&2; return 1 ;;
	esac
	printf 'nand device 0 && setenv mtdids nand0=nand0 && setenv mtdparts "mtdparts=nand0:%s@%s(fs)" && ubi part fs && ubi read 0x60000000 kernel && setenv bootargs "console=ttyMSM0,115200n8 cnss2.bdf_pci0=0xab ubi.mtd=%s root=/dev/ubiblock0_1 rootfstype=squashfs rootwait swiotlb=1" && bootm 0x60000000#%s\n' \
		"$(jaguar_bank_hex)" "$offset" "$part" "$JAGUAR_FIT"
}

# Guarded one-shot for the one-OEM/one-OpenWrt state, booting OpenWrt slot
# $1 after restoring the stock default. Slot 0 is the command validated on
# the XV2-2T1; slot 1 uses the "(fs)" / "ubi part fs" form that booted the
# XV2-2 from its slot 1.
jaguar_guarded_command() {
	local mtdparts part
	case "$1" in
	0) mtdparts="$(jaguar_bank_hex)@0x0(rootfs)"; part=rootfs ;;
	1) mtdparts="$(jaguar_bank_hex)@$JAGUAR_SLOT1_OFFSET(fs)"; part=fs ;;
	*) echo "Jaguar: invalid slot $1" >&2; return 1 ;;
	esac
	echo "setenv bootcmd bootipq; setenv changing_bootcmd; saveenv; nand device 0 && setenv mtdids nand0=nand0 && setenv mtdparts \"mtdparts=nand0:$mtdparts\" && ubi part $part && ubi read 0x60000000 kernel && setenv bootargs \"console=ttyMSM0,115200n8 cnss2.bdf_pci0=0xab ubi.mtd=$(jaguar_bank_name "$1") root=/dev/ubiblock0_1 rootfstype=squashfs rootwait swiotlb=1\" && bootm 0x60000000#$JAGUAR_FIT; reset"
}

# Stable boot: slot $1, then slot $2 if bootm returns.
jaguar_stable_command() {
	case "$1:$2" in
	0:1|1:0) echo "run jaguar_boot$1; run jaguar_boot$2" ;;
	*) echo 'Jaguar: a stable command needs distinct slots 0 and 1' >&2; return 1 ;;
	esac
}

# One-shot trial of slot $2 from confirmed slot $1. Its first durable step
# restores the stable old-bank default, so a hung new kernel returns to the
# old bank on the next power cycle; bootm returning tries the old bank now.
# Only named variables are used, so no nested quoting reaches U-Boot.
jaguar_trial_command() {
	jaguar_stable_command "$1" "$2" >/dev/null || return 1
	echo "setenv bootcmd run jaguar_stable$1; setenv image $1; setenv jaguar_ab_state trial-started; saveenv; run jaguar_boot$2; run jaguar_boot$1"
}

# fw_printenv/fw_setenv against the verified 64 KiB 0:APPSBLENV mapping.
jaguar_env_config() {
	local idx
	[ -z "${JAGUAR_ENV_CONFIG:-}" ] || return 0
	idx=$(jaguar_mtd_index 0:APPSBLENV)
	[ -n "$idx" ] || { echo 'Jaguar: no 0:APPSBLENV partition' >&2; return 1; }
	[ "$(jaguar_mtd_geometry 0:APPSBLENV | cut -d' ' -f1)" = 00010000 ] || {
		echo 'Jaguar: unexpected 0:APPSBLENV size' >&2
		return 1
	}
	JAGUAR_ENV_CONFIG=/tmp/jaguar-fw_env.config
	printf '/dev/mtd%s 0x0 0x00010000 0x00010000 1\n' "$idx" > "$JAGUAR_ENV_CONFIG"
}

jaguar_getenv() {
	jaguar_env_config && fw_printenv -c "$JAGUAR_ENV_CONFIG" -n "$1" 2>/dev/null
}

# jaguar_setenv NAME [VALUE]: write one variable and read it back.
jaguar_setenv() {
	jaguar_env_config || return 1
	if [ $# -ge 2 ]; then
		fw_setenv -c "$JAGUAR_ENV_CONFIG" "$1" "$2" || return 1
		[ "$(jaguar_getenv "$1")" = "$2" ]
	else
		fw_setenv -c "$JAGUAR_ENV_CONFIG" "$1" || return 1
		[ -z "$(jaguar_getenv "$1")" ]
	fi
}

# jaguar_setenv_batch FILE: one environment write from "name value" lines,
# then read every value back.
jaguar_setenv_batch() {
	local name value
	jaguar_env_config || return 1
	fw_setenv -c "$JAGUAR_ENV_CONFIG" -s "$1" || return 1
	while read -r name value; do
		[ "$(jaguar_getenv "$name")" = "$value" ] || {
			echo "Jaguar: environment readback failed for $name" >&2
			return 1
		}
	done < "$1"
}

# True once jaguar-ab-convert has made both banks OpenWrt banks.
jaguar_ab_converted() {
	[ "$(jaguar_getenv jaguar_ab_version)" = 1 ]
}

# Install the boot commands for both slots. changing_bootcmd must already be
# saved as its own write: this U-Boot discards an environment whose bootcmd
# differs from the default while the marker is absent.
jaguar_write_boot_vars() {
	local batch=/tmp/jaguar-env.$$ rc=0
	[ "$(jaguar_getenv changing_bootcmd)" = 1 ] || {
		echo 'Jaguar: changing_bootcmd is not saved' >&2
		return 1
	}
	{
		echo "jaguar_boot0 $(jaguar_boot_command 0)"
		echo "jaguar_boot1 $(jaguar_boot_command 1)"
		echo "jaguar_stable0 $(jaguar_stable_command 0 1)"
		echo "jaguar_stable1 $(jaguar_stable_command 1 0)"
	} > "$batch" || rc=1
	[ "$rc" = 0 ] && { jaguar_setenv_batch "$batch" || rc=1; }
	rm -f "$batch"
	return "$rc"
}
