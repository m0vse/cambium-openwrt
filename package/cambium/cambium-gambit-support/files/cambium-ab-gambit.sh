#!/bin/sh
# E400: raw nboot uImage kernels and independent UBI root/overlay banks.
# Shared cambium-ab owns the trial, health checks, rollback and confirmation.

case " ${AB_FAMILIES:-} " in
*" gambit "*) ;;
*) AB_FAMILIES="${AB_FAMILIES:+$AB_FAMILIES }gambit" ;;
esac

ab_gambit_board() {
	local oem
	[ "$1" = cambiumnetworks,e400 ] || return 1
	AB_NAME=Gambit AB_MODEL=E400 AB_SKU=00000006 AB_ENV=gambit
	AB_FIT=uimage AB_IMAGE_DIR=sysupgrade-cambiumnetworks_gambit-persistent
	AB_ENV_PART=u-boot-env AB_MARKER=0 AB_QUALIFIED=1
	AB_BANK_SIZE=02c00000 AB_BANK_LEBS=328 AB_SLOT1_OFFSET=0x3000000
	AB_STOCK_BOOTCMD='nboot 0x81000000 0 0x00000000'
	oem=$(ab_getenv gambit_oem_slot)
	[ "$oem" != 1 ] || AB_STOCK_BOOTCMD='nboot 0x81000000 0 0x03000000'
	AB_PROTECTED='u-boot CrashLog mfginfo ART nvram'
	AB_LAN='br-lan.1 br-lan' AB_RADIOS=2
}

ab_gambit_boot_command() {
	local offset
	case "$1" in 0) offset=0x00000000 ;; 1) offset=0x03000000 ;; *) return 1 ;; esac
	# 0x81000000 overlaps an expanded initramfs. Keep the proven safe address.
	echo "setenv bootargs console=ttyS0,115200n8 ubi.mtd=rootfs$1 root=/dev/ubiblock0_1 rootfstype=squashfs init=/sbin/init panic=5 mem=128M; nboot 0x83000000 0 $offset"
}

ab_gambit_guarded_command() {
	# First installation preserves whichever bank runs OEM. Save its default before changing
	# bootargs in RAM, so a failed OpenWrt boot still has OEM's YAFFS arguments.
	local oem
	oem=$(ab_getenv gambit_oem_slot)
	case "$oem" in 0|1) ;; *) return 1 ;; esac
	[ "$1" = "$((1 - oem))" ] || return 1
	echo "setenv bootcmd $AB_STOCK_BOOTCMD; saveenv; $(ab_gambit_boot_command "$1")"
}

ab_gambit_running_slot() {
	local arg slot=
	for arg in $(cat "${AB_CMDLINE:-/proc/cmdline}"); do
		case "$arg" in
		ubi.mtd=rootfs0) [ -z "$slot" ] || return 1; slot=0 ;;
		ubi.mtd=rootfs1) [ -z "$slot" ] || return 1; slot=1 ;;
		ubi.mtd=*) return 1 ;;
		esac
	done
	[ -n "$slot" ] || return 1
	echo "$slot"
}

# Layout checks are also used by the RAM installer before any flash write.
ab_gambit_layout() {
	local slot name idx offset expected flags
	for slot in 0 1; do
		for name in linux$slot rootfs$slot; do
			idx=$(ab_mtd_index "$name")
			case "$idx" in ''|*[!0-9]*) return 1 ;; esac
			case "$name" in
			linux*) expected='00400000 00020000'; offset=$((slot * 0x3000000)) ;;
			rootfs*) expected='02c00000 00020000'; offset=$((slot * 0x3000000 + 0x400000)) ;;
			esac
			[ "$(ab_mtd_geometry "$name")" = "$expected" ] || return 1
			if [ -f "${AB_MTD_SYS:-/sys/class/mtd}/mtd$idx/offset" ]; then
				[ "$(cat "${AB_MTD_SYS:-/sys/class/mtd}/mtd$idx/offset")" = "$offset" ] || return 1
			fi
			case "$name" in linux*) eval "AB_KERNEL_MTD$slot=$idx" ;; rootfs*) eval "AB_MTD$slot=$idx" ;; esac
		done
	done
	for name in $AB_PROTECTED; do
		idx=$(ab_mtd_index "$name")
		case "$idx" in ''|*[!0-9]*) return 1 ;; esac
		flags=$(cat "${AB_MTD_SYS:-/sys/class/mtd}/mtd$idx/flags") || return 1
		[ $((flags & 0x400)) -eq 0 ] || return 1
	done
}

