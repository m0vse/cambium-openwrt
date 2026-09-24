PART_NAME=firmware
REQUIRE_IMAGE_METADATA=1

RAMFS_COPY_BIN='fw_printenv fw_setenv head sha256sum'
RAMFS_COPY_DATA='/etc/fw_env.config /var/lock/fw_printenv.lock'

[ -f "${CAMBIUM_SAGE_LIB:-/lib/functions/cambium-sage.sh}" ] &&
	. "${CAMBIUM_SAGE_LIB:-/lib/functions/cambium-sage.sh}"

# Every Cambium Sage board is dispatched here and refused unless the board
# table (cambium-sage.sh) qualifies it for persistent A/B writes.
cambium_sage_prepare() {
	cambium_sage_board || {
		echo "Unknown Cambium Sage board $(board_name); refusing to write flash"
		return 1
	}
	[ "$SAGE_QUALIFIED" = 1 ] || {
		echo "Cambium $SAGE_MODEL: A/B sysupgrade is not qualified on this model yet; refusing to write flash"
		return 1
	}
	cambium_sage_check_sku || {
		echo "Cambium $SAGE_MODEL: the board SKU does not match SKU $SAGE_SKU; refusing to write flash"
		return 1
	}
}

cambium_sage_image_info() {
	local image="$1"
	local board_dir

	board_dir=$(tar tf "$image" | grep -m 1 "^$SAGE_BOARD_DIR/\$")
	board_dir=${board_dir%/}
	[ -n "$board_dir" ] || return 1

	SAGE_IMAGE_DIR="$board_dir"
	SAGE_KERNEL_SIZE=$(tar xOf "$image" "$board_dir/kernel" | wc -c)
	SAGE_ROOTFS_SIZE=$(tar xOf "$image" "$board_dir/root" | wc -c)
	[ "$SAGE_KERNEL_SIZE" -gt 0 ] 2>/dev/null || return 1
	[ "$SAGE_ROOTFS_SIZE" -gt 0 ] 2>/dev/null || return 1
	[ "$SAGE_KERNEL_SIZE" -le "$SAGE_KERNEL_MAX" ] || return 1
	[ "$SAGE_ROOTFS_SIZE" -le "$SAGE_ROOTFS_MAX" ] || return 1

	[ "$(tar xOf "$image" "$board_dir/kernel" | head -c 4 | hexdump -v -e '1/1 "%02x"')" = d00dfeed ] || return 1
	[ "$(tar xOf "$image" "$board_dir/root" | head -c 4 | hexdump -v -e '1/1 "%02x"')" = 31181006 ] || return 1
}

# Set SAGE_ACTIVE, SAGE_TARGET and the target's kernel/rootfs UBI volumes.
cambium_sage_select_slots() {
	SAGE_ACTIVE=$(cambium_sage_running_slot)
	case "$SAGE_ACTIVE" in
		0) SAGE_TARGET=1 ;;
		1) SAGE_TARGET=0 ;;
		*) echo "Cannot determine the active $SAGE_MODEL slot"; return 1 ;;
	esac
	SAGE_KERNEL_UBI=$(nand_find_volume ubi0 "$SAGE_KERNEL_VOL$SAGE_TARGET")
	SAGE_ROOTFS_UBI=$(nand_find_volume ubi0 "$SAGE_ROOTFS_VOL$SAGE_TARGET")
	[ -n "$SAGE_KERNEL_UBI" ] && [ -n "$SAGE_ROOTFS_UBI" ] || {
		echo "The inactive $SAGE_MODEL UBI volume pair is missing"
		return 1
	}
}

cambium_sage_check_image() {
	local image="$1"
	local sysfs="${SAGE_UBI_SYSFS:-/sys/class/ubi}"

	cambium_sage_prepare || return 1
	nand_do_platform_check "$(board_name)" "$image" || return 1
	cambium_sage_image_info "$image" || {
		echo "Invalid Cambium $SAGE_MODEL A/B sysupgrade image"
		return 1
	}
	cambium_sage_select_slots || return 1
	[ "$SAGE_KERNEL_SIZE" -le "$(cat "$sysfs/$SAGE_KERNEL_UBI/data_bytes")" ] || {
		echo "The kernel does not fit the inactive $SAGE_MODEL volume"
		return 1
	}
	[ "$SAGE_ROOTFS_SIZE" -le "$(cat "$sysfs/$SAGE_ROOTFS_UBI/data_bytes")" ] || {
		echo "The root filesystem does not fit the inactive $SAGE_MODEL volume"
		return 1
	}
	return 0
}

