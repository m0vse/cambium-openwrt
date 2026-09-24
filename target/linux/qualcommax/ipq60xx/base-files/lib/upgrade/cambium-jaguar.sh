# Cambium Jaguar family A/B sysupgrade: write only the inactive 96 MiB
# firmware bank, verify it, then arm a one-shot trial whose first durable
# step restores the old bank as the default. The boot guard commits the new
# bank only after its health checks pass. Nothing here falls back to the
# generic nand_do_upgrade/default_do_upgrade paths.
#
# Test hooks: CAMBIUM_JAGUAR_LIB, JAGUAR_DEV and the hooks listed in
# /lib/functions/cambium-jaguar.sh.

. "${CAMBIUM_JAGUAR_LIB:-/lib/functions/cambium-jaguar.sh}"

JAGUAR_IMAGE_DIR=sysupgrade-cambiumnetworks_jaguar
# The bank's usable LEBs (JAGUAR_BANK_LEBS) come from the board table.
JAGUAR_VAULT_LEBS=8
# Smallest writable overlay a new bank may get (8 MiB).
JAGUAR_MIN_DATA_LEBS=67

jaguar_lebs() {
	echo $(( ($1 + JAGUAR_LEB - 1) / JAGUAR_LEB ))
}

jaguar_fail() {
	echo "Jaguar sysupgrade: $*" >&2
	return 1
}

# Extract and check the image's kernel FIT and root filesystem into
# $JAGUAR_WORK. Sets JAGUAR_KERNEL_SIZE and JAGUAR_ROOT_SIZE.
jaguar_image_extract() {
	local image="$1" magic
	JAGUAR_WORK=${JAGUAR_WORK:-/tmp/jaguar-upgrade}
	rm -rf "$JAGUAR_WORK" && mkdir -p "$JAGUAR_WORK" || return 1
	tar -xf "$image" -C "$JAGUAR_WORK" "$JAGUAR_IMAGE_DIR/kernel" "$JAGUAR_IMAGE_DIR/root" 2>/dev/null ||
		jaguar_fail "image has no $JAGUAR_IMAGE_DIR/kernel and root" || return 1
	JAGUAR_KERNEL=$JAGUAR_WORK/$JAGUAR_IMAGE_DIR/kernel
	JAGUAR_ROOT=$JAGUAR_WORK/$JAGUAR_IMAGE_DIR/root
	magic=$(hexdump -n 4 -v -e '4/1 "%02x"' "$JAGUAR_KERNEL")
	[ "$magic" = d00dfeed ] || jaguar_fail "kernel is not a FIT image" || return 1
	# A FIT node name follows the FDT_BEGIN_NODE token, which ends in 0x01.
	tr '\000' '\n' < "$JAGUAR_KERNEL" | grep -q "^$(printf '\001')$JAGUAR_FIT\$" ||
		jaguar_fail "FIT lacks $JAGUAR_FIT for $JAGUAR_MODEL" || return 1
	[ "$(head -c 4 "$JAGUAR_ROOT")" = hsqs ] || jaguar_fail "root is not SquashFS" || return 1
	JAGUAR_KERNEL_SIZE=$(wc -c < "$JAGUAR_KERNEL")
	JAGUAR_ROOT_SIZE=$(wc -c < "$JAGUAR_ROOT")
	[ $(( $(jaguar_lebs "$JAGUAR_KERNEL_SIZE") + $(jaguar_lebs "$JAGUAR_ROOT_SIZE") + \
		JAGUAR_VAULT_LEBS + JAGUAR_MIN_DATA_LEBS )) -le "$JAGUAR_BANK_LEBS" ] ||
		jaguar_fail "image does not fit this $JAGUAR_MODEL bank ($JAGUAR_BANK_LEBS LEBs) with the vault and overlay" || return 1
}

