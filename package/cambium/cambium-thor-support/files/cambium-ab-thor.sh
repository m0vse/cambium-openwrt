#!/bin/sh
# Cambium A/B module for the Thor family (IPQ8074). See cambium-ab.sh.
#
# The XV3-8 has two 96 MiB NAND firmware banks, rootfs (slot 0) at 0x0 and
# rootfs_1 (slot 1) at 0x6000000. Its stock U-Boot default is
# "aq_load_fw&&bootipq": the Aquantia PHY firmware must be loaded before any
# boot. The persistent FIT selects the bank through its configuration rather
# than U-Boot bootargs: config@hk02 appends ubi.mtd=rootfs (as the validated
# single-bank installs do) and config@hk02-bank1 appends ubi.mtd=rootfs_1.

case " ${AB_FAMILIES:-} " in
*" thor "*) ;;
*) AB_FAMILIES="${AB_FAMILIES:+$AB_FAMILIES }thor" ;;
esac

ab_thor_board() {
	AB_NAME=Thor
	AB_ENV=thor
	# The sysupgrade tar keeps the directory installed XV3-8 images expect.
	AB_IMAGE_DIR=sysupgrade-cambiumnetworks_xv3-8
	AB_VAULT=1
	AB_STOCK_BOOTCMD='aq_load_fw&&bootipq'
	AB_BANK_SIZE=06000000
	AB_SLOT1_OFFSET=0x6000000
	AB_BANK_LEBS=724
	AB_PROTECTED='0:ETHPHYFW 0:ART'
	case "$1" in
	cambiumnetworks,xv3-8)
		AB_MODEL=XV3-8; AB_SKU=00000013; AB_FIT=config@hk02
		# Managed on the VLAN-1 bridge once OpenWISP's trunk template has
		# applied; all three radios are validated.
		AB_LAN='br-lan.1 br-lan'
		AB_RADIOS=3
		;;
	*) return 1 ;;
	esac
}

# Boot slot $1: the validated single-bank Thor command, with the bank and
# its FIT configuration selected.
ab_thor_boot_command() {
	local mtdparts part config
	case "$1" in
	0) mtdparts="$(ab_bank_hex)@0x0(rootfs)"; part=rootfs; config=$AB_FIT ;;
	1) mtdparts="$(ab_bank_hex)@$AB_SLOT1_OFFSET(fs)"; part=fs; config=$AB_FIT-bank1 ;;
	*) echo "cambium-ab: invalid slot $1" >&2; return 1 ;;
	esac
	printf 'aq_load_fw; nand device 0 && setenv mtdids nand0=nand0 && setenv mtdparts "mtdparts=nand0:%s" && ubi part %s && ubi read 0x60000000 kernel && bootm 0x60000000#%s\n' \
		"$mtdparts" "$part" "$config"
}

# One-OEM/one-OpenWrt guarded boot of OpenWrt slot $1: restore the stock
# default first, as the validated Thor one-shots did, and fall back to it.
ab_thor_guarded_command() {
	local boot
	boot=$(ab_thor_boot_command "$1") || return 1
	echo "setenv changing_bootcmd; setenv bootcmd \"aq_load_fw&&bootipq\"; saveenv; $boot; bootipq"
}
