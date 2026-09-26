#!/bin/sh
# Cambium RRM measurement library, shared by cambium-rrm-agent and the
# scanning-radio hotplug step. See cambium-rrm-agent for what is measured.
#
# Family modules (/lib/functions/cambium-rrm-*.sh) add "BOARD:DRIVER" to
# RRM_SCAN_RADIOS for boards with a dedicated scanning radio. Callers
# provide board_name().
#
# Test hooks: RRM_SYS, RRM_NET, RRM_OUT, RRM_MODULES.

RRM_SYS=${RRM_SYS:-/sys/class/ieee80211}
RRM_NET=${RRM_NET:-/sys/class/net}
RRM_OUT=${RRM_OUT:-/tmp/cambium-rrm}
RRM_SCAN_RADIOS=${RRM_SCAN_RADIOS:-}

for _rrm_module in "${RRM_MODULES:-/lib/functions}"/cambium-rrm-*.sh; do
	[ -f "$_rrm_module" ] && . "$_rrm_module"
done
unset _rrm_module

# The driver of this board's dedicated scanning radio, if it has one.
rrm_scan_driver() {
	local board entry
	board=$(board_name)
	for entry in $RRM_SCAN_RADIOS; do
		[ "${entry%%:*}" = "$board" ] && { echo "${entry#*:}"; return 0; }
	done
	return 1
}

rrm_phy_driver() {
	basename "$(readlink "$RRM_SYS/$1/device/driver")"
}

# The phy of the scanning radio, if this board has one and it is present.
rrm_scan_phy() {
	local driver p
	driver=$(rrm_scan_driver) || return 1
	for p in "$RRM_SYS"/*; do
		[ -e "$p" ] || continue
		[ "$(rrm_phy_driver "${p##*/}")" = "$driver" ] && { echo "${p##*/}"; return 0; }
	done
	return 1
}

# JSON string escaping for values from iw (SSIDs above all).
rrm_json_str() {
	printf '%s' "$1" | awk 'BEGIN { ORS = "" } { gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/[[:cntrl:]]/, ""); print }'
}

