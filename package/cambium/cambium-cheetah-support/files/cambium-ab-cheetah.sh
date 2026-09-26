#!/bin/sh
# Cambium A/B module for the Cheetah family (IPQ5018). See cambium-ab.sh.
#
# Cheetah has a 256 MiB NAND with two 96 MiB firmware banks: rootfs (slot 0)
# at 0x80000, after the 0:TRAINING partition, and rootfs_1 (slot 1) at
# 0x6080000. The boot commands keep the form validated on the XV2-21X and set
# bootargs with the bank, since the stock U-Boot builds its own ubi.mtd.

case " ${AB_FAMILIES:-} " in
*" cheetah "*) ;;
*) AB_FAMILIES="${AB_FAMILIES:+$AB_FAMILIES }cheetah" ;;
esac

ab_cheetah_board() {
	AB_NAME=Cheetah
	AB_ENV=cheetah
	AB_IMAGE_DIR=sysupgrade-cambiumnetworks_cheetah
	AB_VAULT=1
	AB_BANK_SIZE=06000000
	AB_SLOT0_OFFSET=0x80000
	AB_SLOT1_OFFSET=0x6080000
	AB_BANK_LEBS=724
	AB_PROTECTED='0:TRAINING 0:NVRAM crashLog 0:ART'
	case "$1" in
	cambiumnetworks,xv2-21x)
		# Installed, converted and bank-switched by sysupgrade on hardware.
		AB_MODEL=XV2-21X; AB_SKU=00000023; AB_FIT=config@mp03.3-ocelot; AB_QUALIFIED=1
		# Managed on the VLAN-1 bridge; both radios are validated.
		AB_LAN='br-lan.1 br-lan'
		AB_RADIOS=2
		;;
	cambiumnetworks,xv2-22h) AB_MODEL=XV2-22H; AB_SKU=00000022; AB_FIT=config@mp03.3-cheetah ;;
	cambiumnetworks,xv2-23t) AB_MODEL=XV2-23T; AB_SKU=00000024; AB_FIT=config@mp03.3-lynx ;;
	*) return 1 ;;
	esac
}

# The validated XV2-21X boot of a bank, with bootargs selecting slot $1.
ab_cheetah_boot_command() {
	local part offset
	case "$1" in
	0) part=rootfs; offset=$AB_SLOT0_OFFSET ;;
	1) part=rootfs_1; offset=$AB_SLOT1_OFFSET ;;
	*) echo "cambium-ab: invalid slot $1" >&2; return 1 ;;
	esac
	printf 'nand device 0; setenv mtdids nand0=nand0; setenv mtdparts "mtdparts=nand0:%s@%s(fs)"; ubi part fs && ubi read 0x60000000 kernel && setenv bootargs "console=ttyMSM0,115200n8 ubi.mtd=%s root=/dev/ubiblock0_1 rootfstype=squashfs rootwait" && bootm 0x60000000#%s\n' \
		"$(ab_bank_hex)" "$offset" "$part" "$AB_FIT"
}

# One-OEM/one-OpenWrt guarded boot of OpenWrt slot $1: restore the stock
# default first, as the validated XV2-21X guard did, and fall back to it.
ab_cheetah_guarded_command() {
	local boot
	boot=$(ab_cheetah_boot_command "$1") || return 1
	echo "setenv bootcmd bootipq; setenv changing_bootcmd; saveenv; $boot; bootipq"
}
