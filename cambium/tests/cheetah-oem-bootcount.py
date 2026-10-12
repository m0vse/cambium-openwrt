#!/usr/bin/env python3
"""Exercise actual Cheetah hooks/commands against the captured OEM counter rule."""
import pathlib
import subprocess

module = pathlib.Path(__file__).resolve().parents[2] / "package/cambium/cambium-cheetah-support/files/cambium-ab-cheetah.sh"

trial = r'''
. "$1"
slot=$2; bootcount=$3; image=$((1-slot)); bootcmd=trial
ab_bank_hex() { echo 0x6000000; }
ab_cheetah_board cambiumnetworks,xv2-21x
setenv() {
    key=$1; shift
    case "$key" in
    image) image=$1 ;;
    bootcount) bootcount=$1 ;;
    bootcmd) bootcmd="$*" ;;
    esac
}
saveenv() { saved_count=$bootcount; saved_image=$image; saved_boot=$bootcmd; }
nand() { :; }
ubi() {
    if [ "$1" = read ]; then
        if [ "$POWER_CUT" = 1 ]; then
            printf '%s %s %s\n' "$saved_count" "$saved_image" "$saved_boot"
            exit 0
        fi
        return 1
    fi
}
bootm() { echo unexpected-bootm >&2; return 1; }
bootipq() {
    # Captured v2.7.5b parses the first ASCII digit; 8/9 toggle image.
    digit=${bootcount%"${bootcount#?}"}
    case "$digit" in 8|9) image=$((1-image));; esac
    printf '%s %s %s %s\n' "$saved_count" "$saved_image" "$saved_boot" "$image"
}
eval "$(ab_cheetah_guarded_command "$slot")"
'''

hook = r'''
. "$1"
running_slot=$2; oem_image=$3; count=9; mode=$4
ab_running_slot() { echo "$running_slot"; }
ab_getenv() { case "$1" in image) echo "$oem_image";; bootcount) echo "$count";; esac; }
ab_setenv() {
    [ "$mode" != fail ] || return 1
    [ "$mode" != stale ] || return 0
    count=$2
    [ "$mode" != moved ] || oem_image=$running_slot
}
ab_cheetah_healthy_boot
rc=$?
printf '%s %s %s\n' "$rc" "$count" "$oem_image"
'''

def run(program, *args, cut=False):
    import os
    env = dict(os.environ, POWER_CUT=str(int(cut)))
    return subprocess.check_output(["sh", "-s", "--", str(module), *map(str,args)], input=program, text=True, env=env).strip()

passed = 0
for slot in (0, 1):
    for counter in (0, 8, 9):
        assert run(trial, slot, counter) == f"0 {1-slot} bootipq {1-slot}"
        assert run(trial, slot, counter, cut=True) == f"0 {1-slot} bootipq"
        passed += 2
    assert run(hook, slot, 1-slot, "ok") == f"0 0 {1-slot}"
    for mode in ("fail", "stale"):
        assert run(hook, slot, 1-slot, mode) == f"1 9 {1-slot}"
    assert run(hook, slot, 1-slot, "moved") == f"1 0 {slot}"
    assert run(hook, slot, slot, "ok") == f"1 9 {slot}"
    passed += 5
print(f"{passed} passed, 0 failed")