# Everything a normal A/B upgrade requires of the running system.
jaguar_upgrade_preflight() {
	local state
	jaguar_identity || return 1
	jaguar_ab_converted ||
		jaguar_fail "this AP still has one OEM slot; run jaguar-ab-convert first" || return 1
	jaguar_mtd_writable "$JAGUAR_TARGET_MTD" ||
		jaguar_fail "target bank $JAGUAR_TARGET_PART is read-only (not an A/B image)" || return 1
	[ "$(jaguar_getenv changing_bootcmd)" = 1 ] ||
		jaguar_fail "changing_bootcmd is not saved" || return 1
	state=$(jaguar_getenv jaguar_ab_state)
	case "$state" in
	trial-started|armed)
		jaguar_fail "a trial of slot $(jaguar_getenv jaguar_ab_target) is not confirmed yet" || return 1
		;;
	esac
	jaguar_ubi_volume "$JAGUAR_ACTIVE_UBI" cambium_device_data >/dev/null ||
		jaguar_fail "the running bank has no device-data vault" || return 1
}

cambium_jaguar_check_image() {
	jaguar_upgrade_preflight || return 1
	${JAGUAR_BOARD_DATA:-/usr/sbin/cambium-board-data} --check-vault ||
		jaguar_fail "the device-data vault is missing or does not match this AP" || return 1
	jaguar_image_extract "$1" || return 1
	rm -rf "$JAGUAR_WORK"
}

jaguar_record_failure() {
	local batch=/tmp/jaguar-env-fail.$$
	printf 'jaguar_ab_state %s\njaguar_ab_last_failure %s\n' "$1" "$2" > "$batch"
	jaguar_setenv_batch "$batch" >/dev/null 2>&1
	rm -f "$batch"
	jaguar_fail "$2"
}

# Readback: the first $3 bytes of volume $1 must hash like file $2.
jaguar_verify_volume() {
	[ "$(head -c "$3" "$1" | sha256sum | cut -d' ' -f1)" = \
		"$(sha256sum < "$2" | cut -d' ' -f1)" ]
}

# Format the inactive bank and create kernel (0), rootfs (1), the vault (3)
# and rootfs_data (2) from the remaining space. Sets JAGUAR_TARGET_UBI.
jaguar_prepare_bank() {
	local kernel_size="$1" root_size="$2" ubi dev=${JAGUAR_DEV:-/dev} data
	ubi=$(jaguar_ubi_for_mtd "$JAGUAR_TARGET_MTD") &&
		{ ubidetach -m "$JAGUAR_TARGET_MTD" || return 1; }
	ubiformat "$dev/mtd$JAGUAR_TARGET_MTD" -y -q || return 1
	ubiattach -m "$JAGUAR_TARGET_MTD" >/dev/null || return 1
	JAGUAR_TARGET_UBI=$(jaguar_ubi_for_mtd "$JAGUAR_TARGET_MTD") || return 1
	ubimkvol "$dev/$JAGUAR_TARGET_UBI" -n 0 -N kernel -s "$kernel_size" >/dev/null &&
		ubimkvol "$dev/$JAGUAR_TARGET_UBI" -n 1 -N rootfs -s "$root_size" >/dev/null &&
		ubimkvol "$dev/$JAGUAR_TARGET_UBI" -n 3 -N cambium_device_data \
			-s $((JAGUAR_VAULT_LEBS * JAGUAR_LEB)) >/dev/null &&
		ubimkvol "$dev/$JAGUAR_TARGET_UBI" -n 2 -N rootfs_data -m >/dev/null || return 1
	data=$(cat "${JAGUAR_UBI_SYS:-/sys/class/ubi}/${JAGUAR_TARGET_UBI}_2/data_bytes") || return 1
	[ "$data" -ge $((JAGUAR_MIN_DATA_LEBS * JAGUAR_LEB)) ] ||
		jaguar_fail "only $data bytes left for rootfs_data"
}