platform_check_image() {
	case "$(board_name)" in
	cambium,e410|\
	cambiumnetworks,e410b|\
	cambiumnetworks,e430h|\
	cambiumnetworks,e430w|\
	cambiumnetworks,e510|\
	cambiumnetworks,e600|\
	cambiumnetworks,e700)
		cambium_sage_check_image "$1"
		return $?
		;;
	asus,map-ac1300|\
	asus,rt-ac42u|\
	asus,rt-ac58u)
		local ubidev=$(nand_find_ubi $CI_UBIPART)
		local asus_root=$(nand_find_volume $ubidev jffs2)

		[ -n "$asus_root" ] || return 0

		cat << EOF
jffs2 partition is still present.
There's probably no space left
to install the filesystem.

You need to delete the jffs2 partition first:
# ubirmvol /dev/ubi0 --name=jffs2

Once this is done. Retry.
EOF
		return 1
		;;
	zte,mf18a|\
	zte,mf282plus|\
	zte,mf286d|\
	zte,mf287|\
	zte,mf287plus|\
	zte,mf287pro|\
	zte,mf289f)
		CI_UBIPART="rootfs"
		local mtdnum="$( find_mtd_index $CI_UBIPART )"
		[ ! "$mtdnum" ] && return 1
		ubiattach -m "$mtdnum" || true
		local ubidev="$( nand_find_ubi $CI_UBIPART )"
		local ubi_rootfs=$(nand_find_volume $ubidev ubi_rootfs)
		local ubi_rootfs_data=$(nand_find_volume $ubidev ubi_rootfs_data)

		[ -n "$ubi_rootfs" ] || [ -n "$ubi_rootfs_data" ] || return 0

		cat << EOF
ubi_rootfs partition is still present.

You need to delete the stock partition first:
# ubirmvol /dev/ubi0 -N ubi_rootfs
Please also delete ubi_rootfs_data, if exist:
# ubirmvol /dev/ubi0 -N ubi_rootfs_data

Once this is done. Retry.
EOF
		return 1
		;;
	esac
	return 0;
}

askey_do_upgrade() {
	local tar_file="$1"

	local board_dir=$(tar tf $tar_file | grep -m 1 '^sysupgrade-.*/$')
	board_dir=${board_dir%/}

	tar Oxf $tar_file ${board_dir}/root | mtd write - rootfs

	nand_do_upgrade "$1"
}

zyxel_do_upgrade() {
	local tar_file="$1"

	local board_dir=$(tar tf $tar_file | grep -m 1 '^sysupgrade-.*/$')
	board_dir=${board_dir%/}

	tar Oxf $tar_file ${board_dir}/kernel | mtd write - kernel

	if [ -n "$UPGRADE_BACKUP" ]; then
		tar Oxf $tar_file ${board_dir}/root | mtd -j "$UPGRADE_BACKUP" write - rootfs
	else
		tar Oxf $tar_file ${board_dir}/root | mtd write - rootfs
	fi
}