ab_gambit_identity() {
	ab_gambit_layout || return 1
	AB_ACTIVE=$(ab_gambit_running_slot) || return 1
	AB_TARGET=$((1 - AB_ACTIVE))
	eval "AB_ACTIVE_MTD=\$AB_MTD$AB_ACTIVE"
	eval "AB_TARGET_MTD=\$AB_MTD$AB_TARGET"
	AB_TARGET_PART=rootfs$AB_TARGET
	AB_ACTIVE_UBI=$(ab_ubi_for_mtd "$AB_ACTIVE_MTD") || return 1
	[ "$(ab_ubi_volume "$AB_ACTIVE_UBI" rootfs)" = "${AB_ACTIVE_UBI}_1" ] &&
		[ "$(ab_ubi_volume "$AB_ACTIVE_UBI" rootfs_data)" = "${AB_ACTIVE_UBI}_2" ]
}

ab_gambit_uimage_size() {
	local size
	size=$(hexdump -s 12 -n 4 -v -e '4/1 "%02x"' "$1") || return 1
	[ "${#size}" = 8 ] || return 1
	echo $((0x$size + 64))
}

ab_gambit_check_kernel() {
	[ "$(hexdump -n 4 -v -e '4/1 "%02x"' "$1")" = 27051956 ] &&
		[ "$(hexdump -s 28 -n 4 -v -e '4/1 "%02x"' "$1")" = 05050203 ] &&
		[ "$(wc -c < "$1")" -eq "$(ab_gambit_uimage_size "$1")" ] || {
		ab_fail 'E400 needs a complete Linux/MIPS/kernel/LZMA uImage'
		return 1
	}
}

ab_gambit_image_fits() {
	local idx bad=2
	eval "idx=\$AB_KERNEL_MTD$AB_TARGET"
	if [ -f "${AB_MTD_SYS:-/sys/class/mtd}/mtd$idx/bad_blocks" ]; then
		bad=$(cat "${AB_MTD_SYS:-/sys/class/mtd}/mtd$idx/bad_blocks") || return 1
		bad=$((bad + 2))
	fi
	[ "$1" -le $((0x400000 - bad * 0x20000)) ] ||
		ab_fail 'kernel exceeds the 4 MiB partition with bad-block reserve' || return 1
	[ $(( $(ab_lebs "$2") + AB_MIN_DATA_LEBS )) -le "$AB_BANK_LEBS" ] ||
		ab_fail 'rootfs exceeds the 44 MiB bank with its writable overlay' || return 1
}

ab_gambit_write_target() {
	AB_STEP_ERROR=
	ab_gambit_write_target_inner || {
		ab_record_failure write-failed "cannot write and verify Gambit slot $AB_TARGET"
		return 1
	}
}

ab_gambit_write_target_inner() {
	local dev=${AB_DEV:-/dev} idx ubi padded check=${AB_WORK:-/tmp/cambium-ab-upgrade}/kernel-readback
	case "$AB_ACTIVE:$AB_TARGET" in 0:1|1:0) ;; *) return 1 ;; esac
	ab_gambit_layout && ab_gambit_check_kernel "$AB_KERNEL" &&
		ab_gambit_image_fits "$AB_KERNEL_SIZE" "$AB_ROOT_SIZE" || return 1
	eval "idx=\$AB_KERNEL_MTD$AB_TARGET"
	local rootidx
	eval "rootidx=\$AB_MTD$AB_TARGET"
	[ "$AB_TARGET_MTD" = "$rootidx" ] || return 1
	ab_mtd_writable "$idx" && ab_mtd_writable "$AB_TARGET_MTD" || return 1
	# Reject a mounted/attached target rather than detaching a live filesystem.
	! ab_ubi_for_mtd "$AB_TARGET_MTD" >/dev/null || return 1
	[ "$(head -c 4 "$AB_ROOT")" = hsqs ] || return 1
	ab_step "erase linux$AB_TARGET" flash_erase "$dev/mtd$idx" 0 0 &&
		ab_step "write linux$AB_TARGET" nandwrite -p "$dev/mtd$idx" "$AB_KERNEL" || return 1
	padded=$(( (AB_KERNEL_SIZE + 2047) / 2048 * 2048 ))
	ab_step 'read back raw kernel' nanddump -q --omitoob --bb=skipbad -l "$padded" -f "$check" "$dev/mtd$idx" &&
		ab_verify_volume "$check" "$AB_KERNEL" "$AB_KERNEL_SIZE" || return 1
	rm -f "$check"
	ab_step "format rootfs$AB_TARGET" ubiformat "$dev/mtd$AB_TARGET_MTD" -y -q &&
		ab_step "attach rootfs$AB_TARGET" ubiattach -m "$AB_TARGET_MTD" || return 1
	ubi=$(ab_ubi_for_mtd "$AB_TARGET_MTD") || return 1
	AB_TARGET_UBI=$ubi
	ab_step 'create UBI node' ab_ubi_node "$ubi" &&
		ab_step 'create rootfs' ubimkvol "$dev/$ubi" -n 1 -N rootfs -s "$AB_ROOT_SIZE" &&
		ab_step 'create rootfs node' ab_ubi_node "${ubi}_1" &&
		ab_step 'write rootfs' ubiupdatevol "$dev/${ubi}_1" "$AB_ROOT" &&
		ab_verify_volume "$dev/${ubi}_1" "$AB_ROOT" "$AB_ROOT_SIZE" || return 1
	ab_step 'create overlay' ubimkvol "$dev/$ubi" -n 2 -N rootfs_data -m &&
		ab_step 'create overlay node' ab_ubi_node "${ubi}_2" || return 1
	[ "$(cat "${AB_UBI_SYS:-/sys/class/ubi}/${ubi}_2/data_bytes")" -ge $((AB_MIN_DATA_LEBS * AB_LEB)) ] || return 1
	if [ -n "${UPGRADE_BACKUP:-}" ]; then
		CI_UBIPART=$AB_TARGET_PART nand_restore_config "$UPGRADE_BACKUP" || return 1
	fi
}

