#!/bin/sh
# Cambium A/B module for the Jaguar family (IPQ6018). See cambium-ab.sh.
#
# Each Jaguar has two NAND firmware banks, rootfs (slot 0) and rootfs_1
# (slot 1), whose size depends on the NAND: two 96 MiB banks on the 256 MiB
# models (captured on the XV2-2T1, OEM 7.2-r1) and two 52 MiB banks on the
# XV2-2's 128 MiB NAND. The identity preflight re-checks the layout on every
# unit instead of assuming it.

case " ${AB_FAMILIES:-} " in
*" jaguar "*) ;;
*) AB_FAMILIES="${AB_FAMILIES:+$AB_FAMILIES }jaguar" ;;
esac

ab_jaguar_board() {
	AB_NAME=Jaguar
	AB_ENV=jaguar
	AB_IMAGE_DIR=sysupgrade-cambiumnetworks_jaguar
	AB_VAULT=1
	AB_BANK_SIZE=06000000
	AB_SLOT1_OFFSET=0x6000000
	AB_BANK_LEBS=724
	AB_PROTECTED='NVRAM crashLog 0:ART'
	case "$1" in
	cambiumnetworks,xv2-2)
		# 128 MiB Winbond NAND: 416-PEB banks, 20 reserved + 4.
		AB_MODEL=XV2-2; AB_SKU=00000014; AB_FIT=config@cp01-c1; AB_QUALIFIED=1
		AB_BANK_SIZE=03400000
		AB_SLOT1_OFFSET=0x3400000
		AB_BANK_LEBS=392
		AB_PROTECTED='0:NVRAM crashlog 0:ART'
		;;
	cambiumnetworks,xv2-2t0) AB_MODEL=XV2-2T0; AB_SKU=00000016; AB_FIT=config@cp01-c1-1 ;;
	cambiumnetworks,xv2-2t1) AB_MODEL=XV2-2T1; AB_SKU=0000001f; AB_FIT=config@cp01-c1-2; AB_QUALIFIED=1 ;;
	cambiumnetworks,xe3-4) AB_MODEL=XE3-4; AB_SKU=00000020; AB_FIT=config@cp01-c3-xv3-4 ;;
	cambiumnetworks,xe3-4tn) AB_MODEL=XE3-4TN; AB_SKU=00000021; AB_FIT=config@cp01-c3-2 ;;
	*) return 1 ;;
	esac
}

# Boot slot $1: the validated slot-0 guard command apart from the bank.
ab_jaguar_boot_command() {
	local part offset
	case "$1" in
	0) part=rootfs; offset=0x0 ;;
	1) part=rootfs_1; offset=$AB_SLOT1_OFFSET ;;
	*) echo "cambium-ab: invalid slot $1" >&2; return 1 ;;
	esac
	printf 'nand device 0 && setenv mtdids nand0=nand0 && setenv mtdparts "mtdparts=nand0:%s@%s(fs)" && ubi part fs && ubi read 0x60000000 kernel && setenv bootargs "console=ttyMSM0,115200n8 cnss2.bdf_pci0=0xab ubi.mtd=%s root=/dev/ubiblock0_1 rootfstype=squashfs rootwait swiotlb=1" && bootm 0x60000000#%s\n' \
		"$(ab_bank_hex)" "$offset" "$part" "$AB_FIT"
}

# One-OEM/one-OpenWrt guarded boot of OpenWrt slot $1. Slot 0 is the command
# validated on the XV2-2T1; slot 1 uses the "(fs)" / "ubi part fs" form that
# booted the XV2-2 from its slot 1.
ab_jaguar_guarded_command() {
	local mtdparts part
	case "$1" in
	0) mtdparts="$(ab_bank_hex)@0x0(rootfs)"; part=rootfs ;;
	1) mtdparts="$(ab_bank_hex)@$AB_SLOT1_OFFSET(fs)"; part=fs ;;
	*) echo "cambium-ab: invalid slot $1" >&2; return 1 ;;
	esac
	echo "setenv bootcmd bootipq; setenv changing_bootcmd; saveenv; nand device 0 && setenv mtdids nand0=nand0 && setenv mtdparts \"mtdparts=nand0:$mtdparts\" && ubi part $part && ubi read 0x60000000 kernel && setenv bootargs \"console=ttyMSM0,115200n8 cnss2.bdf_pci0=0xab ubi.mtd=$(ab_bank_name "$1") root=/dev/ubiblock0_1 rootfstype=squashfs rootwait swiotlb=1\" && bootm 0x60000000#$AB_FIT; reset"
}
