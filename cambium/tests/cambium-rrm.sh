#!/bin/sh
# Tests for the Cambium RRM measurement agent (package cambium-rrm-agent) and
# the Thor scanning-radio module: the JSON it writes, the scanning interface
# that exists only while scanning, families without a scanning radio, and
# the hotplug step that keeps the scanning radio out of the Wi-Fi config.
# The iw output is modelled on an XV3-8 with its QCA9887 scanning radio.
#
# Usage: cambium/tests/cambium-rrm.sh   (exit status 0 when all pass)

set -u

top=$(cd "$(dirname "$0")/../.." && pwd)
pkg=$top/package/cambium/cambium-rrm-agent/files
W=$(cd "$(mktemp -d)" && pwd -P)
[ -n "${KEEP:-}" ] || trap 'rm -rf "$W"' EXIT HUP INT TERM
pass=0 fail=0

check() { # check DESCRIPTION EXPECTED(0|1) COMMAND...
	local desc=$1 want=$2 got
	shift 2
	( "$@" ) > "$W/out" 2>&1; got=$?
	[ "$got" -ne 0 ] && got=1
	if [ "$got" = "$want" ]; then pass=$((pass + 1)); else
		fail=$((fail + 1)); echo "FAIL: $desc (exit $got, wanted $want)"; sed 's/^/    /' "$W/out"; fi
}
assert() {
	local desc=$1
	shift
	if "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $desc"; fi
}
# jq-like checks with python, on the agent's JSON.
jcheck() { # jcheck DESCRIPTION PYTHON-EXPRESSION (d is the JSON)
	if python3 -c "import json,sys; d=json.load(open('$W/rrm/latest.json')); sys.exit(0 if ($2) else 1)" 2>"$W/py.err"; then
		pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; sed 's/^/    /' "$W/py.err"; fi
}

# --- simulated XV3-8 --------------------------------------------------------------
PCIE=platform/soc@0/10000000.pcie/pci0001:00/0001:00:00.0/0001:01:00.0
AHB=platform/soc@0/c000000.wifi
setup() { # setup BOARD [with-scan-radio]
	rm -rf "$W/sys" "$W/rrm" "$W/state" "$W/calls"
	# Network interfaces: a Wi-Fi one whose address is a BSSID in the scan,
	# and a wired one (no phy80211) with another's.
	mkdir -p "$W/sys/class/net/wlan1_24/phy80211" "$W/sys/class/net/eth0"
	echo FA:11:65:D6:A5:70 > "$W/sys/class/net/wlan1_24/address"
	echo ec:6c:9a:52:d2:6c > "$W/sys/class/net/eth0/address"
	mkdir -p "$W/sys/class/ieee80211" "$W/sys/bus/pci/drivers/ath10k_pci" "$W/sys/bus/platform/drivers/ath11k" "$W/state"
	: > "$W/calls"
	echo "$1" > "$W/board"
	mkdir -p "$W/sys/devices/$AHB"
	ln -s "$W/sys/bus/platform/drivers/ath11k" "$W/sys/devices/$AHB/driver"
	for p in 1 2 3; do
		mkdir -p "$W/sys/devices/$AHB/ieee80211/phy$p"
		ln -s "$W/sys/devices/$AHB" "$W/sys/devices/$AHB/ieee80211/phy$p/device"
		ln -s "$W/sys/devices/$AHB/ieee80211/phy$p" "$W/sys/class/ieee80211/phy$p"
	done
	if [ -n "${2:-}" ]; then
		mkdir -p "$W/sys/devices/$PCIE/ieee80211/phy0"
		ln -s "$W/sys/bus/pci/drivers/ath10k_pci" "$W/sys/devices/$PCIE/driver"
		ln -s "$W/sys/devices/$PCIE" "$W/sys/devices/$PCIE/ieee80211/phy0/device"
		ln -s "$W/sys/devices/$PCIE/ieee80211/phy0" "$W/sys/class/ieee80211/phy0"
	fi
}

