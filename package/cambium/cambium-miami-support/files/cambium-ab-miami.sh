#!/bin/sh
# Cambium A/B module for the Miami family (IPQ5332). See cambium-ab.sh.
#
# Each Miami has two 96 MiB NAND firmware banks after 0:TRAINING and
# 0:LICENSE: rootfs (slot 0) at 0xc0000 and rootfs_1 (slot 1) at 0x60c0000.
#
# Before conversion (one OEM bank, one OpenWrt bank) the OEM shell installs
# OpenWrt (miami-oem-install.sh) and arms one guarded boot; after a healthy
# start (root, overlay, management LAN with a reachable gateway) the guard
# re-arms it, otherwise the next boot is the OEM firmware. That boot uses the
# per-slot trees (config@mi01.6-acadia-slot0/-slot1), in which the OEM bank
# stays read-only.
#
# Conversion and A/B sysupgrade use config@mi01.6-acadia-ab (both banks and
# the environment writable). They are implemented but NOT hardware-tested:
# AB_QUALIFIED stays 0, so cambium-ab-convert needs --allow-untested as well
# as the verified OEM backup hash, and refuses while the running tree keeps
# the OEM bank read-only. The radio files that live on the OEM bank are kept
# in the per-bank device-data vault (miami-board-data), which conversion
# requires to be valid before the OEM bank is erased.

case " ${AB_FAMILIES:-} " in
*" miami "*) ;;
*) AB_FAMILIES="${AB_FAMILIES:+$AB_FAMILIES }miami" ;;
esac

ab_miami_board() {
	# Match the board before setting anything: ab_board tries each family in
	# turn and does not reset AB_VAULT_LEBS or AB_BOARD_DATA between them.
	case "$1" in
	cambiumnetworks,x7-35x) AB_MODEL=X7-35X; AB_SKU=0000002c ;;
	*) return 1 ;;
	esac
	AB_NAME=Miami
	AB_ENV=miami
	AB_IMAGE_DIR=sysupgrade-cambiumnetworks_miami
	AB_FIT=config@mi01.6-acadia-ab
	AB_BANK_SIZE=06000000
	AB_SLOT0_OFFSET=0xc0000
	AB_SLOT1_OFFSET=0x60c0000
	AB_BANK_LEBS=724
	AB_PROTECTED='0:NVRAM crashLog 0:ART'
	# Q6 firmware and every regional board file: about 7.5 MB.
	AB_VAULT=1
	AB_VAULT_LEBS=72
	AB_BOARD_DATA=/usr/sbin/miami-board-data
	AB_OWN_BOARD_DATA=1
	# Managed on the VLAN-1 bridge (17_miami_bridge_section). The LAN is
	# the health requirement: without it the unit is reachable only by
	# serial console. Radios are not required.
	AB_LAN='br-lan.1 br-lan'
	AB_RADIOS=0
}

# Boot slot $1 (A/B): the U-Boot sequence validated from the OEM shell,
# without its progress markers.
ab_miami_boot_command() {
	local part offset
	case "$1" in
	0) part=rootfs; offset=$AB_SLOT0_OFFSET ;;
	1) part=rootfs_1; offset=$AB_SLOT1_OFFSET ;;
	*) echo "cambium-ab: invalid slot $1" >&2; return 1 ;;
	esac
	printf 'nand device 0 && setenv mtdids nand0=nand0 && setenv mtdparts mtdparts=nand0:%s@%s(fs) && ubi part fs && ubi read 0x60000000 kernel && setenv bootargs console=ttyMSM0,115200n8 ubi.mtd=%s root=/dev/ubiblock0_1 rootfstype=squashfs rootwait && bootm 0x60000000#%s\n' \
		"$(ab_bank_hex)" "$offset" "$part" "$AB_FIT"
}

# The OEM shell (miami-oem-install.sh boot) saved the validated one-shot in
# miami_start/miami_load/miami_boot; re-arm it only while it still boots
# slot $1 from this bank.
ab_miami_guarded_command() {
	local part offset load boot
	case "$1" in
	0) part=rootfs; offset=$AB_SLOT0_OFFSET ;;
	1) part=rootfs_1; offset=$AB_SLOT1_OFFSET ;;
	*) echo "cambium-ab: invalid slot $1" >&2; return 1 ;;
	esac
	load=$(ab_getenv miami_load) || return 1
	boot=$(ab_getenv miami_boot) || return 1
	case "$load" in
	*"mtdparts=nand0:0x6000000@$offset(fs)"*"ubi read 0x60000000 kernel "*) ;;
	*) echo "cambium-ab: miami_load does not boot slot $1" >&2; return 1 ;;
	esac
	case "$boot" in
	*"ubi.mtd=$part "*"bootm 0x60000000#config@mi01.6-acadia-slot$1;"*) ;;
	*"ubi.mtd=$part "*"bootm 0x60000000#config@mi01.6-acadia-ab;"*) ;;
	*) echo "cambium-ab: miami_boot does not boot slot $1" >&2; return 1 ;;
	esac
	[ "$(ab_getenv miami_start)" = 'setenv bootcmd bootipq; setenv changing_bootcmd; setenv miami_trial entered; saveenv' ] || {
		echo 'cambium-ab: miami_start does not restore bootipq first' >&2
		return 1
	}
	echo 'run miami_start && run miami_load; run miami_fallback'
}

# Reachable, not just addressed: the management default gateway answers.
ab_miami_healthy_extra() {
	local gw
	gw=$(ip -4 route show default 2>/dev/null | awk '$1 == "default" { print $3; exit }')
	[ -n "$gw" ] && ping -c 2 -W 2 "$gw" >/dev/null 2>&1
}
