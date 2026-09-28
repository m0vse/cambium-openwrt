#!/bin/sh
# Cambium RRM measurement library, shared by cambium-rrm-agent and the
# scanning-radio hotplug step. See cambium-rrm-agent for what is measured.
#
# Family modules (/lib/functions/cambium-rrm-*.sh) add "BOARD:DRIVER" to
# RRM_SCAN_RADIOS for boards with a dedicated scanning radio. Callers
# provide board_name().
#
# Neighbouring networks come from the dedicated scanning radio at every
# measurement, where there is one. Elsewhere they come from scans by the
# serving radios at the times in cambium_rrm.agent.scan_times: each such
# scan takes its radio off its channel for a few seconds, so a radio with
# clients waits, except at the day's last scan time.
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
	printf '%s' "$1" | awk '
	function esc(s,   out, i, c) {
		# Character by character: backslashes in gsub replacements differ
		# between awks (BusyBox left them unescaped). Drops control characters.
		out = ""
		for (i = 1; i <= length(s); i++) {
			c = substr(s, i, 1)
			if (c == "\\") out = out "\\\\"
			else if (c == "\"") out = out "\\\""
			else if (c !~ /[[:cntrl:]]/) out = out c
		}
		return out
	}
	BEGIN { ORS = "" } { print esc($0) }'
}