mkdir -p "$W/bin"
cat > "$W/bin/iw" <<'EOS'
#!/bin/sh
echo "iw $*" >> "$SIM/calls"
case "$*" in
dev)
	cat <<'EOF'
phy#3
	Interface wlan3_5_low
		ifindex 15
		type AP
		channel 36 (5180 MHz), width: 40 MHz, center1: 5190 MHz
	Interface wlan2_5_low
		type AP
		channel 36 (5180 MHz), width: 40 MHz, center1: 5190 MHz
phy#2
	Interface wlan1_24
		type AP
		channel 11 (2462 MHz), width: 20 MHz, center1: 2462 MHz
phy#1
	Interface wlan3_5
		type AP
		channel 149 (5745 MHz), width: 40 MHz, center1: 5755 MHz
EOF
	[ -f "$SIM/state/scan0" ] && printf 'phy#0\n\tInterface scan0\n\t\ttype managed\n'
	;;
"dev wlan3_5_low station dump") printf 'Station aa:aa:aa:00:00:01 (on wlan3_5_low)\n\tsignal: -60\nStation aa:aa:aa:00:00:02 (on wlan3_5_low)\n' ;;
"dev wlan2_5_low station dump") printf 'Station aa:aa:aa:00:00:03 (on wlan2_5_low)\n' ;;
"dev wlan1_24 station dump"|"dev wlan3_5 station dump") ;;
"dev wlan3_5_low survey dump")
	cat <<'EOF'
Survey data from wlan3_5_low
	frequency:			5180 MHz [in use]
	noise:				-95 dBm
	channel active time:		1000 ms
	channel busy time:		230 ms
	channel receive time:		180 ms
	channel transmit time:		20 ms
Survey data from wlan3_5_low
	frequency:			5200 MHz
	noise:				-96 dBm
	channel active time:		50 ms
	channel busy time:		5 ms
EOF
	;;
"dev "*" survey dump") ;;
"dev "*" scan ap-force")
	# A serving radio's own scan.
	echo "$2" >> "$SIM/state/apscans"
	[ -f "$SIM/state/apfail" ] && { echo 'command failed: Operation not supported (-95)' >&2; exit 1; }
	printf 'BSS 00:11:22:33:44:55(on %s)\n\tfreq: 2437.0\n\tsignal: -70.00 dBm\n\tSSID: Next door\n' "$2"
	;;
"dev scan0 info") [ -f "$SIM/state/scan0" ] ;;
"phy phy0 interface add scan0 type managed") touch "$SIM/state/scan0" ;;
"dev scan0 del") rm -f "$SIM/state/scan0" ;;
"dev scan0 scan")
	[ -f "$SIM/state/scan0" ] || { echo 'command failed: No such device (-19)' >&2; exit 1; }
	n=$(cat "$SIM/state/busy" 2>/dev/null || echo 0)
	[ "$n" -gt 0 ] && { echo $((n - 1)) > "$SIM/state/busy"; echo 'command failed: Device or resource busy (-16)' >&2; exit 1; }
	cat <<'EOF'
BSS 30:cb:c7:8f:f2:b0(on scan0)
	last seen: 120 ms ago
	freq: 2412.0
	signal: -49.00 dBm
	SSID: Dante
BSS fa:11:65:d6:a5:70(on scan0)
	freq: 2412.0
	signal: -14.00 dBm
	SSID: Shine Systems
BSS ec:6c:9a:52:d2:6c(on scan0)
	freq: 5745.0
	signal: -66.00 dBm
	SSID: Joe's "5G" \office
BSS 62:6c:9a:52:d2:6d(on scan0)
	freq: 5500.0
	signal: -81.00 dBm
EOF
	;;
