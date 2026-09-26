#!/bin/sh
# Generated from cambium/families.json by cambium/scripts/gen-select-config.py.
# Run on the access point's stock firmware as root:
#   sh select-config.sh recovery|installer|persistent
# Prints FAMILY, MODEL, SKU, CONFIG and STATUS as shell assignments, e.g.
#   eval "$(sh select-config.sh recovery)" && echo "$CONFIG"
# Exits non-zero, printing nothing on stdout, for an unknown SKU, an image
# that is not built for this model, or a persistent or installer image for a
# model that is not yet validated (those get the recovery image only).

flavour=${1:-}
case "$flavour" in
recovery|installer|persistent) ;;
*) echo "usage: $0 recovery|installer|persistent" >&2; exit 2 ;;
esac

sku=
node=${CAMBIUM_SKU_NODE:-/proc/device-tree/cambium-platform/board-sku}
if [ -r "$node" ]; then
	# The stock firmware has od; OpenWrt's BusyBox has hexdump instead.
	hex=$(od -An -tx1 "$node" 2>/dev/null | tr -d ' \n')
	[ -n "$hex" ] || hex=$(hexdump -v -e '1/1 "%02x"' "$node" 2>/dev/null)
	[ -n "$hex" ] && sku=$(printf '%d' "0x$hex")
fi
if [ -z "$sku" ] && [ -r /proc/sku ]; then
	sku=$(tr -dc '0-9' < /proc/sku)
fi
[ -n "$sku" ] || { echo "Cannot read the board SKU on this firmware" >&2; exit 1; }

