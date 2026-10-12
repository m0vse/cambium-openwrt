#!/bin/sh
# Command-generation regression only; never executes an OEM bootloader or
# accesses an AP. Sage 1.0.13a (2026-08-24) reads the first bootcount digit
# and toggles image for 8/9 before persisting count 1.
set -eu
top=${CAMBIUM_TEST_TOP:-$(cd "$(dirname "$0")/../.." && pwd)}
export CAMBIUM_SAGE_LIB="$top/target/linux/ipq40xx/base-files/lib/functions/cambium-sage.sh"
. "$top/package/cambium/cambium-sage-support/files/cambium-ab-sage.sh"
ab_getenv() {
	case "$1" in
	sage_oem_fallback) echo "$OEM_SLOT" ;;
	bootcount) echo "$OEM_COUNT" ;;
	esac
}
pass=0
for OEM_SLOT in 0 1; do
	for OEM_COUNT in 9 8 0 7; do
		AB_MODEL=E600
		command=$(ab_sage_boot_command "$OEM_SLOT")
		[ "$command" = "setenv bootcount 0; setenv image $OEM_SLOT; bootipq" ] || {
			echo "FAIL: OEM slot $OEM_SLOT count $OEM_COUNT can reach bootipq without clearing the alternate-boot request"
			exit 1
		}
		# The generated commands select the surviving OEM pair, not the
		# overwritten inactive pair, regardless of the incoming sentinel.
		pass=$((pass + 1))
	done
done
OEM_SLOT=0 OEM_COUNT=9 AB_MODEL=E600
ab_sage_root_format() { echo ubifs; }
cambium_sage_boot_command() { echo "openwrt-slot-$1"; }
AB_SAGE_LEGACY_B=0
[ "$(ab_sage_boot_command 1)" = openwrt-slot-1 ]
pass=$((pass + 1))
AB_MODEL=E410
[ "$(ab_sage_boot_command 0)" = openwrt-slot-0 ]
pass=$((pass + 1))
echo "$pass passed, 0 failed (Sage OEM fallback commands; no AP access)"
