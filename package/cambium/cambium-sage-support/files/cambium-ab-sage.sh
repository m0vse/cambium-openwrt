#!/bin/sh
# Cambium A/B module for the Sage family (IPQ4019). See cambium-ab.sh.
#
# Sage keeps both slots in one UBI device on the SPI-NAND "fs" partition, as
# the stock firmware laid it out: volume pairs linux0/rootfs0 and
# linux1/rootfs1, each root a writable UBIFS (no overlay). A slot is written
# with ubiupdatevol and never formatted, and the configuration is carried
# into the new root as sysupgrade.tgz. This U-Boot has no changing_bootcmd
# marker. The board table, boot commands and running slot come from
# cambium-sage.sh, which the earlier Sage upgrade code also used.
#

. "${CAMBIUM_SAGE_LIB:-/lib/functions/cambium-sage.sh}"

case " ${AB_FAMILIES:-} " in
*" sage "*) ;;
*) AB_FAMILIES="${AB_FAMILIES:+$AB_FAMILIES }sage" ;;
esac

# Factory product ID is read only. A legacy B-suffix unit trials config@17
# on its next upgrade while retaining the confirmed E410 boot command.
ab_sage_legacy_b() {
	local idx
	idx=$(ab_mtd_index mfginfo)
	case "$idx" in ''|*[!0-9]*) return 1 ;; esac
	[ -r "${AB_DEV:-/dev}/mtd${idx}ro" ] || return 1
	tr '\000' '\n' < "${AB_DEV:-/dev}/mtd${idx}ro" | grep -Fq 'PL-E410XXXB-'
}

ab_sage_board() {
	cambium_sage_board "$1" || return 1
	AB_SAGE_LEGACY_B=0
	case "$1" in
	cambium,e410|cambiumnetworks,e410)
		if ab_sage_legacy_b; then
			AB_SAGE_LEGACY_B=1
			SAGE_MODEL=E410B
			SAGE_FIT=config@17
		fi
		;;
	esac
	AB_NAME=Sage
	AB_ENV=sage
	AB_LAYOUT=pair
	AB_MARKER=0
	AB_IMAGE_DIR=$SAGE_BOARD_DIR
	AB_ROOT_MAGIC=31181006
	AB_MODEL=$SAGE_MODEL
	AB_SKU=$(printf '%08x' "$SAGE_SKU")
	AB_FIT=$SAGE_FIT
	AB_QUALIFIED=$SAGE_QUALIFIED
	AB_RADIOS=$SAGE_RADIOS
	AB_LAN='br-lan.1 br-lan'
	AB_PROTECTED='0:ART'
	# OpenWISP-managed Sage APs are committed only after authenticated
	# controller access, which can take longer than the other checks.
	AB_HEALTH_TRIES=180
}

ab_sage_boot_command() {
	case "$1" in 0|1) ;; *) echo "cambium-ab: invalid slot $1" >&2; return 1 ;; esac
	if [ "$AB_SAGE_LEGACY_B" = 1 ] && [ "$1" = "${AB_ACTIVE:-}" ]; then
		# Keep the confirmed pair on its proven E410 FIT configuration.
		(SAGE_FIT=config@ap.dk01.1-c2; cambium_sage_boot_command "$1")
	else
		cambium_sage_boot_command "$1"
	fi
	echo
}

# Sage first installs and later upgrades use the shared A/B one-shot trial;
# a single OEM/OpenWrt guarded boot command is not applicable to this pair layout.
ab_sage_guarded_command() {
	return 1
}

ab_sage_running_slot() {
	local slot
	slot=$(CAMBIUM_CMDLINE=${AB_CMDLINE:-/proc/cmdline} cambium_sage_running_slot)
	case "$slot" in
	0|1) echo "$slot" ;;
	*) echo 'cambium-ab: no root=ubi0:rootfs0/1 on the kernel command line' >&2; return 1 ;;
	esac
}

# Slot values for the pair layout: both slots live on the "fs" MTD.
ab_sage_identity() {
	local fs slot vol name idx flags
	[ "$SAGE_QUALIFIED" = 1 ] || {
		echo "cambium-ab: the $AB_MODEL flash layout has not been captured" >&2
		return 1
	}
	fs=$(ab_mtd_index "$SAGE_UBI_PART")
	case "$fs" in
	''|*[!0-9]*) echo "cambium-ab: missing or duplicate $SAGE_UBI_PART partition" >&2; return 1 ;;
	esac
	slot=$(ab_running_slot) || return 1
	AB_ACTIVE=$slot
	AB_TARGET=$((1 - slot))
	AB_ACTIVE_MTD=$fs
	AB_TARGET_MTD=$fs
	AB_TARGET_PART="linux$AB_TARGET/rootfs$AB_TARGET"
	AB_ACTIVE_UBI=$(ab_ubi_for_mtd "$fs") || {
		echo "cambium-ab: no UBI device is attached to $SAGE_UBI_PART" >&2
		return 1
	}
	for vol in linux0 rootfs0 linux1 rootfs1; do
		ab_ubi_volume "$AB_ACTIVE_UBI" "$vol" >/dev/null || {
			echo "cambium-ab: no UBI volume $vol" >&2
			return 1
		}
	done
	for name in $AB_PROTECTED; do
		idx=$(ab_mtd_index "$name")
		[ -n "$idx" ] || { echo "cambium-ab: missing protected $name" >&2; return 1; }
		flags=$(cat "${AB_MTD_SYS:-/sys/class/mtd}/mtd$idx/flags") || return 1
		[ $(( flags & 0x400 )) -eq 0 ] || {
			echo "cambium-ab: protected $name is writable" >&2
			return 1
		}
	done
}

