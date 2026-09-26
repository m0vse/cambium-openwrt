#!/bin/sh
# Tests for the first-boot management VLAN scripts of every family: on a
# fresh install the LAN bridge filters VLANs and carries only untagged
# VLAN 1 on the LAN ports, so tagged traffic (e.g. a busy VLAN 101 on the
# same trunk) cannot swamp DHCP; an existing OpenWISP trunk is left alone.
#
# Usage: cambium/tests/cambium-vlan.sh   (exit status 0 when all pass)

set -u

top=$(cd "$(dirname "$0")/../.." && pwd)
pkg=$top/package/cambium
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT HUP INT TERM
pass=0 fail=0

# A small uci over a "key=value" file; lists are space-separated values.
mkdir -p "$W/bin" "$W/root/tmp/sysinfo" "$W/root/lib/functions"
cat > "$W/bin/uci" <<'EOS'
#!/bin/sh
db=$SIM/uci
[ "$1" = -q ] && shift
op=$1; arg=${2:-}; key=${arg%%=*}; val=${arg#*=}
get() { awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2) }' "$db"; }
del() { awk -v k="$1" 'index($0, k "=") != 1' "$db" > "$db.new"; mv "$db.new" "$db"; }
case "$op" in
get) v=$(get "$key"); [ -n "$v" ] && echo "$v" ;;
set) del "$key"; echo "$key=$val" >> "$db" ;;
delete) del "$key" ;;
add_list) v=$(get "$key"); del "$key"; echo "$key=${v:+$v }$val" >> "$db" ;;
rename) awk -v k="$key" -v n="network.$val" '{ c = substr($0, length(k) + 1, 1) }
	index($0, k) == 1 && (c == "." || c == "=") { $0 = n substr($0, length(k) + 1) } { print }' "$db" > "$db.new"; mv "$db.new" "$db" ;;
commit) echo "commit $arg" >> "$SIM/commits" ;;
esac
exit 0
EOS
cat > "$W/bin/cat" <<'EOS'
#!/bin/sh
case "$1" in /tmp/sysinfo/board_name) exec /bin/cat "$SIM/board" ;; esac
exec /bin/cat "$@"
EOS
chmod +x "$W/bin/"*
export PATH="$W/bin:$PATH" SIM=$W

# fresh BOARD PORTS: the network config_generate writes on a fresh install.
fresh() {
	echo "$1" > "$W/board"
	rm -f "$W/commits"
	printf '%s\n' 'network.device_lan.name=br-lan' "network.device_lan.ports=$2" \
		'network.lan.proto=dhcp' 'network.lan.device=br-lan' 'network.lan6.device=br-lan' \
		'openwisp.http.management_interface=br-lan' > "$W/uci"
}
val() { sed -n "s/^$1=//p" "$W/uci"; }
run() { sh "$1" > /dev/null 2>&1; }
expect() { # expect DESCRIPTION WANT GOT
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); else
		fail=$((fail + 1)); echo "FAIL: $1: got '$3', want '$2'"; fi
}

# script BOARD PORTS VLAN-PORTS
while read -r script board ports want; do
	fresh "$board" "$(echo "$ports" | tr , ' ')"
	run "$pkg/$script"
	expect "$board: VLAN filtering" 1 "$(val network.device_br_lan.vlan_filtering)"
	expect "$board: only untagged VLAN 1 on the LAN ports" "$(echo "$want" | tr , ' ')" "$(val network.vlan_br_lan_1.ports)"
	expect "$board: management on br-lan.1" 'br-lan.1 br-lan.1 br-lan.1' \
		"$(val network.lan.device) $(val network.lan6.device) $(val openwisp.http.management_interface)"
	expect "$board: no other VLAN" '' "$(grep -v vlan_br_lan_1 "$W/uci" | grep -c bridge-vlan | grep -v '^0$')"