*) echo "unexpected iw $*" >&2; exit 1 ;;
esac
EOS
# The clock: "DATE HH:MM EPOCH" in $SIM/clock, else the real one.
cat > "$W/bin/date" <<'EOS'
#!/bin/sh
[ -f "$SIM/clock" ] || exec /bin/date "$@"
read -r d t e < "$SIM/clock"
case "$1" in
+%s) echo "$e" ;;
'+%Y-%m-%d %H:%M') echo "$d $t" ;;
*) exec /bin/date "$@" ;;
esac
EOS
printf '#!/bin/sh\necho "$*" >> "$SIM/log"\n' > "$W/bin/logger"
cat > "$W/bin/ip" <<'EOS'
#!/bin/sh
echo "ip $*" >> "$SIM/calls"
EOS
printf '#!/bin/sh\nexit 0\n' > "$W/bin/sleep"
# A uci over a "key=value" file, as used by the hotplug step.
cat > "$W/bin/uci" <<'EOS'
#!/bin/sh
db=$SIM/uci
[ "$1" = -q ] && shift
op=$1; arg=${2:-}; key=${arg%%=*}; val=${arg#*=}
get() { awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2) }' "$db"; }
del() { awk -v k="$1" 'index($0, k "=") != 1 && index($0, k ".") != 1' "$db" > "$db.new"; mv "$db.new" "$db"; }
case "$op" in
show) awk -F= -v p="$arg." 'index($0, p) == 1 { k = $1; v = substr($0, length(k) + 2); n = split(k, parts, ".");
	if (n == 2) print k "=" v; else print k "='\''" v "'\''" }' "$db" ;;
get) v=$(get "$key"); [ -n "$v" ] && echo "$v" || exit 1 ;;
set) awk -v k="$key" 'index($0, k "=") != 1' "$db" > "$db.new"; mv "$db.new" "$db"; echo "$key=$val" >> "$db" ;;
delete) del "$key" ;;
commit) echo "commit $arg" >> "$SIM/calls" ;;
esac
exit 0
EOS
chmod +x "$W/bin/"*
cat > "$W/system.sh" <<'EOS'
board_name() { cat "$SIM/board"; }
EOS
mkdir -p "$W/modules"
ln -s "$top/package/cambium/cambium-thor-support/files/cambium-rrm-thor.sh" "$W/modules/"
export PATH="$W/bin:$PATH" SIM=$W RRM_SYS=$W/sys/class/ieee80211 RRM_NET=$W/sys/class/net RRM_OUT=$W/rrm \
	RRM_MODULES=$W/modules CAMBIUM_SYSTEM_FUNCTIONS=$W/system.sh CAMBIUM_RRM_LIB=$pkg/cambium-rrm.sh

agent() { sh "$pkg/cambium-rrm-agent" "$@"; }

# --- XV3-8 with its scanning radio ----------------------------------------------------
setup cambiumnetworks,xv3-8 scan
check "XV3-8 measurement" 0 agent --once
jcheck "the result is valid JSON with version 1" 'd["version"] == 1 and d["board"] == "cambiumnetworks,xv3-8"'
jcheck "the scanning radio is phy0" 'd["scan_radio"] == "phy0"'
jcheck "three serving radios, not the scanning radio" 'sorted(r["phy"] for r in d["radios"]) == ["phy1", "phy2", "phy3"]'
jcheck "phy3: channel 36, 5180 MHz, 40 MHz, both interfaces" '[(r["channel"], r["freq"], r["width"], r["interfaces"]) for r in d["radios"] if r["phy"] == "phy3"] == [(36, 5180, "40 MHz", ["wlan3_5_low", "wlan2_5_low"])]'
jcheck "phy3 clients summed across its interfaces" '[r["clients"] for r in d["radios"] if r["phy"] == "phy3"] == [3]'
jcheck "phy3 survey from the in-use channel" '[r["survey"] for r in d["radios"] if r["phy"] == "phy3"] == [{"noise": -95, "active_ms": 1000, "busy_ms": 230, "rx_ms": 180, "tx_ms": 20}]'
jcheck "no survey is null, not an error" '[r["survey"] for r in d["radios"] if r["phy"] == "phy1"] == [None]'
jcheck "driver recorded" 'all(r["driver"] == "ath11k" for r in d["radios"])'
jcheck "four networks heard" 'len(d["neighbours"]) == 4'
jcheck "neighbours come from the scanning radio, at the measurement time" 'all(x["radio"] == "phy0" and x["time"] == d["time"] for x in d["neighbours"])'
jcheck "neighbour fields and channel numbers" '{k: v for k, v in d["neighbours"][1].items() if k not in ("radio", "time")} == {"bssid": "fa:11:65:d6:a5:70", "ssid": "Shine Systems", "freq": 2412, "channel": 1, "signal": -14, "last_seen_ms": None, "own": True} and d["neighbours"][2]["channel"] == 149 and d["neighbours"][3]["channel"] == 100'
jcheck "quotes and backslashes in an SSID survive" 'd["neighbours"][2]["ssid"] == "Joe'"'"'s \"5G\" \\office"'
jcheck "only the AP's own Wi-Fi addresses are marked own" '[x["own"] for x in d["neighbours"]] == [False, True, False, False]'
jcheck "a hidden SSID is empty" 'd["neighbours"][3]["ssid"] == ""'
assert "scan0 is created for the scan" grep -q "iw phy phy0 interface add scan0 type managed" "$W/calls"
assert "scan0 is removed afterwards" [ ! -f "$W/state/scan0" ]
assert "the serving radios are never scanned" sh -c "! grep -E 'iw dev wlan[^ ]* scan' '$W/calls'"