# The reserved capacity is stable even when recovery staging temporarily
# shrinks a dynamic rootfs volume's data_bytes to the FIT's length.
ab_sage_volume_bytes() {
	local vol base lebs lebsize
	vol=$(ab_ubi_volume "$AB_ACTIVE_UBI" "$1") || return 1
	base=${AB_UBI_SYS:-/sys/class/ubi}/$vol
	lebs=$(cat "$base/reserved_ebs") || return 1
	lebsize=$(cat "$base/usable_eb_size") || return 1
	echo $((lebs * lebsize))
}

ab_sage_image_fits() {
	[ "$1" -le "$(ab_sage_volume_bytes "linux$AB_TARGET")" ] ||
		ab_fail "the kernel ($1 bytes) does not fit linux$AB_TARGET" || return 1
	[ "$2" -le "$(ab_sage_volume_bytes "rootfs$AB_TARGET")" ] ||
		ab_fail "the root filesystem ($2 bytes) does not fit rootfs$AB_TARGET" || return 1
}

# Write the target pair, read it back, carry the configuration into the new
# UBIFS root, and record that both pairs now hold OpenWrt.
ab_sage_write_target() {
	local dev=${AB_DEV:-/dev} kvol rvol mnt=${AB_NEWROOT:-/tmp/cambium-ab-newroot} rc=0
	local batch=/tmp/cambium-ab-sage.$$
	kvol=$(ab_ubi_volume "$AB_ACTIVE_UBI" "linux$AB_TARGET") &&
		rvol=$(ab_ubi_volume "$AB_ACTIVE_UBI" "rootfs$AB_TARGET") || {
		ab_record_failure write-failed "no linux$AB_TARGET/rootfs$AB_TARGET volumes"
		return 1
	}
	# Invalidate the OEM-return marker before the first write to that pair.
	# A failed or interrupted upgrade must not claim a damaged OEM fallback.
	if [ "$(ab_getenv sage_oem_fallback)" = "$AB_TARGET" ]; then
		ab_setenv sage_oem_fallback || {
			ab_record_failure write-failed "cannot retire OEM fallback marker"
			return 1
		}
	fi
	ab_step "mknod $kvol" ab_ubi_node "$kvol" &&
		ab_step "mknod $rvol" ab_ubi_node "$rvol" &&
		ab_step "ubiupdatevol linux$AB_TARGET" ubiupdatevol "$dev/$kvol" "$AB_KERNEL" &&
		ab_step "ubiupdatevol rootfs$AB_TARGET" ubiupdatevol "$dev/$rvol" "$AB_ROOT" || {
		ab_record_failure write-failed "cannot write pair $AB_TARGET"
		return 1
	}
	ab_verify_volume "$dev/$kvol" "$AB_KERNEL" "$AB_KERNEL_SIZE" &&
		ab_verify_volume "$dev/$rvol" "$AB_ROOT" "$AB_ROOT_SIZE" || {
		AB_STEP_ERROR=
		ab_record_failure write-failed "pair $AB_TARGET readback mismatch"
		return 1
	}
	if [ -n "${UPGRADE_BACKUP:-}" ]; then
		mkdir -p "$mnt"
		ab_step "mount rootfs$AB_TARGET" mount -t ubifs "$dev/$rvol" "$mnt" || {
			ab_record_failure write-failed "cannot mount rootfs$AB_TARGET to keep the configuration"
			return 1
		}
		ab_step "keep the configuration" cp "$UPGRADE_BACKUP" "$mnt/${BACKUP_FILE:-sysupgrade.tgz}" || rc=1
		sync
		umount "$mnt" || rc=1
		rmdir "$mnt" 2>/dev/null
		[ "$rc" = 0 ] || {
			ab_record_failure write-failed "cannot keep the configuration in rootfs$AB_TARGET"
			return 1
		}
	fi
	# Record the confirmed source before arming the target trial. On the
	# first stock install that source is OEM; its marker is set afterward.
	{ echo 'sage_ab_version 1'; echo "sage_ab_confirmed $AB_ACTIVE"; } > "$batch"
	ab_setenv_batch "$batch" || rc=1
	rm -f "$batch"
	[ "$rc" = 0 ] || ab_record_failure write-failed "cannot record the A/B state"
}

# The root is the running pair's UBIFS, mounted read-write.
ab_sage_root_healthy() {
	awk '$2 == "/" && $3 == "ubifs" && $4 ~ /^rw/ { found = 1 } END { exit !found }' \
		"${AB_PROC_MOUNTS:-/proc/mounts}"
}

# Managed APs also need their OpenWISP controller, as the earlier Sage
# commit service did; standalone APs (no controller URL) do not.
ab_sage_healthy_extra() {
	[ -n "$(uci -q get openwisp.http.url 2>/dev/null)" ] || return 0
	[ -f "${CAMBIUM_OPENWISP_LED_STATE:-/tmp/cambium-openwisp-managed}" ] &&
		/etc/init.d/openwisp-config running >/dev/null 2>&1 &&
		/etc/init.d/openwisp-monitoring running >/dev/null 2>&1
}
