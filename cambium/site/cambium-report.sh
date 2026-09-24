#!/bin/sh
# cambium-report.sh: collect read-only hardware information from a Cambium
# access point for a cambium-openwrt hardware report.
#
# Run as root, preferably in the OpenWrt recovery (RAM) image, and also on
# the stock firmware if you can:
#   sh /tmp/cambium-report.sh
# It writes /tmp/cambium-report-SKU-TIME.txt; attach that file to an issue
# at https://github.com/m0vse/cambium-openwrt/issues/new/choose
#
# The script only reads. It never writes flash, attaches UBI devices,
# changes the U-Boot environment or mounts anything, and it copies no
# partition contents: no firmware, calibration (ART) or board-data files,
# only their names, sizes and hashes. MAC addresses keep their vendor half
# (OUI) and the rest is masked; U-Boot variables that look like serial
# numbers, keys or passwords are masked. Read the file before posting it.
#
# Options: --no-redact  keep MAC addresses and masked variables as they are

REPORT_VERSION=1
redact=1
[ "${1:-}" = --no-redact ] && redact=

PATH=/usr/sbin:/usr/bin:/sbin:/bin:$PATH
have() { command -v "$1" >/dev/null 2>&1; }

sku_hex=
# The stock firmware has od; OpenWrt's BusyBox has hexdump instead.
hex_bytes() {
	local h
	h=$(od -An -tx1 "$1" 2>/dev/null | tr -d ' \n')
	[ -n "$h" ] || h=$(hexdump -v -e '1/1 "%02x"' "$1" 2>/dev/null)
	echo "$h"
}
[ -r /proc/device-tree/cambium-platform/board-sku ] &&
	sku_hex=$(hex_bytes /proc/device-tree/cambium-platform/board-sku)
sku=unknown
[ -n "$sku_hex" ] && sku=$(printf '%d' "0x$sku_hex")
[ "$sku" = unknown ] && [ -r /proc/sku ] && sku=$(tr -dc '0-9' < /proc/sku)
out=${CAMBIUM_REPORT_OUT:-/tmp/cambium-report-sku${sku}-$(date -u +%Y%m%d-%H%M%S).txt}

section() { printf '\n===== %s =====\n' "$1"; }
# show TITLE COMMAND...: run a read-only command if it exists.
show() {
	local title=$1
	shift
	have "$1" || return 0
	section "$title"
	"$@" 2>&1
}
showfile() {
	local f
	for f; do
		[ -r "$f" ] && [ -f "$f" ] || continue
		section "$f"
		cat "$f" 2>&1
	done
}
# A device-tree property as text (strings) or hex (cells).
dt_text() { [ -r "$1" ] && tr '\000' ' ' < "$1"; }
dt_hex() {
	[ -r "$1" ] || return 0
	od -An -tx4 "$1" 2>/dev/null | tr -s ' \n' ' ' | grep . ||
		hexdump -v -e '4/1 "%02x" " "' "$1" 2>/dev/null
}

# MAC addresses keep their vendor half (OUI).
mask() {
	if [ -n "$redact" ]; then
		sed -E 's/(([0-9a-fA-F]{2}[:-]){3})[0-9a-fA-F]{2}[:-][0-9a-fA-F]{2}[:-][0-9a-fA-F]{2}/\1xx:xx:xx/g'
	else
		cat
	fi
}
# U-Boot variables that may identify the unit or hold a secret.
mask_env() {
	if [ -n "$redact" ]; then
		mask | sed -E 's/^([^=]*(serial|[Ss][Nn]$|passw|secret|key|token|psk|cloud|maestro)[^=]*=).*/\1<masked>/'
	else
		cat
	fi
}