# One JSON object per serving radio, comma-separated.
rrm_radios_json() {
	local scan_phy=$1 first=1 phy driver ifaces iface freq width chan clients survey txpower signal
	iw dev > "$RRM_OUT/iw-dev.txt" 2>/dev/null
	# "phy interface freq clients" per serving radio, for rrm_active_scan.
	: > "$RRM_OUT/radios.txt"
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
		freq= width= chan= clients=0 survey=null txpower= signal=null
		if [ -n "$iface" ]; then
			set -- $(awk -v want="$iface" '
				$1 == "Interface" { on = ($2 == want) }
				on && $1 == "channel" {
					gsub(/[(]/, "", $3)
					w = $0; sub(/.*width: /, "", w); sub(/,.*/, "", w)
					print $2, $3, w; exit
				}' "$RRM_OUT/iw-dev.txt")
			chan=${1:-} freq=${2:-} width=${3:-}${4:+ $4}
			# The transmit power the radio is really using (after the
			# country's limits), for the power planner.
			txpower=$(awk -v want="$iface" '
				$1 == "Interface" { on = ($2 == want) }
				on && $1 == "txpower" { printf "%.1f", $2 + 0; exit }' "$RRM_OUT/iw-dev.txt")
			# Clients over all this radio's networks, and how strongly the
			# radio hears them: weakest, median and strongest.
			for i in $ifaces; do
				iw dev "$i" station dump 2>/dev/null
			done > "$RRM_OUT/stations.txt"
			clients=$(grep -c '^Station' "$RRM_OUT/stations.txt")
			signal=$(awk '/^\tsignal:/ { print $2 + 0 }' "$RRM_OUT/stations.txt" | sort -n | awk '
				{ v[++n] = $1 }
				END {
					if (!n) { print "null"; exit }
					printf "{\"min\": %d, \"median\": %d, \"max\": %d}", v[1], v[int((n + 1) / 2)], v[n]
				}')
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
		[ -n "$iface" ] && echo "$phy $iface ${freq:-0} $clients" >> "$RRM_OUT/radios.txt"
		[ -n "$first" ] || printf ',\n'
		first=
		# Each interface's address (BSSID), so OpenWISP can tell this radio's
		# networks in other APs' scans from outside ones.
		printf '    {"phy": "%s", "driver": "%s", "interfaces": [%s], "bssids": [%s], "channel": %s, "freq": %s, "width": %s, "txpower": %s, "clients": %s, "client_signal": %s, "survey": %s}' \
			"$phy" "$(rrm_json_str "$driver")" \
			"$(for i in $ifaces; do printf '"%s",' "$(rrm_json_str "$i")"; done | sed 's/,$//')" \
			"$(for i in $ifaces; do
				a=$(cat "$RRM_NET/$i/address" 2>/dev/null) && [ -n "$a" ] && printf '"%s",' "$(rrm_json_str "$a")"
			done | sed 's/,$//')" \
			"${chan:-null}" "${freq:-null}" "$([ -n "$width" ] && printf '"%s"' "$width" || echo null)" \
			"${txpower:-null}" "$clients" "${signal:-null}" "${survey:-null}"
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
	# The survey now holds every channel the scan visited.
	iw dev scan0 survey dump > "$RRM_OUT/scan-survey.txt" 2>/dev/null
	ip link set scan0 down
	iw dev scan0 del
	[ "$tries" -lt 3 ]
}

# One JSON object per channel in a survey by RADIO at TIME, comma-separated:
# its noise and its cumulative active and busy time. After a scan the survey
# covers every channel the scan visited, so these show how busy each channel
# is, not only the one the AP is on.
rrm_channels_json() { # rrm_channels_json SURVEY-FILE RADIO TIME
	awk -v radio="$2" -v time="$3" '
	function chan(f) {
		if (f == 2484) return 14
		if (f >= 2412 && f <= 2472) return (f - 2407) / 5
		if (f >= 5000 && f < 5925) return (f - 5000) / 5
		if (f >= 5955 && f <= 7115) return (f - 5950) / 5
		return "null"
	}
	function flush() {
		if (f == "" || a == "" || a == 0) { f = ""; return }
		printf "%s    {\"radio\": \"%s\", \"time\": %s, \"freq\": %d, \"channel\": %s, \"noise\": %s, \"active_ms\": %s, \"busy_ms\": %s}",
			(n++ ? ",\n" : ""), radio, time, f, chan(f), (noise == "" ? "null" : noise), a, (b == "" ? "null" : b)
		f = ""
	}
	/^Survey data/ { flush(); noise = ""; a = ""; b = "" }
	/frequency:/ { f = $2 + 0 }
	/noise:/ { noise = $2 }
	/channel active time:/ { a = $4 }
	/channel busy time:/ { b = $4 }
	END { flush() }' "$1" 2>/dev/null
}

# The MAC addresses of this AP's own Wi-Fi interfaces (its BSSIDs).
rrm_own_bssids() {
	local n
	for n in "$RRM_NET"/*; do
		[ -e "$n/phy80211" ] && cat "$n/address"
	done 2>/dev/null | tr 'A-F' 'a-f' | tr '\n' ' '
}

# One JSON object per network in a scan by RADIO at TIME, comma-separated.
# The AP's own networks are included, marked "own": hearing them shows they
# are on the air.
rrm_neighbours_json() { # rrm_neighbours_json SCAN-FILE RADIO TIME
	awk -v own=" $(rrm_own_bssids) " -v radio="$2" -v time="$3" '
	function esc(s,   out, i, c) {
		# Character by character: backslashes in gsub replacements differ
		# between awks (BusyBox left them unescaped). Drops control characters.
		out = ""
		for (i = 1; i <= length(s); i++) {
			c = substr(s, i, 1)
			if (c == "\\") out = out "\\\\"
			else if (c == "\"") out = out "\\\""
			else if (c !~ /[[:cntrl:]]/) out = out c
		}
		return out
	}
	function chan(f) {
		if (f == 2484) return 14
		if (f >= 2412 && f <= 2472) return (f - 2407) / 5
		if (f >= 5000 && f < 5925) return (f - 5000) / 5
		if (f >= 5955 && f <= 7115) return (f - 5950) / 5
		return "null"
	}
	function flush() {
		if (bssid == "") return
		printf "%s    {\"radio\": \"%s\", \"time\": %s, \"bssid\": \"%s\", \"ssid\": \"%s\", \"freq\": %s, \"channel\": %s, \"signal\": %s, \"last_seen_ms\": %s, \"own\": %s}",
			(n++ ? ",\n" : ""), radio, time, bssid, esc(ssid), (freq == "" ? "null" : freq), (freq == "" ? "null" : chan(freq)),
			(signal == "" ? "null" : signal), (seen == "" ? "null" : seen),
			(index(own, " " tolower(bssid) " ") ? "true" : "false")
		bssid = ""
	}
	/^BSS / { flush(); bssid = substr($2, 1, 17); ssid = ""; freq = ""; signal = ""; seen = "" }
	/^\tfreq:/ { freq = int($2) }
	/^\tsignal:/ { signal = $2 + 0 }
	/^\tlast seen:/ { seen = $3 }
	/^\tSSID:/ {
		ssid = substr($0, index($0, "SSID:") + 6)
		# iw prints the null bytes of a hidden network as \x00: no name.
		if (ssid ~ /^(\\x00)+$/) ssid = ""
	}
	END { flush() }' "$1"
}

# The scan time due now, as "DATE HH:MM [final]": the latest time in
# scan_times that has passed within the last hour. "final" marks the day's
# last scan time.
rrm_scan_due() {
	date '+%Y-%m-%d %H:%M' | awk -v times="$(uci -q get cambium_rrm.agent.scan_times)" '{
		split($2, a, ":"); now = a[1] * 60 + a[2]
		n = split(times, t, " "); best = -1; max = -1
		for (i = 1; i <= n; i++) {
			if (split(t[i], b, ":") != 2) continue
			m = b[1] * 60 + b[2]
			if (m > max) max = m
			if (m <= now && now - m < 60 && m > best) best = m
		}
		if (best < 0) exit 1
		printf "%s %02d:%02d%s\n", $1, int(best / 60), best % 60, (best == max ? " final" : "")
	}'
}

# Each serving radio scans in turn, leaving its channel for a few seconds.
# Its networks go to $RRM_OUT/active-PHY.json, kept until its next scan.
rrm_active_scan() { # rrm_active_scan [final]
	local phy iface freq clients tries now
	while read -r phy iface freq clients; do
		if [ "$clients" -gt 0 ] && [ "${1:-}" != final ]; then
			logger -t cambium-rrm "$phy has $clients clients: its scan waits for the last scan time"
			continue
		fi
		tries=0
		until iw dev "$iface" scan ap-force > "$RRM_OUT/scan-$phy.txt" 2> "$RRM_OUT/scan-$phy.err"; do
			tries=$((tries + 1))
			[ "$tries" -lt 3 ] || break
			sleep 5
		done
		if [ "$tries" -ge 3 ]; then
			logger -t cambium-rrm "$phy scan failed: $(head -n 1 "$RRM_OUT/scan-$phy.err")"
			continue
		fi
		now=$(date +%s)
		rrm_neighbours_json "$RRM_OUT/scan-$phy.txt" "$phy" "$now" > "$RRM_OUT/active-$phy.json"
		iw dev "$iface" survey dump > "$RRM_OUT/survey-$phy.txt" 2>/dev/null
		rrm_channels_json "$RRM_OUT/survey-$phy.txt" "$phy" "$now" > "$RRM_OUT/active-channels-$phy.json"
	done < "$RRM_OUT/radios.txt"
}

rrm_measure() {
	local scan_phy= neighbours= channels= radios due f now tmp
	mkdir -p "$RRM_OUT"
	scan_phy=$(rrm_scan_phy) || scan_phy=
	radios=$(rrm_radios_json "$scan_phy")
	if [ -n "$scan_phy" ]; then
		if rrm_scan "$scan_phy"; then
			now=$(date +%s)
			neighbours=$(rrm_neighbours_json "$RRM_OUT/scan.txt" "$scan_phy" "$now")
			channels=$(rrm_channels_json "$RRM_OUT/scan-survey.txt" "$scan_phy" "$now")
		fi
	else
		if due=$(rrm_scan_due) && [ "$due" != "$(cat "$RRM_OUT/scan-due" 2>/dev/null)" ]; then
			echo "$due" > "$RRM_OUT/scan-due"
			case "$due" in
			*" final") rrm_active_scan final ;;
			*) rrm_active_scan ;;
			esac
		fi
		for f in "$RRM_OUT"/active-phy*.json; do
			[ -s "$f" ] || continue
			neighbours="${neighbours:+$neighbours,
}$(cat "$f")"
		done
		for f in "$RRM_OUT"/active-channels-*.json; do
			[ -s "$f" ] || continue
			channels="${channels:+$channels,
}$(cat "$f")"
		done
	fi
	tmp=$RRM_OUT/latest.json.$$
	{
		printf '{\n  "version": 1,\n  "time": %s,\n' "$(date +%s)"
		printf '  "board": "%s",\n  "hostname": "%s",\n' "$(rrm_json_str "$(board_name)")" \
			"$(rrm_json_str "$(cat /proc/sys/kernel/hostname 2>/dev/null)")"
		printf '  "scan_radio": %s,\n' "$([ -n "$scan_phy" ] && printf '"%s"' "$scan_phy" || echo null)"
		printf '  "radios": [\n%s\n  ],\n' "$radios"
		if [ -n "$neighbours" ]; then
			printf '  "neighbours": [\n%s\n  ],\n' "$neighbours"
		else
			printf '  "neighbours": null,\n'
		fi
		if [ -n "$channels" ]; then
			printf '  "channels": [\n%s\n  ]\n}\n' "$channels"
		else
			printf '  "channels": null\n}\n'
		fi
	} > "$tmp" && mv "$tmp" "$RRM_OUT/latest.json"
}

# Send latest.json to OpenWISP, as the AP registered with openwisp-config
# (openwisp.http: url, uuid, key). Nothing is sent from an unregistered AP.
# A change of outcome is logged, not every attempt.
rrm_upload() {
	local url uuid key code args=
	[ "$(uci -q get cambium_rrm.agent.upload)" != 0 ] || return 0
	url=$(uci -q get openwisp.http.url) || return 0
	uuid=$(uci -q get openwisp.http.uuid) || return 0
	key=$(uci -q get openwisp.http.key) || return 0
	[ -n "$url" ] && [ -n "$uuid" ] && [ -n "$key" ] && [ -s "$RRM_OUT/latest.json" ] || return 0
	# The key goes into curl's config on stdin, written by the shell's own
	# printf, so it never appears in a process's arguments (/proc/*/cmdline).
	# A key that would need quoting there is not one OpenWISP issues.
	case "$key" in *[\"\\]*|*"
"*) logger -t cambium-rrm "upload to OpenWISP: unusable device key"; return 1 ;; esac
	[ "$(uci -q get openwisp.http.verify_ssl)" = 0 ] && args=-k
	[ -n "$(uci -q get openwisp.http.cacert)" ] && args="$args --cacert $(uci -q get openwisp.http.cacert)"
	code=$(printf 'header = "X-Cambium-Key: %s"\n' "$key" |
		curl -sS -K - $args --connect-timeout 10 --max-time 30 -o /dev/null -w '%{http_code}' \
		-H 'Content-Type: application/json' \
		--data-binary "@$RRM_OUT/latest.json" "${url%/}/api/v1/cambium/rrm/$uuid/" 2>/dev/null)
	[ "$code" = "$(cat "$RRM_OUT/upload.status" 2>/dev/null)" ] ||
		logger -t cambium-rrm "upload to OpenWISP: HTTP ${code:-error}"
	echo "$code" > "$RRM_OUT/upload.status"
	[ "$code" = 201 ]
}