cambium_sage_do_upgrade() {
	local image="$1"
	local dev="${SAGE_DEV:-/dev}"
	local kernel_tmp=/tmp/sage-sysupgrade-kernel.itb
	local rootfs_tmp=/tmp/sage-sysupgrade-rootfs.ubifs
	local new_root=/tmp/sage-sysupgrade-root
	local active target kernel_hash rootfs_hash written_hash
	local boot0 boot1 stable trial

	# Re-check everything: stage two must never trust an earlier check.
	cambium_sage_prepare || return 1
	cambium_sage_image_info "$image" || return 1
	cambium_sage_select_slots || return 1
	active=$SAGE_ACTIVE
	target=$SAGE_TARGET

	boot0=$(cambium_sage_boot_command 0)
	boot1=$(cambium_sage_boot_command 1)
	stable="run owrt_boot$active; run owrt_boot$target"
	# The e410_* variable names are kept so installed systems and the
	# mark-good service continue to agree on the upgrade state.
	trial="setenv bootcmd '$stable'; setenv image $active; setenv e410_upgrade_state fallback-restored; saveenv; run owrt_boot$target; run owrt_boot$active"

	# Make the currently running slot persistent before modifying its peer.  The
	# final bootcmd update below is deliberately the last persistent operation.
	fw_setenv owrt_boot0 "$boot0" || return 1
	fw_setenv owrt_boot1 "$boot1" || return 1
	fw_setenv bootcmd "$stable" || return 1
	fw_setenv image "$active" || return 1
	fw_setenv e410_upgrade_target "$target" || return 1
	fw_setenv e410_upgrade_fallback "$active" || return 1
	fw_setenv e410_upgrade_state writing || return 1
	sync

	tar xOf "$image" "$SAGE_IMAGE_DIR/kernel" >"$kernel_tmp" || return 1
	tar xOf "$image" "$SAGE_IMAGE_DIR/root" >"$rootfs_tmp" || return 1
	kernel_hash=$(sha256sum "$kernel_tmp" | awk '{print $1}')
	rootfs_hash=$(sha256sum "$rootfs_tmp" | awk '{print $1}')

	ubiupdatevol "$dev/$SAGE_KERNEL_UBI" "$kernel_tmp" || return 1
	ubiupdatevol "$dev/$SAGE_ROOTFS_UBI" "$rootfs_tmp" || return 1
	sync
	written_hash=$(head -c "$SAGE_KERNEL_SIZE" "$dev/$SAGE_KERNEL_UBI" | sha256sum | awk '{print $1}')
	[ "$written_hash" = "$kernel_hash" ] || return 1
	written_hash=$(head -c "$SAGE_ROOTFS_SIZE" "$dev/$SAGE_ROOTFS_UBI" | sha256sum | awk '{print $1}')
	[ "$written_hash" = "$rootfs_hash" ] || return 1
	rm -f "$kernel_tmp" "$rootfs_tmp"

	if [ -n "$UPGRADE_BACKUP" ]; then
		mkdir -p "$new_root"
		mount -t ubifs "$dev/$SAGE_ROOTFS_UBI" "$new_root" || return 1
		mv "$UPGRADE_BACKUP" "$new_root/$BACKUP_FILE" || {
			umount "$new_root"
			return 1
		}
		sync
		umount "$new_root" || return 1
		rmdir "$new_root"
		UPGRADE_BACKUP=
	fi

	fw_setenv e410_upgrade_state trial-armed || return 1
	fw_setenv bootcmd "$trial" || return 1
	sync
	echo "$SAGE_MODEL inactive slot $target written and protected trial boot armed"
}

platform_do_upgrade_mikrotik_nand() {
	local fw_mtd=$(find_mtd_part kernel)
	fw_mtd="${fw_mtd/block/}"
	[ -n "$fw_mtd" ] || return

	local board_dir=$(tar tf "$1" | grep -m 1 '^sysupgrade-.*/$')
	board_dir=${board_dir%/}
	[ -n "$board_dir" ] || return

	local kernel_len=$(tar xf "$1" ${board_dir}/kernel -O | wc -c)
	[ -n "$kernel_len" ] || return

	tar xf "$1" ${board_dir}/kernel -O | ubiformat "$fw_mtd" -y -S $kernel_len -f -

	CI_KERNPART="none"
	nand_do_upgrade "$1"
}

