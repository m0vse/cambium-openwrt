#!/bin/sh
# Pure guard tests: no host networking, flash, UCI or boot environment writes.
set -eu
top=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
CAMBIUM_SYSTEM_FUNCTIONS=/dev/null
CAMBIUM_AB_LIB=/dev/null
AB_GUARD_SOURCE_ONLY=1
. "$top/package/cambium/cambium-ab/files/cambium-ab-guard"
work=$(mktemp -d /tmp/cambium-ab-routing.XXXXXX)
trap 'rm -rf "$work"' EXIT HUP INT TERM
AB_PROC_MOUNTS=$work/mounts
AB_RADIOS=0
AB_VAULT=0
printf '/dev/ubi0_2 /overlay ubifs rw 0 0\n' > "$AB_PROC_MOUNTS"
ab_identity() { return 0; }
ab_hook() { [ "$1" = root_healthy ]; }
AB_FAMILY=test
ab_test_root_healthy() { return 0; }
radios_up() { echo 0; }
lan_interface() { echo management101; }
uci() {
    case "$*" in
    '-q show network') printf '%s\n' network.unrelated=interface network.management101=interface ;;
    '-q get network.management101.device') echo management101 ;;
    '-q get network.unrelated.device') echo unrelated0 ;;
    '-q get network.management101.ip4table') printf '%s\n' "$configured_table" ;;
    '-q get network.unrelated.ip4table') echo 999 ;;
    *) return 1 ;;
    esac
}
ip() {
    printf '%s\n' "$*" >> "$work/ip-calls"
    case "$*" in
    '-4 address show dev management101') echo '    inet 192.0.2.10/24' ;;
    '-4 route show default dev management101') [ "$actual_table" = main ] && echo 'default via 192.0.2.1 dev management101' ;;
    '-4 route show table 101 default dev management101') [ "$actual_table" = 101 ] && echo 'default via 192.0.2.1 dev management101' ;;
    *) return 1 ;;
    esac
}
configured_table=101 actual_table=101
healthy ab
grep -q 'route show table 101 default dev management101' "$work/ip-calls"
configured_table=101 actual_table=main
if healthy ab; then echo 'FAIL: unrelated main route accepted' >&2; exit 1; fi
configured_table= actual_table=main
healthy ab
for configured_table in '-101' '101;reboot' '101 table 102' '../101'; do
    : > "$work/ip-calls"
    if healthy ab; then echo 'FAIL: invalid table accepted' >&2; exit 1; fi
    if grep -q 'route show' "$work/ip-calls"; then echo 'FAIL: invalid table reached ip' >&2; exit 1; fi
done
echo 'PASS: selected tagged/main routes; unrelated section/main route and invalid table identifiers refused'