ab_gambit_root_healthy() {
	[ -e "${AB_DEV:-/dev}/ubiblock${AB_ACTIVE_UBI#ubi}_1" ] &&
		awk '$2 == "/rom" && $3 == "squashfs" { rom=1 }
		$2 == "/overlay" && $3 == "ubifs" && $4 ~ /^rw/ { data=1 }
		$2 == "/" && $3 == "overlay" && $4 ~ /^rw/ { merged=1 }
		END { exit !(rom && data && merged) }' "${AB_PROC_MOUNTS:-/proc/mounts}"
}

# OEM U-Boot increments this on every boot (limit eight). Clear it only after
# the same root, networking and radio checks used to confirm other families.
ab_gambit_healthy_boot() {
	[ "$(ab_getenv bootcount)" = 0 ] || ab_setenv bootcount 0
}

# Conversion's verified backup must cover the complete 48 MiB OEM bank,
# not just its rootfs partition. This is corrected-ECC data without OOB.
ab_gambit_oem_hash() {
	local idx dev=${AB_DEV:-/dev}
	eval "idx=\$AB_KERNEL_MTD$AB_TARGET"
	# Avoid a pipeline which could accept a hash after a failed flash read.
	local bank=${AB_CONVERT_BANK:-/tmp/cambium-gambit-oem-bank}
	dd if="$dev/mtd$idx" of="$bank" bs=131072 &&
		dd if="$dev/mtd$AB_TARGET_MTD" bs=131072 >> "$bank" || { rm -f "$bank"; return 1; }
	[ "$(wc -c < "$bank")" -eq $((0x3000000)) ] || { rm -f "$bank"; return 1; }
	sha256sum < "$bank" | cut -d' ' -f1
	rm -f "$bank"
}

ab_gambit_convert_target() {
	local idx full rootvol
	AB_WORK=$(mktemp -d /tmp/cambium-gambit-convert.XXXXXX) || return 1
	eval "idx=\$AB_KERNEL_MTD$AB_ACTIVE"
	full=$AB_WORK/raw-kernel
	nanddump -q --omitoob --bb=skipbad -l $((0x400000)) -f "$full" "${AB_DEV:-/dev}/mtd$idx" || return 1
	AB_KERNEL_SIZE=$(ab_gambit_uimage_size "$full") || return 1
	AB_KERNEL=$AB_WORK/kernel AB_ROOT=$AB_WORK/root
	head -c "$AB_KERNEL_SIZE" "$full" > "$AB_KERNEL" || return 1
	rm -f "$full"
	rootvol=$(ab_ubi_volume "$AB_ACTIVE_UBI" rootfs) || return 1
	cat "${AB_DEV:-/dev}/$rootvol" > "$AB_ROOT" || return 1
	AB_ROOT_SIZE=$(wc -c < "$AB_ROOT")
	ab_gambit_write_target || return 1
	rm -rf "$AB_WORK"
}