platform_do_upgrade() {
	case "$(board_name)" in
	cambium,e410|\
	cambiumnetworks,e410b|\
	cambiumnetworks,e430h|\
	cambiumnetworks,e430w|\
	cambiumnetworks,e510|\
	cambiumnetworks,e600|\
	cambiumnetworks,e700)
		cambium_sage_do_upgrade "$1"
		;;
	8dev,jalapeno|\
	aruba,ap-303|\
	aruba,ap-303h|\
	aruba,ap-365|\
	avm,fritzbox-7530|\
	avm,fritzrepeater-1200|\
	avm,fritzrepeater-3000|\
	buffalo,wtr-m2133hp|\
	cilab,meshpoint-one|\
	compex,wpj419|\
	edgecore,ecw5211|\
	edgecore,oap100|\
	engenius,eap2200|\
	glinet,gl-a1300|\
	glinet,gl-ap1300|\
	luma,wrtq-329acn|\
	mobipromo,cm520-79f|\
	netgear,lbr20|\
	netgear,rbr20|\
	netgear,rbs20|\
	netgear,wac510|\
	p2w,r619ac-64m|\
	p2w,r619ac-128m|\
	qxwlan,e2600ac-c2|\
	wallys,dr40x9)
		nand_do_upgrade "$1"
		;;
	alfa-network,ap120c-ac)
		part="$(awk -F 'ubi.mtd=' '{printf $2}' /proc/cmdline | sed -e 's/ .*$//')"
		if [ "$part" = "rootfs1" ]; then
			fw_setenv active 2 || exit 1
			CI_UBIPART="rootfs2"
		else
			fw_setenv active 1 || exit 1
			CI_UBIPART="rootfs1"
		fi
		nand_do_upgrade "$1"
		;;
	asus,map-ac1300|\
	asus,map-ac2200|\
	asus,rt-ac42u|\
	asus,rt-ac58u)
		CI_KERNPART="linux"
		nand_do_upgrade "$1"
		;;
	cellc,rtl30vw)
		CI_UBIPART="ubifs"
		askey_do_upgrade "$1"
		;;
	glinet,gl-b2200)
		CI_KERNPART="0:HLOS"
		CI_ROOTPART="rootfs"
		CI_DATAPART="rootfs_data"
		emmc_do_upgrade "$1"
		;;
	google,wifi)
		export_bootdevice
		export_partdevice CI_ROOTDEV 0
		CI_KERNPART="kernel"
		CI_ROOTPART="rootfs"
		emmc_do_upgrade "$1"
		;;
	huawei,ap4050dn)
		# Store beginning address of the "uboot" partition
		# as KernelA address and KernelB address, each to ResultA & ResultB
		# This is the address from which the bootloader will try to load the u-boot that we use as loader.
		HUAWEI_AP4050DN_LOADADDR="\x00\x00\x70\x00\x00\x00\x70\x00"
		echo -n -e $HUAWEI_AP4050DN_LOADADDR | dd of=$(find_mtd_part ResultA) bs=1 seek=$((0x4264)) conv=notrunc
		echo -n -e $HUAWEI_AP4050DN_LOADADDR | dd of=$(find_mtd_part ResultA) bs=1 seek=$((0x40264)) conv=notrunc
		echo -n -e $HUAWEI_AP4050DN_LOADADDR | dd of=$(find_mtd_part ResultB) bs=1 seek=$((0x4264)) conv=notrunc
		default_do_upgrade "$1"
		;;
	linksys,ea6350v3|\
	linksys,ea8300|\
	linksys,mr6350|\
	linksys,mr8300|\
	linksys,mr9000|\
	linksys,whw01|\
	linksys,whw03v2)
		platform_do_upgrade_linksys "$1"
		;;
	linksys,whw03)
		platform_do_upgrade_linksys_emmc "$1"
		;;
	meraki,mr20|\
	meraki,mr70|\
	meraki,gx20|\
	meraki,z3|\
	meraki,z3c)
		# DO NOT set CI_KERNPART to part.safe,
		# that is used for chain-loading an unlocked u-boot
		# if part.safe is overwritten, then u-boot is lost!
		CI_KERNPART="part.old"
		nand_do_upgrade "$1"
		;;
	meraki,mr30h|\
	meraki,mr33|\
	meraki,mr74)
		CI_KERNPART="part.safe"
		nand_do_upgrade "$1"
		;;
	mikrotik,cap-ac|\
	mikrotik,hap-ac2|\
	mikrotik,hap-ac3-lte6-kit|\
	mikrotik,lhgg-60ad|\
	mikrotik,sxtsq-5-ac|\
	mikrotik,wap-ac|\
	mikrotik,wap-ac-lte|\
	mikrotik,wap-r-ac)
		[ "$(rootfs_type)" = "tmpfs" ] && mtd erase firmware
		default_do_upgrade "$1"
		;;
	mikrotik,hap-ac3)
		platform_do_upgrade_mikrotik_nand "$1"
		;;
	netgear,rbr40|\
	netgear,rbs40|\
	netgear,rbr50|\
	netgear,rbs50|\
	netgear,srr60|\
	netgear,srs60)
		platform_do_upgrade_netgear_orbi_upgrade "$1"
		;;
	openmesh,a42|\
	openmesh,a62|\
	plasmacloud,pa1200|\
	plasmacloud,pa2200)
		PART_NAME="inactive"
		platform_do_upgrade_dualboot_datachk "$1"
		;;
	sony,ncp-hg100-cellular)
		sony_emmc_do_upgrade "$1"
		;;
	sophos,apx120)
		CI_UBIPART="rootfs"
		# Strip fwtool trailer for eraseblock alignment before ubiformat.
		fwtool -q -t -i /dev/null "$1" || true
		nand_do_upgrade "$1"
		;;
	teltonika,rutx10|\
	teltonika,rutx50|\
	zte,mf18a|\
	zte,mf282plus|\
	zte,mf286d|\
	zte,mf287|\
	zte,mf287plus|\
	zte,mf287pro|\
	zte,mf289f)
		CI_UBIPART="rootfs"
		nand_do_upgrade "$1"
		;;
	ubnt,utr)
		CI_UBIPART="kernel1"
		CI_KERNPART="vol"
		nand_do_upgrade "$1"
		;;
	zyxel,nbg6617)
		zyxel_do_upgrade "$1"
		;;
	*)
		default_do_upgrade "$1"
		;;
	esac
}

platform_copy_config() {
	case "$(board_name)" in
	glinet,gl-b2200|\
	google,wifi|\
	linksys,whw03)
		emmc_copy_config
		;;
	esac
	return 0;
}
