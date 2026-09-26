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
# The earlier Sage code kept its state in e410_upgrade_* and owrt_boot0/1.
# On the first boot of an image carrying this module, ab_sage_takeover
# adopts that state, so an installed E410 moves over with a normal
# sysupgrade.

. "${CAMBIUM_SAGE_LIB:-/lib/functions/cambium-sage.sh}"

case " ${AB_FAMILIES:-} " in
*" sage "*) ;;
*) AB_FAMILIES="${AB_FAMILIES:+$AB_FAMILIES }sage" ;;
esac

ab_sage_board() {
	cambium_sage_board "$1" || return 1
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
	case "$1" in
	0|1) cambium_sage_boot_command "$1"; echo ;;
	*) echo "cambium-ab: invalid slot $1" >&2; return 1 ;;
	esac
}

# Sage installs arm their own one-shot trial (sage-migration-mark-good);
# there is no one-OEM guarded command.
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

ab_sage_volume_bytes() {
	cat "${AB_UBI_SYS:-/sys/class/ubi}/$(ab_ubi_volume "$AB_ACTIVE_UBI" "$1")/data_bytes"
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
	# From here both pairs hold OpenWrt; the running pair is the default.
	printf "sage_ab_version 1\nsage_ab_confirmed %s\n" "$AB_ACTIVE" > "$batch"
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

# Make the running pair the committed default under the sage_* state.
ab_sage_adopt() {
	local slot=$1 batch=/tmp/cambium-ab-sage.$$ rc=0
	ab_write_boot_vars || return 1
	printf "sage_ab_version 1\nsage_ab_confirmed %s\nsage_ab_state confirmed\nimage %s\ne410_upgrade_state migrated\n" \
		"$slot" "$slot" > "$batch"
	printf "sage_ab_target\nsage_ab_last_failure\nbootcount 0\n" >> "$batch"
	ab_setenv_batch "$batch" || rc=1
	rm -f "$batch"
	[ "$rc" = 0 ] && ab_setenv bootcmd "run sage_stable$slot"
}

# First boot of this module on an E410 that the earlier Sage code upgraded:
# both pairs hold OpenWrt (owrt_boot0/1 exist). A trial it armed
# (e410_upgrade_state fallback-restored, running the target pair) is
# committed once healthy, or left for the old pair, which is still the
# default, to take back on the next boot. An E410 still holding the stock
# firmware in its other pair has no owrt_boot0/1 and is left alone.
ab_sage_takeover() {
	local state target fallback
	ab_converted && return 2
	[ -n "$(ab_getenv owrt_boot0)" ] && [ -n "$(ab_getenv owrt_boot1)" ] || return 2
	state=$(ab_getenv e410_upgrade_state)
	target=$(ab_getenv e410_upgrade_target)
	fallback=$(ab_getenv e410_upgrade_fallback)
	case "$target:$fallback" in 0:1|1:0) ;; *) return 2 ;; esac
	ab_identity || return 1
	[ "$AB_ACTIVE" = "$target" ] || return 2
	case "$state" in
	fallback-restored)
		if wait_healthy ab; then
			ab_sage_adopt "$AB_ACTIVE" || { log "could not adopt the Sage A/B state"; return 1; }
			log "Sage pair $AB_ACTIVE healthy; adopted as the default, pair $fallback the fallback"
			return 0
		fi
		# bootcmd still boots the old pair first; its own commit service
		# records the rollback.
		log "startup checks failed; returning to pair $fallback"
		do_reboot
		return 0
		;;
	committed)
		ab_sage_adopt "$AB_ACTIVE" || { log "could not adopt the Sage A/B state"; return 1; }
		log "Sage pair $AB_ACTIVE adopted as the default, pair $fallback the fallback"
		return 0
		;;
	esac
	return 2
}
