#!/bin/sh
# Tests for cambium/scripts/rootfs-gate.sh, the release gate that reads a
# persistent image's installed packages from its own apk database. Unpacked
# root directories stand in for the images; the real SquashFS and UBIFS
# unpacking is exercised by every build.
#
# Usage: cambium/tests/rootfs-gate.sh   (exit status 0 when all pass)

set -u

top=$(cd "$(dirname "$0")/../.." && pwd)
gate=$top/cambium/scripts/rootfs-gate.sh
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT HUP INT TERM
pass=0 fail=0

full="openwisp-config openwisp-monitoring wireguard-tools kmod-wireguard luci
	luci-ssl uhttpd wpad-mbedtls cambium-openwisp-led kmod-leds-gpio
	kmod-gpio-button-hotplug cambium-sage-support base-files"

# root NAME PACKAGES...: an unpacked root whose apk database lists PACKAGES,
# with the OpenWISP and uHTTPd init scripts.
root() {
	local d=$W/$1 p
	shift
	rm -rf "$d"; mkdir -p "$d/lib/apk/db" "$d/etc/init.d"
	for p; do printf 'P:%s\nV:1.0-r1\nA:arm\n\n' "$p"; done > "$d/lib/apk/db/installed"
	touch "$d/etc/init.d/openwisp-config" "$d/etc/init.d/uhttpd"
}
check() { # check DESCRIPTION EXPECTED(0|1) ROOT [EXTRA...]
	local desc=$1 want=$2 dir=$3 got
	shift 3
	sh "$gate" "$dir" "$W/manifest" "test image" "$@" > "$W/out" 2>&1; got=$?
	[ "$got" -ne 0 ] && got=1
	if [ "$got" = "$want" ]; then pass=$((pass + 1)); else
		fail=$((fail + 1)); echo "FAIL: $desc (exit $got, wanted $want)"; sed 's/^/    /' "$W/out"; fi
}
said() {
	if grep -q -- "$2" "$W/out"; then pass=$((pass + 1)); else
		fail=$((fail + 1)); echo "FAIL: $1"; sed 's/^/    /' "$W/out"; fi
}

root good $full
check "a full managed-AP root passes" 0 "$W/good" cambium-sage-support
if [ "$(sed -n 's/^luci-ssl //p' "$W/manifest")" = 1.0-r1 ] && [ "$(wc -l < "$W/manifest")" -eq 13 ]; then
	pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: the manifest lists every package with its version"; fi

# The published Sage 2026.09.25.0 root: the shared base only.
root base base-files busybox dropbear wpad-basic-mbedtls ubi-utils
check "the shared base root fails" 1 "$W/base" cambium-sage-support
said "every missing package and service is named" 'missing: openwisp-config openwisp-monitoring wireguard-tools kmod-wireguard luci luci-ssl uhttpd wpad-mbedtls cambium-openwisp-led kmod-leds-gpio kmod-gpio-button-hotplug cambium-sage-support$'

root nowg $(echo $full | sed 's/kmod-wireguard //')
check "a root without kmod-wireguard fails" 1 "$W/nowg" cambium-sage-support
said "the missing kernel module is named" 'missing: kmod-wireguard$'

root noinit $full; rm "$W/noinit/etc/init.d/uhttpd"
check "a root without the uHTTPd init script fails" 1 "$W/noinit" cambium-sage-support
said "the missing service is named" 'missing: /etc/init.d/uhttpd$'

root noled $(echo $full | sed 's/kmod-leds-gpio //')
check "a root without the GPIO LED driver fails (Thor, 25 Sep)" 1 "$W/noled" cambium-sage-support
said "the missing LED driver is named" 'missing: kmod-leds-gpio$'

root basic $full wpad-basic-mbedtls
check "a root that still has wpad-basic-mbedtls fails" 1 "$W/basic" cambium-sage-support

root noab $full
check "a family's extra package is required" 1 "$W/noab" cambium-sage-support cambium-ab
said "the extra package is named" 'missing: cambium-ab$'

root nodb; rm "$W/nodb/lib/apk/db/installed"
check "a root without an apk database fails" 1 "$W/nodb"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