# Copy the running bank's vault to the target bank and compare it.
jaguar_copy_vault() {
	local dev=${JAGUAR_DEV:-/dev} src dst copy=/tmp/jaguar-vault.$$
	src=$dev/$(jaguar_ubi_volume "$JAGUAR_ACTIVE_UBI" cambium_device_data) || return 1
	dst=$dev/${JAGUAR_TARGET_UBI}_3
	cat "$src" > "$copy" && ubiupdatevol "$dst" "$copy" &&
		jaguar_verify_volume "$dst" "$copy" "$(wc -c < "$copy")"
	local rc=$?
	rm -f "$copy"
	return "$rc"
}

# Arm the one-shot trial of the written bank. bootcmd is the last write.
jaguar_arm_trial() {
	local batch=/tmp/jaguar-env-arm.$$ trial rc=0
	trial=$(jaguar_trial_command "$JAGUAR_ACTIVE" "$JAGUAR_TARGET") || return 1
	jaguar_write_boot_vars || return 1
	printf 'jaguar_ab_state armed\njaguar_ab_target %s\n' "$JAGUAR_TARGET" > "$batch"
	jaguar_setenv_batch "$batch" || rc=1
	rm -f "$batch"
	[ "$rc" = 0 ] && jaguar_setenv bootcmd "$trial"
}

cambium_jaguar_do_upgrade() {
	local dev=${JAGUAR_DEV:-/dev} batch=/tmp/jaguar-env-write.$$
	jaguar_upgrade_preflight || return 1
	jaguar_image_extract "$1" || return 1

	# Record the write before touching the bank. bootcmd still boots the
	# running bank first, so an interrupted write never loses it.
	printf 'jaguar_ab_state writing\njaguar_ab_target %s\n' "$JAGUAR_TARGET" > "$batch"
	jaguar_setenv_batch "$batch" || { rm -f "$batch"; jaguar_fail "cannot record the upgrade"; return 1; }
	rm -f "$batch"

	echo "Jaguar: writing slot $JAGUAR_TARGET ($JAGUAR_TARGET_PART) from slot $JAGUAR_ACTIVE"
	jaguar_prepare_bank "$JAGUAR_KERNEL_SIZE" "$JAGUAR_ROOT_SIZE" ||
		{ jaguar_record_failure write-failed "cannot format slot $JAGUAR_TARGET"; return 1; }
	ubiupdatevol "$dev/${JAGUAR_TARGET_UBI}_0" "$JAGUAR_KERNEL" &&
		ubiupdatevol "$dev/${JAGUAR_TARGET_UBI}_1" "$JAGUAR_ROOT" ||
		{ jaguar_record_failure write-failed "cannot write slot $JAGUAR_TARGET"; return 1; }
	jaguar_verify_volume "$dev/${JAGUAR_TARGET_UBI}_0" "$JAGUAR_KERNEL" "$JAGUAR_KERNEL_SIZE" &&
		jaguar_verify_volume "$dev/${JAGUAR_TARGET_UBI}_1" "$JAGUAR_ROOT" "$JAGUAR_ROOT_SIZE" ||
		{ jaguar_record_failure write-failed "slot $JAGUAR_TARGET readback mismatch"; return 1; }
	jaguar_copy_vault ||
		{ jaguar_record_failure write-failed "cannot copy the device-data vault"; return 1; }

	if [ -n "${UPGRADE_BACKUP:-}" ]; then
		CI_UBIPART=$JAGUAR_TARGET_PART nand_restore_config "$UPGRADE_BACKUP" ||
			{ jaguar_record_failure write-failed "cannot save the configuration"; return 1; }
	fi
	sync

	jaguar_arm_trial ||
		{ jaguar_record_failure write-failed "cannot arm the trial of slot $JAGUAR_TARGET"; return 1; }
	echo "Jaguar: slot $JAGUAR_TARGET armed for one trial boot; slot $JAGUAR_ACTIVE stays the default until it is confirmed"
}
