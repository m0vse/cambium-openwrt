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
running_slot=$2; oem_image=$3; count=9; mode=$4; AB_STOCK_BOOTCMD=bootipq
ab_running_slot() { echo "$running_slot"; }
ab_getenv() { case "$1" in image) echo "$oem_image";; bootcount) echo "$count";; bootcmd) echo bootipq;; esac; }
ab_setenv() {
    [ "$mode" != fail ] || return 1
    [ "$mode" != stale ] || return 0
    count=$2
    [ "$mode" != moved ] || oem_image=$running_slot
}
ab_cheetah_legacy_boot
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

# Failure injection must stop candidate and OEM commands before saved fallback.
prefix_failure = r'''
. "$1"
ab_bank_hex() { echo 0x6000000; }
ab_cheetah_board cambiumnetworks,xv2-21x
failure=$3
setenv() { [ "$1" != "$failure" ]; }
saveenv() { [ "$failure" != saveenv ]; }
nand() { echo candidate; }
ubi() { return 1; }
bootm() { echo candidate; }
bootipq() { echo oem; }
eval "$(ab_cheetah_guarded_command "$2")"
:
'''

guard_path = module.parents[2] / 'cambium-ab/files/cambium-ab-guard'
guard_case = r'''
export CAMBIUM_SYSTEM_FUNCTIONS=/dev/null CAMBIUM_AB_LIB="$1" AB_GUARD_SOURCE_ONLY=1
. "$5"
G_RUN=$2; G_MODE=$3; G_FAULT=$4; G_COUNT=9; G_IMAGE=$((1-G_RUN)); G_BOOT=bootipq
AB_FAMILY=cheetah; AB_ENV=cheetah; AB_MARKER=1; AB_STOCK_BOOTCMD=bootipq
[ "$G_MODE" != converted ] || { G_IMAGE=$G_RUN; G_BOOT="run cheetah_stable$G_RUN"; }
[ "$G_FAULT" != selector ] || G_IMAGE=$G_RUN
[ "$G_FAULT" != bootcmd ] || G_BOOT=independent
ab_running_slot() { echo "$G_RUN"; }
ab_bank_hex() { echo 0x6000000; }
ab_guarded_command() { ab_cheetah_board cambiumnetworks,xv2-21x; ab_cheetah_guarded_command "$1"; }
ab_identity() { AB_ACTIVE=$G_RUN; }
ab_hook() { command -v "ab_${AB_FAMILY}_$1" >/dev/null; }
ab_getenv() {
    case "$1" in
    image) echo "$G_IMAGE";; bootcount) echo "$G_COUNT";; bootcmd) echo "$G_BOOT";;
    cheetah_ab_state) echo confirmed;; cheetah_ab_confirmed) echo "$G_RUN";;
    esac
}
ab_setenv() {
    [ "$G_FAULT" != write ] || return 1
    case "$1" in bootcount) G_COUNT=$2;; bootcmd) G_BOOT=$2;; esac
}
wait_healthy() { [ "$G_MODE" != unhealthy ]; }
log() { :; }
do_reboot() { echo reboot; }
if [ "$G_MODE" = converted ]; then ab_guard; else legacy_guard; fi
rc=$?
printf 'rc=%s count=%s image=%s\n' "$rc" "$G_COUNT" "$G_IMAGE"
'''

failures = []
for slot in (0, 1):
    for failure in ('bootcmd', 'changing_bootcmd', 'image', 'bootcount', 'saveenv'):
        got = run(prefix_failure, slot, failure)
        if got:
            failures.append(f'prefix slot {slot}/{failure}: executed {got!r}')
    cases = [
        ('converted', 'ok', f'rc=0 count=9 image={slot}'),
        ('unhealthy', 'ok', f'reboot\nrc=0 count=0 image={1-slot}'),
        ('unhealthy', 'selector', f'rc=1 count=9 image={slot}'),
        ('unhealthy', 'write', f'rc=1 count=9 image={1-slot}'),
        ('unhealthy', 'bootcmd', f'rc=1 count=9 image={1-slot}'),
    ]
    for mode, fault, expected in cases:
        got = run(guard_case, slot, mode, fault, guard_path)
        if got != expected:
            failures.append(f'guard slot {slot}/{mode}/{fault}: {got!r}, expected {expected!r}')
if failures:
    raise AssertionError('\n'.join(failures))
print('20 prefix/guard regression cases passed')
