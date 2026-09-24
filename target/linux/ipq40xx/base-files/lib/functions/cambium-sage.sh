# Cambium Sage (IPQ4019) board table, shared by sysupgrade (platform.sh) and
# the cambium-sage-support helpers.
#
# Boards built on the E410 tree (E410, E410B, E510) share the SPI-NAND UBI
# layout captured on the E410/E410B and are qualified for persistent A/B
# writes. The DK07-based boards (E600, E700, E430W, E430H) use the separate
# parallel NAND controller; they refuse to write flash until one unit's
# layout, U-Boot environment and NAND numbering have been captured. The OEM
# migration helpers remain E410-only; they do not consult this table.

# cambium_sage_board [BOARD_NAME]
# Set the SAGE_* variables for a Sage board and return 0, or return 1 for any
# other board.
cambium_sage_board() {
	local board="${1:-$(board_name)}"

	SAGE_MODEL= SAGE_SKU= SAGE_FIT= SAGE_QUALIFIED=0
	case "$board" in
	cambium,e410)
		# Also E410B hardware, which boots the same configuration.
		SAGE_MODEL=E410 SAGE_SKU=10 SAGE_FIT=config@ap.dk01.1-c2 SAGE_QUALIFIED=1 ;;
	cambiumnetworks,e410b)	SAGE_MODEL=E410B SAGE_SKU=21 SAGE_FIT=config@17 SAGE_QUALIFIED=1 ;;
	cambiumnetworks,e600)	SAGE_MODEL=E600 SAGE_SKU=11 SAGE_FIT=config@10 ;;
	cambiumnetworks,e430w)	SAGE_MODEL=E430W SAGE_SKU=13 SAGE_FIT=config@13 ;;
	cambiumnetworks,e700)	SAGE_MODEL=E700 SAGE_SKU=14 SAGE_FIT=config@14 ;;
	cambiumnetworks,e430h)	SAGE_MODEL=E430H SAGE_SKU=15 SAGE_FIT=config@15 ;;
	cambiumnetworks,e510)	SAGE_MODEL=E510 SAGE_SKU=16 SAGE_FIT=config@16 SAGE_QUALIFIED=1 ;;
	*) return 1 ;;
	esac

	# Layout captured on the E410/E410B: SPI NAND as U-Boot nand device 1,
	# holding one 128 MiB UBI partition "fs" with linuxN/rootfsN volume pairs
	# and 126,976-byte LEBs. Unqualified boards keep these values only so that
	# their refusal messages are complete; they are not used to write flash.
	SAGE_BOARD_DIR=sysupgrade-cambium_e410
	SAGE_NAND_DEV=1
	SAGE_NAND_MTDPARTS='mtdparts=nand1:0x8000000@0x0(fs)'
	SAGE_KERNEL_MTDPARTS='mtdparts=spi0.1:128M(fs)'
	SAGE_UBI_PART=fs
	SAGE_KERNEL_VOL=linux
	SAGE_ROOTFS_VOL=rootfs
	SAGE_LOADADDR=0x84000000
	SAGE_KERNEL_MAX=4317184
	SAGE_ROOTFS_MAX=47235072
	SAGE_RADIOS=2
	return 0
}

# cambium_sage_check_sku
# Fail if the running device tree records a board SKU other than the table's.
cambium_sage_check_sku() {
	local node="${SAGE_DT_SKU:-/proc/device-tree/cambium-platform/board-sku}"
	local hex

	[ -r "$node" ] || return 0
	hex=$(hexdump -v -e '1/1 "%02x"' "$node")
	[ -n "$hex" ] && [ "$(printf '%d' "0x$hex")" = "$SAGE_SKU" ]
}

# cambium_sage_boot_command SLOT
# U-Boot command that boots slot SLOT (0 or 1) on the current board.
cambium_sage_boot_command() {
	local slot="$1"

	printf '%s' "setenv image $slot; setenv bootargs \"$SAGE_KERNEL_MTDPARTS ubi.mtd=$SAGE_UBI_PART root=ubi0:$SAGE_ROOTFS_VOL$slot rootfstype=ubifs rootwait\"; nand device $SAGE_NAND_DEV && setenv mtdids nand$SAGE_NAND_DEV=nand$SAGE_NAND_DEV && setenv mtdparts \"$SAGE_NAND_MTDPARTS\" && ubi part $SAGE_UBI_PART && ubi read $SAGE_LOADADDR $SAGE_KERNEL_VOL$slot && bootm $SAGE_LOADADDR#$SAGE_FIT"
}

# cambium_sage_running_slot
# Print the slot the running system booted from (0 or 1).
cambium_sage_running_slot() {
	sed -n "s/.*root=ubi0:$SAGE_ROOTFS_VOL\([01]\).*/\1/p" "${CAMBIUM_CMDLINE:-/proc/cmdline}"
}
