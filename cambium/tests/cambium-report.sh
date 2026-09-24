#!/bin/sh
# Checks for cambium/site/cambium-report.sh, the hardware report users run on
# untested access points: it must contain no command that writes flash, the
# U-Boot environment, mounts or reboots, it must run to completion, and its
# default output must not contain a full MAC address.
#
# Usage: cambium/tests/cambium-report.sh   (exit status 0 when all pass)

set -u

top=$(cd "$(dirname "$0")/../.." && pwd)
script=$top/cambium/site/cambium-report.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
fail=0

# Code lines only: comments may name the commands the script never runs.
grep -v '^[[:space:]]*#' "$script" > "$work/code"
forbidden='ubiattach|ubidetach|ubiformat|ubimkvol|ubirmvol|ubirsvol|ubiupdatevol|ubiblock|fw_setenv|flash_erase|nandwrite|mtd (write|erase|unlock)|(^|[ ;|&(])(dd|mount|reboot|poweroff|insmod|rmmod|modprobe) |>[[:space:]]*/(dev/[^n]|sys/|proc/)'
if grep -nE "$forbidden" "$work/code"; then
	echo "FAIL: the report script contains a writing command (above)"
	fail=1
fi

CAMBIUM_REPORT_OUT=$work/report.txt sh "$script" > "$work/stdout" 2>&1 || {
	echo "FAIL: the report script exited non-zero"
	cat "$work/stdout"
	fail=1
}
[ -s "$work/report.txt" ] || { echo "FAIL: no report written"; fail=1; }
for s in 'cambium-report 1' identity 'flash: /proc/mtd' network 'kernel log (dmesg)' end; do
	grep -q "^===== $s =====\$" "$work/report.txt" || { echo "FAIL: section $s missing"; fail=1; }
done
if grep -nE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' "$work/report.txt" | grep -v 'xx:xx:xx' | head -n 3 | grep .; then
	echo "FAIL: unmasked MAC address in the default report"
	fail=1
fi

[ "$fail" = 0 ] && echo "cambium-report: all checks passed"
exit "$fail"