collect() {
	section "cambium-report $REPORT_VERSION"
	echo "date: $(date -u)"
	echo "board-sku: $sku (hex ${sku_hex:-none})"
	if [ -r /etc/openwrt_release ]; then
		echo "running: OpenWrt"
	else
		echo "running: stock (or other) firmware"
	fi
	echo "redaction: ${redact:+on}${redact:-off}"

	section identity
	echo "board_name: $(cat /tmp/sysinfo/board_name 2>/dev/null)"
	echo "sysinfo model: $(cat /tmp/sysinfo/model 2>/dev/null)"
	echo "dt model: $(dt_text /proc/device-tree/model)"
	echo "dt compatible: $(dt_text /proc/device-tree/compatible)"
	echo "dt cambium-platform: $(ls /proc/device-tree/cambium-platform 2>/dev/null | tr '\n' ' ')"
	showfile /proc/cmdline /proc/version /etc/openwrt_release /etc/cambium-openwrt-release \
		/etc/os-release /etc/version /version /etc/issue
	show 'uname -a' uname -a

	section 'stock firmware version files'
	for f in /etc/*version* /etc/*release* /var/*version* /tmp/*version*; do
		[ -f "$f" ] && [ -r "$f" ] && { echo "--- $f"; head -n 20 "$f"; }
	done 2>/dev/null

	showfile /proc/cpuinfo /proc/meminfo
	show uptime uptime

	section 'flash: /proc/mtd'
	cat /proc/mtd 2>&1
	section 'flash: MTD details (sysfs)'
	for d in /sys/class/mtd/mtd*; do
		case "${d##*/}" in *ro) continue ;; esac
		[ -d "$d" ] || continue
		printf '%s:' "${d##*/}"
		for a in name type size erasesize writesize oobsize subpagesize flags \
			ecc_strength ecc_step_size bitflip_threshold numeraseregions; do
			[ -r "$d/$a" ] && printf ' %s=%s' "$a" "$(cat "$d/$a" 2>/dev/null)"
		done
		echo
	done
	section 'flash: device-tree partitions'
	find /proc/device-tree -path '*partition*' -name label 2>/dev/null | sort | while read -r l; do
		n=${l%/label}
		printf '%s label=%s reg=%s%s\n' "${n#/proc/device-tree}" "$(dt_text "$l")" \
			"$(dt_hex "$n/reg")" "$([ -e "$n/read-only" ] && echo ' read-only')"
	done
	showfile /proc/partitions
	section 'flash: UBI (attached devices only)'
	if have ubinfo; then
		ubinfo -a 2>&1
	else
		for d in /sys/class/ubi/ubi*; do
			[ -d "$d" ] || continue
			printf '%s:' "${d##*/}"
			for a in name mtd_num eraseblock_size total_eraseblocks avail_eraseblocks \
				bad_peb_count reserved_for_bad max_ec data_bytes reserved_ebs type; do
				[ -r "$d/$a" ] && printf ' %s=%s' "$a" "$(cat "$d/$a" 2>/dev/null)"
			done
			echo
		done
	fi
	show mounts cat /proc/mounts
	show df df -k

	section 'U-Boot environment (read only)'
	if have fw_printenv; then
		fw_printenv 2>&1 | mask_env
	else
		echo 'fw_printenv not available'
	fi
	showfile /etc/fw_env.config /tmp/fw_env.config

	section 'Wi-Fi firmware and board-data files (names, sizes, hashes only)'
	for dir in /lib/firmware /tmp/lib/firmware; do
		[ -d "$dir" ] || continue
		find "$dir" -type f \( -name 'bdwlan*' -o -name 'board*.bin' -o -name 'caldata*' \
			-o -name '*.mdt' -o -name 'regdb*' \) 2>/dev/null | sort | while read -r f; do
			printf '%s %s %s\n' "$(wc -c < "$f" 2>/dev/null)" \
				"$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1)" "$f"
		done
	done
	showfile /tmp/cambium-board-data.status
	show 'cambium-ab-status' cambium-ab-status
	show 'jaguar-ab-status (older images)' jaguar-ab-status

	section 'PCI devices'
	for d in /sys/bus/pci/devices/*; do
		[ -d "$d" ] && echo "${d##*/} vendor=$(cat "$d/vendor") device=$(cat "$d/device") class=$(cat "$d/class")"
	done 2>/dev/null
	section 'USB devices'
	for d in /sys/bus/usb/devices/*; do
		[ -r "$d/idVendor" ] && echo "${d##*/} $(cat "$d/idVendor"):$(cat "$d/idProduct") $(cat "$d/product" 2>/dev/null)"
	done 2>/dev/null

	section network
	if have ip; then
		ip -d link 2>&1 | mask
		ip addr 2>&1 | mask
		ip route 2>&1
	else
		ifconfig -a 2>&1 | mask
		route -n 2>&1
	fi
	for n in /sys/class/net/*; do
		[ -d "$n" ] || continue
		echo "${n##*/}: carrier=$(cat "$n/carrier" 2>/dev/null) speed=$(cat "$n/speed" 2>/dev/null) phydev=$(basename "$(readlink "$n/phydev" 2>/dev/null)" 2>/dev/null) driver=$(basename "$(readlink "$n/device/driver" 2>/dev/null)" 2>/dev/null)"
	done
	if have ethtool; then
		for n in /sys/class/net/*; do
			i=${n##*/}
			[ "$i" = lo ] && continue
			section "ethtool $i"
			ethtool "$i" 2>&1
			ethtool -i "$i" 2>&1
		done
	fi
	have swconfig && { section swconfig; swconfig list 2>&1; }
	show 'mdio devices' sh -c 'ls /sys/bus/mdio_bus/devices 2>/dev/null; for d in /sys/bus/mdio_bus/devices/*; do echo "${d##*/} phy_id=$(cat $d/phy_id 2>/dev/null)"; done'

	section wifi
	ls /sys/class/ieee80211 2>&1
	show 'iw dev' iw dev
	have iw && { section 'iw phy'; iw phy 2>&1 | grep -E '^Wiphy|Band|MHz \[|Capabilities|HE |EHT |valid interface'; }

	section 'LEDs, buttons and GPIO'
	ls /sys/class/leds 2>&1
	showfile /proc/bus/input/devices /sys/kernel/debug/gpio
	for c in /sys/class/gpio/gpiochip*; do
		[ -d "$c" ] && echo "${c##*/} label=$(cat "$c/label") base=$(cat "$c/base") ngpio=$(cat "$c/ngpio")"
	done 2>/dev/null

	section 'sensors'
	for h in /sys/class/hwmon/hwmon*; do
		[ -d "$h" ] || continue
		echo "${h##*/} $(cat "$h/name" 2>/dev/null) $(cat "$h"/temp*_input 2>/dev/null | tr '\n' ' ')"
	done
	for t in /sys/class/thermal/thermal_zone*; do
		[ -d "$t" ] && echo "${t##*/} $(cat "$t/type" 2>/dev/null) $(cat "$t/temp" 2>/dev/null)"
	done

	show 'kernel modules' cat /proc/modules
	showfile /proc/interrupts /proc/iomem
	showfile /etc/board.json
	show 'ubus system board' ubus call system board
	section 'kernel log (dmesg)'
	dmesg 2>&1 | mask
	have logread && { section 'system log (last 300 lines)'; logread 2>&1 | tail -n 300 | mask; }
	section end
}

umask 077
collect > "$out" 2>&1
echo "Report written to $out ($(wc -c < "$out" | tr -d " ") bytes)."
echo 'Read it, copy it off the access point (scp -O, or tftp -p on the stock firmware),'
echo 'and attach it to an issue: https://github.com/m0vse/cambium-openwrt/issues/new/choose'