done <<'EOL'
cambium-thor-support/files/17_thor_bridge_section cambiumnetworks,xv3-8 lan-multigig lan-multigig:u*
cambium-thor-support/files/17_thor_bridge_section cambiumnetworks,xv3-8 lan-multigig,lan lan-multigig:u*,lan:u*
cambium-cheetah-support/files/17_cheetah_bridge_section cambiumnetworks,xv2-21x lan lan:u*
cambium-jaguar-support/files/17_jaguar_bridge_section cambiumnetworks,xv2-2 lan1 lan1:u*
cambium-jaguar-support/files/17_jaguar_bridge_section cambiumnetworks,xv2-2t1 lan1,lan2 lan1:u*,lan2:u*
cambium-jaguar-support/files/17_jaguar_bridge_section cambiumnetworks,xv2-2t0 lan1,lan2 lan1:u*,lan2:u*
cambium-jaguar-support/files/17_jaguar_bridge_section cambiumnetworks,xe3-4 lan1,lan2 lan1:u*,lan2:u*
cambium-jaguar-support/files/17_jaguar_bridge_section cambiumnetworks,xe3-4tn lan1,lan2 lan1:u*,lan2:u*
EOL

# Sage runs on its validated models (its board table decides).
cat > "$W/root/lib/functions/cambium-sage.sh" <<'EOS'
cambium_sage_board() { [ "$1" = cambiumnetworks,e410 ] && SAGE_QUALIFIED=1; }
EOS
sed "s|/lib/functions/cambium-sage.sh|$W/root/lib/functions/cambium-sage.sh|g" \
	"$pkg/cambium-sage-support/files/96-sage-vlan-management" > "$W/sage-vlan"
fresh cambiumnetworks,e410 lan; run "$W/sage-vlan"
expect "E410: only untagged VLAN 1 on lan" 'lan:u*' "$(val network.vlan_br_lan_1.ports)"
expect "E410: management on br-lan.1" br-lan.1 "$(val network.lan.device)"

# A trunk OpenWISP has already configured is left alone.
fresh cambiumnetworks,xv2-2t1 'lan1 lan2'
printf '%s\n' 'network.device_br_lan.name=br-lan' 'network.device_br_lan.vlan_filtering=1' \
	'network.vlan_br_lan_101.vlan=101' 'network.lan.device=br-lan.1' > "$W/uci"
cp "$W/uci" "$W/uci.before"
run "$pkg/cambium-jaguar-support/files/17_jaguar_bridge_section"
expect "configured trunk untouched" '' "$(cmp -s "$W/uci" "$W/uci.before" || echo changed)"
# ... except lan6, which a trunk template leaves on the unfiltered bridge.
for script in cambium-thor-support/files/17_thor_bridge_section:cambiumnetworks,xv3-8 \
	cambium-cheetah-support/files/17_cheetah_bridge_section:cambiumnetworks,xv2-21x \
	cambium-jaguar-support/files/17_jaguar_bridge_section:cambiumnetworks,xv2-2t1 sage:cambiumnetworks,e410; do
	echo "${script#*:}" > "$W/board"
	rm -f "$W/commits"
	printf '%s\n' 'network.device_br_lan.name=br-lan' 'network.device_br_lan.vlan_filtering=1' \
		'network.vlan_br_lan_101.vlan=101' 'network.lan.device=br-lan.1' 'network.lan6.device=br-lan' > "$W/uci"
	s=${script%%:*}; [ "$s" = sage ] && s=$W/sage-vlan || s=$pkg/$s
	run "$s"
	expect "${script#*:}: trunk's lan6 moved to br-lan.1" 'br-lan.1 commit network' \
		"$(val network.lan6.device) $(cat "$W/commits" 2>/dev/null)"
	expect "${script#*:}: rest of the trunk untouched" 4 "$(grep -c -e 'device_br_lan' -e 'vlan_br_lan_101.vlan=101' -e 'lan.device=br-lan.1' "$W/uci")"
done
# An unexpected port layout is refused rather than guessed at.
fresh cambiumnetworks,xv2-2t1 'lan1'
run "$pkg/cambium-jaguar-support/files/17_jaguar_bridge_section"
expect "unexpected ports: nothing changed" '' "$(val network.device_br_lan.vlan_filtering)$(cat "$W/commits" 2>/dev/null)"
# Other boards are not touched.
fresh cambiumnetworks,xv2-22h lan
run "$pkg/cambium-cheetah-support/files/17_cheetah_bridge_section"
expect "unvalidated XV2-22H untouched" '' "$(val network.device_br_lan.vlan_filtering)"

# The A/B boot guard checks DHCP on the VLAN-1 bridge first.
for fam in thor jaguar cheetah; do
	expect "$fam guard checks br-lan.1 first" yes \
		"$(grep -q "AB_LAN='br-lan.1 br-lan'" "$pkg/cambium-$fam-support/files/cambium-ab-$fam.sh" && echo yes)"
done

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
