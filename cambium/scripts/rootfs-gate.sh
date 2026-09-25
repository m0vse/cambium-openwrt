#!/bin/sh
# Release gate for a persistent image's root filesystem: unpack the actual
# filesystem (SquashFS or UBIFS, or take an unpacked directory), write its
# installed-package manifest from the apk database, and fail unless the
# managed-AP packages and services are present.
#
# Usage: rootfs-gate.sh ROOT MANIFEST LABEL [EXTRA_PACKAGE...]
#   ROOT      SquashFS or UBIFS image, or an unpacked root directory
#   MANIFEST  where to write "name version" lines, one per installed package
#   LABEL     how failures name the image
#   EXTRA_PACKAGE  further packages this image must carry (e.g. the family's
#             support package)
#
# UNSQUASHFS and UBIREADER_EXTRACT name the unpack tools (defaults:
# unsquashfs, ubireader_extract_files).

set -u

root=${1:?usage: rootfs-gate.sh ROOT MANIFEST LABEL [EXTRA_PACKAGE...]}
manifest=${2:?usage: rootfs-gate.sh ROOT MANIFEST LABEL [EXTRA_PACKAGE...]}
label=${3:?usage: rootfs-gate.sh ROOT MANIFEST LABEL [EXTRA_PACKAGE...]}
shift 3

# Every persistent image is a managed access point: OpenWISP, LuCI over
# uHTTPd, WireGuard, the full wpad, the shared status LED and the GPIO LED
# and button drivers it and failsafe need (target defaults are not always
# carried into per-device images: Thor lost both).
required="openwisp-config openwisp-monitoring wireguard-tools kmod-wireguard
	luci luci-ssl uhttpd wpad-mbedtls cambium-openwisp-led
	kmod-leds-gpio kmod-gpio-button-hotplug $*"
required_files="etc/init.d/openwisp-config etc/init.d/uhttpd"
forbidden="wpad-basic-mbedtls"

fail() {
	echo "ROOTFS GATE FAILED: $label: $*" >&2
	exit 1
}

work=
cleanup() { [ -z "$work" ] || rm -rf "$work"; }
trap cleanup EXIT HUP INT TERM

if [ -d "$root" ]; then
	dir=$root
else
	work=$(mktemp -d)
	dir=$work/root
	case "$(head -c 4 "$root" | od -An -tx1 | tr -d ' \n')" in
	68737173) # hsqs: only what the gate reads (device nodes need root)
		"${UNSQUASHFS:-unsquashfs}" -no-progress -d "$dir" "$root" \
			lib/apk/db etc/init.d >/dev/null ||
			fail "cannot unpack the SquashFS" ;;
	31181006) # UBIFS node magic
		"${UBIREADER_EXTRACT:-ubireader_extract_files}" -k -o "$dir" "$root" >/dev/null ||
			fail "cannot unpack the UBIFS" ;;
	*) fail "neither a SquashFS nor a UBIFS image" ;;
	esac
fi

db=$dir/lib/apk/db/installed
[ -s "$db" ] || fail "no apk database (lib/apk/db/installed)"
awk '/^P:/ { name = substr($0, 3) } /^V:/ { print name, substr($0, 3) }' "$db" |
	sort > "$manifest"
[ -s "$manifest" ] || fail "the apk database lists no packages"

missing=
for p in $required; do
	grep -q "^$p " "$manifest" || missing="$missing $p"
done
for f in $required_files; do
	[ -f "$dir/$f" ] || missing="$missing /$f"
done
[ -z "$missing" ] || fail "missing:$missing"
for p in $forbidden; do
	! grep -q "^$p " "$manifest" || fail "has $p"
done
echo "$label: $(wc -l < "$manifest") packages; managed-AP packages and services present"
