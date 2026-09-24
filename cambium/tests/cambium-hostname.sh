#!/bin/sh
# Tests for the 13_cambium_hostname first-boot script, which gives Cambium
# APs their stock firmware's hostname (MODEL-XXXXXX from U-Boot's ethaddr).
# Its four copies, one per target, must stay identical.
#
# Usage: cambium/tests/cambium-hostname.sh   (exit status 0 when all pass)

set -u

top=$(cd "$(dirname "$0")/../.." && pwd)
copies="target/linux/ipq40xx/base-files/etc/uci-defaults/13_cambium_hostname
target/linux/qualcommax/ipq807x/base-files/etc/uci-defaults/13_cambium_hostname
target/linux/qualcommax/ipq50xx/base-files/etc/uci-defaults/13_cambium_hostname
target/linux/qualcommax/ipq60xx/base-files/etc/uci-defaults/13_cambium_hostname"
script=$top/$(echo "$copies" | head -n 1)
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT HUP INT TERM
pass=0 fail=0

for c in $copies; do
	if cmp -s "$top/$c" "$script"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $c differs from the other copies"; fi
done

mkdir -p "$W/bin"
cat > "$W/bin/uci" <<'EOS'
#!/bin/sh
[ "$1" = -q ] && shift
[ "$1" = set ] && echo "${2#*=}" > "$SIM/hostname"
exit 0
EOS
cat > "$W/bin/jsonfilter" <<'EOS'
#!/bin/sh
f=
while [ $# -gt 0 ]; do
	case "$1" in -i) f=$2; shift ;; -e) awk -v k="$2" '$1 == k { print $2 }' "$f" 2>/dev/null ;; esac
	shift
done
EOS
chmod +x "$W/bin/"*
cat > "$W/functions.sh" <<'EOS'
find_mtd_index() { sed -n "s/^mtd\([0-9]*\): .* \"$1\"\$/\1/p" "$CAMBIUM_ROOT/proc/mtd"; }
EOS
cat > "$W/system.sh" <<'EOS'
board_name() { cat "$SIM/board"; }
EOS
export PATH="$W/bin:$PATH" SIM=$W CAMBIUM_ROOT=$W/root \
	CAMBIUM_FUNCTIONS=$W/functions.sh CAMBIUM_SYSTEM_FUNCTIONS=$W/system.sh

# ap BOARD [ethaddr] [board.json lan macaddr] [lan port MAC]
ap() {
	rm -rf "$W/root" "$W/hostname"
	mkdir -p "$W/root/proc/device-tree/cambium-platform" "$W/root/dev" "$W/root/etc" "$W/root/sys/class/net/lan1"
	echo "$1" > "$W/board"
	printf '%s\n' 'dev:    size   erasesize  name' 'mtd5: 00010000 00010000 "0:APPSBLENV"' > "$W/root/proc/mtd"
	# U-Boot environment: CRC, then NUL-separated variables.
	{ printf 'CRC!baudrate=115200\000'; [ -n "${2:-}" ] && printf 'ethaddr=%s\000' "$2"; printf 'bootcmd=bootipq\000\000'; } > "$W/root/dev/mtd5"
	: > "$W/root/etc/board.json"
	[ -n "${3:-}" ] && echo "@.network.lan.macaddr $3" >> "$W/root/etc/board.json"
	echo "@.network.lan.ports[*] lan1" >> "$W/root/etc/board.json"
	echo "${4:-}" > "$W/root/sys/class/net/lan1/address"
}
expect() { # DESCRIPTION HOSTNAME
	sh "$script"
	got=$(cat "$W/hostname" 2>/dev/null)
	if [ "$got" = "$2" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 (got '$got', wanted '$2')"; fi
}

ap cambium,e410 ab:ab:ab:ab:ab:ab;               expect "Sage E410 from ethaddr" E410-ABABAB
ap cambiumnetworks,xv2-21x fc:11:65:be:a5:be;     expect "Cheetah XV2-21X, as on the stock firmware" XV2-21X-BEA5BE
ap cambiumnetworks,xv2-2 00:04:56:12:34:56;       expect "Jaguar XV2-2" XV2-2-123456
ap cambiumnetworks,xv3-8 00:04:56:A1:b2:C3;       expect "Thor XV3-8, mixed-case MAC" XV3-8-A1B2C3
ap cambiumnetworks,xv2-2t1 '' 00:04:56:0a:0b:0c;  expect "no ethaddr: board.json LAN MAC" XV2-2T1-0A0B0C
ap cambiumnetworks,xe3-4 '' '' 00:04:56:de:ad:01; expect "no ethaddr or board MAC: LAN port MAC" XE3-4-DEAD01
ap cambiumnetworks,xe3-4 '' '' '';                expect "no MAC anywhere: hostname untouched" ''
ap cambiumnetworks,xe3-4 00:04:56:12:34:56; rm -rf "$W/root/proc/device-tree/cambium-platform"
expect "upstream image (no cambium-platform): untouched" ''

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