# A radio still starting refuses the first scans: the agent retries.
setup cambiumnetworks,xv3-8 scan; echo 2 > "$W/state/busy"
check "scan retried while the radio is busy" 0 agent --once
jcheck "the retried scan is recorded" 'len(d["neighbours"]) == 4'
assert "scan0 removed after the retries" [ ! -f "$W/state/scan0" ]
setup cambiumnetworks,xv3-8 scan; echo 9 > "$W/state/busy"
check "a scan that keeps failing still writes a measurement" 0 agent --once
jcheck "no neighbours when the scan fails" 'd["neighbours"] is None and len(d["radios"]) == 3'
assert "scan0 removed after a failed scan" [ ! -f "$W/state/scan0" ]

# --- families without a scanning radio ---------------------------------------------------
setup cambiumnetworks,xv2-21x
check "XV2-21X measurement" 0 agent --once
jcheck "no scanning radio" 'd["scan_radio"] is None and d["neighbours"] is None'
jcheck "its radios are measured" 'len(d["radios"]) == 3'
assert "nothing is scanned or created" sh -c "! grep -E 'scan|interface add' '$W/calls'"
# An XV3-8 image without the scanning radio (the earlier device tree).
setup cambiumnetworks,xv3-8
check "XV3-8 without its scanning radio" 0 agent --once
jcheck "no scanning radio found" 'd["scan_radio"] is None'