# One JSON object per serving radio, comma-separated.
rrm_radios_json() {
	local scan_phy=$1 first=1 phy driver ifaces iface freq width chan clients survey n
	iw dev > "$RRM_OUT/iw-dev.txt" 2>/dev/null
	for p in "$RRM_SYS"/*; do
		[ -e "$p" ] || continue
		phy=${p##*/}
		[ "$phy" = "$scan_phy" ] && continue
		driver=$(rrm_phy_driver "$phy")
		# Interfaces of this phy, with the operating channel of the first.
		ifaces=$(awk -v phy="phy#${phy#phy}" '
			/^phy#/ { on = ($1 == phy) }
			on && $1 == "Interface" { print $2 }' "$RRM_OUT/iw-dev.txt")
		iface=$(echo "$ifaces" | head -n 1)
		freq= width= chan= clients=0 survey=null
		if [ -n "$iface" ]; then
			set -- $(awk -v want="$iface" '
				$1 == "Interface" { on = ($2 == want) }
				on && $1 == "channel" {
					gsub(/[(]/, "", $3)
					w = $0; sub(/.*width: /, "", w); sub(/,.*/, "", w)
					print $2, $3, w; exit
				}' "$RRM_OUT/iw-dev.txt")
			chan=${1:-} freq=${2:-} width=${3:-}${4:+ $4}
			for i in $ifaces; do
				n=$(iw dev "$i" station dump 2>/dev/null | grep -c '^Station')
				clients=$((clients + n))
			done
			survey=$(iw dev "$iface" survey dump 2>/dev/null | awk '
				/^Survey data/ { use = 0 }
				/frequency:/ && /\[in use\]/ { use = 1 }
				use && /noise:/ { noise = $2 }
				use && /channel active time:/ { active = $4 }
				use && /channel busy time:/ { busy = $4 }
				use && /channel receive time:/ { rx = $4 }
				use && /channel transmit time:/ { tx = $4 }
				END {
					if (active == "") { print "null"; exit }
					printf "{\"noise\": %s, \"active_ms\": %s, \"busy_ms\": %s, \"rx_ms\": %s, \"tx_ms\": %s}",
						(noise == "" ? "null" : noise), active, (busy == "" ? "null" : busy),
						(rx == "" ? "null" : rx), (tx == "" ? "null" : tx)
				}')
		fi
		[ -n "$first" ] || printf ',\n'
		first=
		printf '    {"phy": "%s", "driver": "%s", "interfaces": [%s], "channel": %s, "freq": %s, "width": %s, "clients": %s, "survey": %s}' \
			"$phy" "$(rrm_json_str "$driver")" \
			"$(for i in $ifaces; do printf '"%s",' "$(rrm_json_str "$i")"; done | sed 's/,$//')" \
			"${chan:-null}" "${freq:-null}" "$([ -n "$width" ] && printf '"%s"' "$width" || echo null)" \
			"$clients" "${survey:-null}"
	done
	echo
}

# Scan with the scanning radio into $RRM_OUT/scan.txt. The interface is
# created for the scan and removed afterwards.
rrm_scan() {
	local phy=$1 tries=0
	iw dev scan0 info >/dev/null 2>&1 || iw phy "$phy" interface add scan0 type managed || return 1
	ip link set scan0 up || { iw dev scan0 del; return 1; }
	# A scan is refused while the radio is still starting; retry briefly.
	until iw dev scan0 scan > "$RRM_OUT/scan.txt" 2> "$RRM_OUT/scan.err"; do
		tries=$((tries + 1))
		[ "$tries" -lt 3 ] || break
		sleep 2
	done
	ip link set scan0 down
	iw dev scan0 del
	[ "$tries" -lt 3 ]
}

# The MAC addresses of this AP's own Wi-Fi interfaces (its BSSIDs).
rrm_own_bssids() {
	local n
	for n in "$RRM_NET"/*; do
		[ -e "$n/phy80211" ] && cat "$n/address"
	done 2>/dev/null | tr 'A-F' 'a-f' | tr '\n' ' '
}

# One JSON object per network in $RRM_OUT/scan.txt, comma-separated. The
# AP's own networks are included, marked "own": the scanning radio hearing
# them shows they are on the air.
rrm_neighbours_json() {
	awk -v own=" $(rrm_own_bssids) " '
	function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/[[:cntrl:]]/, "", s); return s }
	function chan(f) {
		if (f == 2484) return 14
		if (f >= 2412 && f <= 2472) return (f - 2407) / 5
		if (f >= 5000 && f < 5925) return (f - 5000) / 5
		if (f >= 5955 && f <= 7115) return (f - 5950) / 5
		return "null"
	}
	function flush() {
		if (bssid == "") return
		printf "%s    {\"bssid\": \"%s\", \"ssid\": \"%s\", \"freq\": %s, \"channel\": %s, \"signal\": %s, \"last_seen_ms\": %s, \"own\": %s}",
			(n++ ? ",\n" : ""), bssid, esc(ssid), (freq == "" ? "null" : freq), (freq == "" ? "null" : chan(freq)),
			(signal == "" ? "null" : signal), (seen == "" ? "null" : seen),
			(index(own, " " tolower(bssid) " ") ? "true" : "false")
		bssid = ""
	}
	/^BSS / { flush(); bssid = substr($2, 1, 17); ssid = ""; freq = ""; signal = ""; seen = "" }
	/^\tfreq:/ { freq = int($2) }
	/^\tsignal:/ { signal = $2 + 0 }
	/^\tlast seen:/ { seen = $3 }
	/^\tSSID:/ { ssid = substr($0, index($0, "SSID:") + 6) }
	END { flush(); if (n) print "" }' "$RRM_OUT/scan.txt"
}

rrm_measure() {
	local scan_phy= neighbours=null tmp
	mkdir -p "$RRM_OUT"
	scan_phy=$(rrm_scan_phy) || scan_phy=
	if [ -n "$scan_phy" ] && rrm_scan "$scan_phy"; then
		neighbours="[
$(rrm_neighbours_json)  ]"
	fi
	tmp=$RRM_OUT/latest.json.new
	{
		printf '{\n  "version": 1,\n  "time": %s,\n' "$(date +%s)"
		printf '  "board": "%s",\n  "hostname": "%s",\n' "$(rrm_json_str "$(board_name)")" \
			"$(rrm_json_str "$(cat /proc/sys/kernel/hostname 2>/dev/null)")"
		printf '  "scan_radio": %s,\n' "$([ -n "$scan_phy" ] && printf '"%s"' "$scan_phy" || echo null)"
		printf '  "radios": [\n%s  ],\n' "$(rrm_radios_json "$scan_phy")"
		printf '  "neighbours": %s\n}\n' "$neighbours"
	} > "$tmp" && mv "$tmp" "$RRM_OUT/latest.json"
}
