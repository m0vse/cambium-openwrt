#!/bin/sh
# Tests for cambium-openwisp-led, the OpenWISP status LED shared by every
# Cambium family: blue while the controller answers, green otherwise, on
# either LED naming scheme (blue:status or jaguar:status:blue). E400 uses
# green while managed and amber otherwise, without altering network LEDs.
#
# Usage: cambium/tests/cambium-openwisp-led.sh   (exit status 0 when all pass)

set -u

top=$(cd "$(dirname "$0")/../.." && pwd)
script=$top/package/cambium/cambium-openwisp-led/files/cambium-openwisp-led
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT HUP INT TERM
pass=0 fail=0

mkdir -p "$W/bin"
cat > "$W/bin/uci" <<'EOS'
#!/bin/sh
[ "$1" = -q ] && shift
case "$2" in
openwisp.http.url) echo https://openwisp.example.net ;;
openwisp.http.uuid) echo 0123456789abcdef0123456789abcdef ;;
openwisp.http.key) echo abcdefghijklmnopqrstuvwxyz012345 ;;
openwisp.http.management_interface) echo tun0 ;;
*) exit 1 ;;
esac
EOS
cat > "$W/bin/openwisp-get-address" <<'EOS'
#!/bin/sh
echo 10.8.0.2
EOS
# curl answers as the controller does when $SIM/answer is "managed".
cat > "$W/bin/curl" <<'EOS'
#!/bin/sh
headers=
while [ $# -gt 0 ]; do
	[ "$1" = --dump-header ] && { headers=$2; shift; }
	shift
done
if [ "$(cat "$SIM/answer")" = managed ]; then
	printf 'HTTP/1.1 200 OK\r\nX-Openwisp-Controller: true\r\n' > "$headers"
	printf 200
else
	printf 'HTTP/1.1 404 Not Found\r\n' > "$headers"
	printf 404
fi
EOS
chmod +x "$W/bin/"*
export PATH="$W/bin:$PATH" SIM=$W CAMBIUM_OPENWISP_LEDS=$W/leds \
	CAMBIUM_OPENWISP_LED_STATE=$W/managed CAMBIUM_OPENWISP_LED_ONCE=1

run_led() {
	if [ "${CAMBIUM_TEST_BUSYBOX:-0}" = 1 ]; then
		busybox sh "$script" "$@"
	else
		sh "$script" "$@"
	fi
}

# leds NAME... : a fresh /sys/class/leds with those LEDs, all lit by a trigger.
leds() {
	rm -rf "$W/leds" "$W/managed"
	mkdir -p "$W/leds"
	for l in "$@"; do
		mkdir -p "$W/leds/$l"
		echo heartbeat > "$W/leds/$l/trigger"
		echo 1 > "$W/leds/$l/brightness"
	done
}

# expect DESCRIPTION ANSWER BLUE GREEN BLUE_BRIGHTNESS GREEN_BRIGHTNESS MANAGED
expect() {
	local got want
	echo "$2" > "$W/answer"
	run_led >/dev/null 2>&1
	got="$(cat "$W/leds/$3/trigger" "$W/leds/$3/brightness" "$W/leds/$4/trigger" "$W/leds/$4/brightness" 2>/dev/null | tr '\n' ' ')$([ -e "$W/managed" ] && echo managed)"
	want="none $5 none $6 $7"
	if [ "$got" = "$want" ]; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		echo "FAIL: $1: got '$got', want '$want'"
	fi
}

for pair in 'blue:status green:status' 'jaguar:status:blue jaguar:status:green'; do
	set -- $pair
	leds "$1" "$2"; expect "$1 managed" managed "$1" "$2" 1 0 managed
	expect "$1 no longer managed" unmanaged "$1" "$2" 0 1 ''
	leds "$1" "$2"; expect "$1 not managed" unmanaged "$1" "$2" 0 1 ''
done

# E400 substitutes green/amber; blue/green still takes precedence if all exist.
leds green:status amber:status green:lan amber:lan
expect "E400 managed" managed green:status amber:status 1 0 managed
expect "E400 lost controller" unmanaged green:status amber:status 0 1 ''
expect "E400 managed again" managed green:status amber:status 1 0 managed
run_led --unmanaged
if [ "$(cat "$W/leds/green:status/brightness" "$W/leds/amber:status/brightness" | tr '\n' ' ')" = '0 1 ' ] && [ ! -e "$W/managed" ]; then
	pass=$((pass + 1))
else
	fail=$((fail + 1)); echo "FAIL: E400 service stop did not restore amber"
fi
if [ "$(cat "$W/leds/green:lan/trigger" "$W/leds/amber:lan/trigger" | tr '\n' ' ')" = 'heartbeat heartbeat ' ]; then
	pass=$((pass + 1))
else
	fail=$((fail + 1)); echo "FAIL: status service changed network LEDs"
fi
leds blue:status green:status amber:status
expect "blue takes precedence" managed blue:status green:status 1 0 managed
if [ "$(cat "$W/leds/amber:status/trigger")" = heartbeat ]; then
	pass=$((pass + 1))
else
	fail=$((fail + 1)); echo "FAIL: blue/green board's amber LED was changed"
fi
run_led --unmanaged
if [ "$(cat "$W/leds/blue:status/brightness" "$W/leds/green:status/brightness" | tr '\n' ' ')" = '0 1 ' ]; then
	pass=$((pass + 1))
else
	fail=$((fail + 1)); echo "FAIL: blue/green service stop changed colours"
fi

# A board without the blue and green status LEDs keeps its LEDs as they
# are, but the managed state is still recorded: Sage's upgrade commit waits
# for it (a Sage image without the LED driver never committed).
leds green:status white:power
echo managed > "$W/answer"
run_led >/dev/null 2>&1
if [ "$(cat "$W/leds/green:status/trigger" "$W/leds/green:status/brightness" | tr '\n' ' ')" = 'heartbeat 1 ' ]; then
	pass=$((pass + 1))
else
	fail=$((fail + 1))
	echo "FAIL: no blue LED: the green LED was changed"
fi
if [ -e "$W/managed" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: no LEDs: the managed state was not recorded"; fi
rm -rf "$W/leds"; mkdir -p "$W/leds"; echo unmanaged > "$W/answer"; touch "$W/managed"
run_led >/dev/null 2>&1
if [ ! -e "$W/managed" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: no LEDs: a lost controller still counted as managed"; fi

# The init script starts the shared service on every family.
if grep -q 'procd_set_param command /usr/sbin/cambium-openwisp-led' "$script.init" && ! grep -q board_name "$script.init"; then
	pass=$((pass + 1))
else
	fail=$((fail + 1))
	echo "FAIL: the init script does not start the shared service unconditionally"
fi

# Every family's support package pulls the shared LED package in.
for fam in sage thor jaguar cheetah gambit; do
	if grep -q '+cambium-openwisp-led' "$top/package/cambium/cambium-$fam-support/Makefile"; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		echo "FAIL: cambium-$fam-support does not depend on cambium-openwisp-led"
	fi
done

# Anything that reads the managed state (e.g. Sage's upgrade commit, which
# waits for OpenWISP on managed APs) must read the file this service writes.
stale=$(grep -rn -- '-openwisp-managed' "$top/package" | grep -v '/tmp/cambium-openwisp-managed' || true)
if [ -z "$stale" ]; then
	pass=$((pass + 1))
else
	fail=$((fail + 1))
	echo "FAIL: scripts read an OpenWISP state file the LED service no longer writes:"
	echo "$stale" | sed 's/^/    /'
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