family= model=
case "$sku" in
	6)
		family=gambit model=E400
		recovery_status=no-build recovery_note='no OpenWrt build for this family yet'
		persistent_status=no-build persistent_note='no OpenWrt build for this family yet'
		;;
	7)
		family=gambit model=E500
		recovery_status=no-build recovery_note='no OpenWrt build for this family yet'
		persistent_status=no-build persistent_note='no OpenWrt build for this family yet'
		;;
	9)
		family=gambit model=E501S
		recovery_status=no-build recovery_note='no OpenWrt build for this family yet'
		persistent_status=no-build persistent_note='no OpenWrt build for this family yet'
		;;
	12)
		family=gambit model=E502S
		recovery_status=no-build recovery_note='no OpenWrt build for this family yet'
		persistent_status=no-build persistent_note='no OpenWrt build for this family yet'
		;;
	10)
		family=sage model=E410
		recovery_config=config@5 recovery_status=validated
		persistent_config=config@ap.dk01.1-c2 persistent_status=validated
		;;
	11)
		family=sage model=E600
		recovery_config=config@10 recovery_status=untested
		persistent_config=config@10 persistent_status=untested
		;;
	13)
		family=sage model=E430W
		recovery_config=config@13 recovery_status=untested
		persistent_config=config@13 persistent_status=untested
		;;
	14)
		family=sage model=E700
		recovery_config=config@14 recovery_status=untested
		persistent_config=config@14 persistent_status=untested
		;;
	15)
		family=sage model=E430H
		recovery_config=config@15 recovery_status=untested
		persistent_config=config@15 persistent_status=untested
		;;
	16)
		family=sage model=E510
		recovery_config=config@16 recovery_status=untested
		persistent_config=config@16 persistent_status=untested
		;;
	21)
		family=sage model=E410B
		recovery_config=config@5 recovery_status=validated
		persistent_config=config@ap.dk01.1-c2 persistent_status=validated
		;;
	17)
		family=lila model=E425W
		recovery_status=no-build recovery_note='no OpenWrt build for this family yet'
		persistent_status=no-build persistent_note='no OpenWrt build for this family yet'
		;;
	18)
		family=lila model=E505
		recovery_status=no-build recovery_note='no OpenWrt build for this family yet'
		persistent_status=no-build persistent_note='no OpenWrt build for this family yet'
		;;
	19)
		family=thor model=XV3-8
		recovery_config=config@hk02 recovery_status=validated
		installer_config=config@hk02 installer_status=validated
		persistent_config=config@hk02 persistent_status=validated
		;;
	30)
		family=thor model=XE5-8
		recovery_config=config@hk01.c6 recovery_status=untested
		installer_status=not-built installer_note='flash layout not yet captured'
		persistent_status=not-built persistent_note='flash layout not yet captured'
		;;
	20)
		family=jaguar model=XV2-2
		recovery_config=config@cp01-c1 recovery_status=validated
		persistent_config=config@cp01-c1 persistent_status=validated
		;;
	22)
		family=jaguar model=XV2-2T0
		recovery_config=config@cp01-c1-1 recovery_status=untested
		persistent_config=config@cp01-c1-1 persistent_status=untested
		;;
	31)
		family=jaguar model=XV2-2T1
		recovery_config=config@cp01-c1-2 recovery_status=validated
		persistent_config=config@cp01-c1-2 persistent_status=validated
		;;
	32)
		family=jaguar model=XE3-4
		recovery_config=config@cp01-c3-xv3-4 recovery_status=untested
		persistent_config=config@cp01-c3-xv3-4 persistent_status=untested
		;;
	33)
		family=jaguar model=XE3-4TN
		recovery_config=config@cp01-c3-2 recovery_status=untested
		persistent_config=config@cp01-c3-2 persistent_status=untested
		;;
	34)
		family=cheetah model=XV2-22H
		recovery_config=config@mp03.3-cheetah recovery_status=untested
		persistent_config=config@mp03.3-cheetah persistent_status=untested
		;;
	35)
		family=cheetah model=XV2-21X
		recovery_config=config@mp03.3-ocelot recovery_status=validated
		persistent_config=config@mp03.3-ocelot persistent_status=validated
		;;
	36)
		family=cheetah model=XV2-23T
		recovery_config=config@mp03.3-lynx recovery_status=untested
		persistent_config=config@mp03.3-lynx persistent_status=untested
		;;
	42)
		family=miami model=X7-55X
		recovery_status=no-build recovery_note='no OpenWrt build for this family yet'
		persistent_status=no-build persistent_note='no OpenWrt build for this family yet'
		;;
	43)
		family=miami model=X7-56X
		recovery_status=no-build recovery_note='no OpenWrt build for this family yet'
		persistent_status=no-build persistent_note='no OpenWrt build for this family yet'
		;;
	44)
		family=miami model=X7-35X
		recovery_status=no-build recovery_note='no OpenWrt build for this family yet'
		persistent_status=no-build persistent_note='no OpenWrt build for this family yet'
		;;
	49)
		family=miami model=X7-53X
		recovery_status=no-build recovery_note='no OpenWrt build for this family yet'
		persistent_status=no-build persistent_note='no OpenWrt build for this family yet'
		;;
	*) echo "Unknown board SKU $sku: not a known Cambium model, do not install" >&2; exit 1 ;;
esac

eval "config=\${${flavour}_config:-} status=\${${flavour}_status:-} note=\${${flavour}_note:-}"
if [ -z "$status" ]; then
	echo "$model (SKU $sku, $family): no $flavour image for this family" >&2
	exit 1
fi
if [ -z "$config" ]; then
	echo "$model (SKU $sku, $family): no $flavour image: $note" >&2
	exit 1
fi
# Until a model is validated only its recovery (RAM) image may be used; the
# report from that boot is what validation starts from.
if [ "$status" != validated ]; then
	if [ "$flavour" = recovery ]; then
		echo "Warning: $model has not been validated. RAM boot only; in the booted image run" >&2
		echo "cambium-report.sh and attach the report to an issue." >&2
	elif [ "${CAMBIUM_HARDWARE_TRIAL:-}" = 1 ]; then
		echo "Warning: $model $flavour image is $status; CAMBIUM_HARDWARE_TRIAL=1 overrides" >&2
		echo "the RAM-only rule for a hardware trial on a unit you can recover." >&2
	else
		echo "$model (SKU $sku, $family): the $flavour image is $status on this model." >&2
		echo "Only the recovery (RAM) image may be used until the model is validated:" >&2
		echo "RAM-boot it, run cambium-report.sh and open an issue with the report." >&2
		exit 1
	fi
fi
printf "FAMILY='%s'\nMODEL='%s'\nSKU='%s'\nCONFIG='%s'\nSTATUS='%s'\n" \
	"$family" "$model" "$sku" "$config" "$status"