# --- scans by the serving radios at scan_times -----------------------------------------------
setup cambiumnetworks,xv2-21x
echo 'cambium_rrm.agent.scan_times=04:00 02:00' > "$W/uci"
at() { echo "$1 $2 $3" > "$W/clock"; }
scans() { cat "$W/state/apscans" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
at 2026-09-27 01:30 1000
check "before the first scan time" 0 agent --once
jcheck "no scan yet: no neighbours" 'd["neighbours"] is None'
assert "no radio has scanned" [ -z "$(scans)" ]
at 2026-09-27 02:05 2000
check "at 02:05" 0 agent --once
assert "the radios without clients scan, once each" [ "$(scans)" = "wlan3_5 wlan1_24" ]
assert "the radio with clients waits" grep -q "phy3 has 3 clients" "$W/log"
jcheck "their networks, with radio and time" 'sorted((x["radio"], x["time"], x["ssid"], x["channel"]) for x in d["neighbours"]) == [("phy1", 2000, "Next door", 6), ("phy2", 2000, "Next door", 6)]'
at 2026-09-27 02:10 2300
check "at 02:10" 0 agent --once
assert "one scan per scan time" [ "$(scans)" = "wlan3_5 wlan1_24" ]
jcheck "the results are kept between scans" 'len(d["neighbours"]) == 2'
at 2026-09-27 04:20 9000
check "at 04:20, the last scan time" 0 agent --once
assert "at the last time, the radio with clients scans too" [ "$(scans)" = "wlan3_5 wlan1_24 wlan3_5 wlan1_24 wlan3_5_low" ]
jcheck "three radios' networks, the latest scan of each" 'sorted((x["radio"], x["time"]) for x in d["neighbours"]) == [("phy1", 9000), ("phy2", 9000), ("phy3", 9000)]'
at 2026-09-27 05:30 13000
check "at 05:30" 0 agent --once
assert "over an hour after a scan time: no scan" [ "$(scans | wc -w)" -eq 5 ]
jcheck "the last results are still reported" 'len(d["neighbours"]) == 3'
touch "$W/state/apfail"
at 2026-09-28 02:01 90000
check "a scan that fails" 0 agent --once
assert "it is retried, then given up" [ "$(scans | wc -w)" -eq 11 ]
assert "the failure is logged" grep -q "phy1 scan failed: command failed: Operation not supported" "$W/log"
jcheck "the earlier results are kept" 'sorted(x["time"] for x in d["neighbours"]) == [9000, 9000, 9000]'
rm -f "$W/state/apfail"
# With a dedicated scanning radio, scan_times does not apply.
setup cambiumnetworks,xv3-8 scan
echo 'cambium_rrm.agent.scan_times=02:00' > "$W/uci"
at 2026-09-27 02:05 2000
check "XV3-8 at a scan time" 0 agent --once
assert "its serving radios never scan" [ -z "$(scans)" ]
jcheck "its neighbours are the scanning radio's" 'len(d["neighbours"]) == 4 and all(x["radio"] == "phy0" for x in d["neighbours"])'
rm -f "$W/clock" "$W/uci"

# --- the scanning radio in /etc/config/wireless ---------------------------------------------
hotplug() { ACTION=add DEVPATH="/devices/$PCIE/ieee80211/phy0" RRM_SYSROOT=$W/sys sh "$pkg/20-cambium-scan-radio"; }
setup cambiumnetworks,xv3-8 scan
# wifi-detect has added the scanning radio with its default network.
printf '%s\n' 'wireless.radio0=wifi-device' "wireless.radio0.path=$PCIE" 'wireless.radio0.band=5g' \
	'wireless.default_radio0=wifi-iface' 'wireless.default_radio0.device=radio0' 'wireless.default_radio0.ssid=OpenWrt' \
	'wireless.radio1=wifi-device' "wireless.radio1.path=$AHB" \
	'wireless.wlan3_5=wifi-iface' 'wireless.wlan3_5.device=radio1' 'wireless.wlan3_5.ssid=phil 5Ghz' > "$W/uci"
check "hotplug for the scanning radio" 0 hotplug
assert "wifi-detect's section and its network are removed" sh -c "! grep -E '^wireless\.(radio0|default_radio0)[.=]' '$W/uci'"
assert "a disabled 'scan' section with the radio's path" [ "$(grep '^wireless\.scan' "$W/uci" | sort | tr '\n' ' ')" = \
	"wireless.scan.disabled=1 wireless.scan.path=$PCIE wireless.scan.type=mac80211 wireless.scan=wifi-device " ]
assert "the serving radio and its network are untouched" [ "$(grep -c '^wireless\.\(radio1\|wlan3_5\)' "$W/uci")" = 5 ]
assert "the change is committed" grep -q 'commit wireless' "$W/calls"
: > "$W/calls"
check "hotplug again" 0 hotplug
assert "already in place: nothing committed" sh -c "! grep -q commit '$W/calls'"
# A serving radio's hotplug, and a board without a scanning radio, change nothing.
cp "$W/uci" "$W/uci.before"
check "hotplug for a serving radio" 0 env ACTION=add DEVPATH="/devices/$AHB/ieee80211/phy1" RRM_SYSROOT=$W/sys sh "$pkg/20-cambium-scan-radio"
assert "serving radio hotplug changes nothing" cmp -s "$W/uci" "$W/uci.before"
echo cambiumnetworks,xv2-21x > "$W/board"
check "hotplug on a board without a scanning radio" 0 hotplug
assert "no scanning radio: nothing changed" cmp -s "$W/uci" "$W/uci.before"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
