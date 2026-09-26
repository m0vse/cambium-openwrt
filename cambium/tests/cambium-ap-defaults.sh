#!/bin/sh
# Tests for the 12_cambium_ap first-boot script: on a Cambium AP (persistent
# or recovery) the LAN never offers DHCP or router advertisements, and
# irqbalance is switched on where the image has it. Upstream images are
# left alone.
#
# Usage: cambium/tests/cambium-ap-defaults.sh   (exit status 0 when all pass)

set -u

top=$(cd "$(dirname "$0")/../.." && pwd)
script=$top/package/base-files/files/etc/uci-defaults/12_cambium_ap
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT HUP INT TERM
pass=0 fail=0

# A small uci over a "key=value" file.
mkdir -p "$W/bin"
cat > "$W/bin/uci" <<'EOS'
#!/bin/sh
db=$SIM/uci
[ "$1" = -q ] && shift
op=$1; arg=${2:-}; key=${arg%%=*}; val=${arg#*=}
case "$op" in
get) awk -v k="$key" 'index($0, k "=") == 1 || index($0, k ".") == 1 { f = 1 } END { exit !f }' "$db" && echo x ;;
set) awk -v k="$key" 'index($0, k "=") != 1' "$db" > "$db.new"; mv "$db.new" "$db"; echo "$key=$val" >> "$db" ;;
commit) echo "commit $arg" >> "$SIM/commits" ;;
esac
EOS
chmod +x "$W/bin/uci"
export PATH="$W/bin:$PATH" SIM=$W CAMBIUM_ROOT=$W/root

expect() { # expect DESCRIPTION WANT GOT
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); else
		fail=$((fail + 1)); echo "FAIL: $1: got '$3', want '$2'"; fi
}
val() { sed -n "s/^$1=//p" "$W/uci"; }
run() { # run CAMBIUM(0|1) IRQBALANCE(0|1)
	rm -rf "$W/root" "$W/commits"
	mkdir -p "$W/root/proc/device-tree"
	[ "$1" = 1 ] && mkdir "$W/root/proc/device-tree/cambium-platform"
	printf '%s\n' 'dhcp.lan.start=100' > "$W/uci"
	[ "$2" = 1 ] && echo 'irqbalance.@irqbalance[0].enabled=0' >> "$W/uci"
	sh "$script"
}

run 1 1
expect "exits cleanly" 0 $?
expect "no DHCP or RA on the LAN" '1 disabled disabled disabled' \
	"$(val dhcp.lan.ignore) $(val dhcp.lan.dhcpv4) $(val dhcp.lan.dhcpv6) $(val dhcp.lan.ra)"
expect "irqbalance on" 1 "$(val 'irqbalance.@irqbalance\[0\].enabled')"
expect "both committed" 'commit dhcp commit irqbalance' "$(tr '\n' ' ' < "$W/commits" | sed 's/ $//')"

run 1 0
expect "without irqbalance: DHCP still off" 1 "$(val dhcp.lan.ignore)"
expect "without irqbalance: no irqbalance section made" '' "$(grep irqbalance "$W/uci")"

run 0 1
expect "upstream image untouched" '' "$(val dhcp.lan.ignore)$(cat "$W/commits" 2>/dev/null)"
expect "upstream image: irqbalance left off" 0 "$(val 'irqbalance.@irqbalance\[0\].enabled')"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
