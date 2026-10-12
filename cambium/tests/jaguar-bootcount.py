#!/usr/bin/env python3
"""Execute Jaguar one-shots with separate RAM and durable U-Boot environments.

This shell simulation tests command control flow, not the U-Boot parser or AP.
"""
import os
import pathlib
import shlex
import subprocess

top = pathlib.Path(__file__).resolve().parents[2]
module = top / "package/cambium/cambium-jaguar-support/files/cambium-ab-jaguar.sh"
shell = os.environ.get("CAMBIUM_TEST_SHELL", "sh")
shell_command = shlex.split(shell)
fixture = r'''
. "$1"
ab_jaguar_board "$2"
slot=$3; failure=$4; volume=$5
ab_bank_hex() { printf '0x%s\n' "$AB_BANK_SIZE"; }
ab_bank_name() { if [ "$1" = 0 ]; then echo rootfs; else echo rootfs_1; fi; }
image=$((1-slot)); bootcount=9; bootcmd=old-trial; changing_bootcmd=1
durable_image=$image; durable_count=$bootcount; durable_cmd=$bootcmd
events=
setenv() {
    key=$1; shift
    [ "$failure" != "$key" ] || return 1
    case "$key" in
    bootcmd) bootcmd="$*" ;;
    changing_bootcmd) changing_bootcmd="$*" ;;
    image) image=$1 ;;
    bootcount) bootcount=$1 ;;
    esac
    return 0
}
saveenv() {
    [ "$failure" != saveenv ] || return 1
    durable_image=$image; durable_count=$bootcount; durable_cmd=$bootcmd
    events="${events}save,"
}
nand() { events="${events}nand,"; [ "$failure" != nand ]; }
ubi() { events="${events}ubi-$1,"; [ "$failure" != "ubi-$1" ]; }
bootm() { events="${events}bootm,"; return 1; }
bootipq() { events="${events}oem,"; }
reset() {
    events="${events}reset,"
    # Model the next OEM boot using SAVED values, not updated RAM values.
    next_image=$durable_image
    case "$durable_count" in 8|9) next_image=$((1-next_image));; esac
}
command=$(ab_jaguar_guarded_command "$slot") || exit 2
# The OEM RAM installer uses the same guard but reads the openwrt volume.
if [ "$volume" = openwrt ]; then
    command=$(printf '%s\n' "$command" | sed 's/0x60000000 kernel/0x60000000 openwrt/')
fi
eval "$command"
printf '%s|%s|%s|%s|%s\n' "$durable_count" "$durable_image" "$durable_cmd" "$events" "${next_image:-none}"
'''

boards = ("xv2-2", "xv2-2t0", "xv2-2t1", "xe3-4", "xe3-4tn")
passed = 0
for board in boards:
    for slot in (0, 1):
        for volume in ("kernel", "openwrt"):
            for failure in ("bootcmd", "changing_bootcmd", "image", "bootcount", "saveenv"):
                output = subprocess.check_output(
                    [*shell_command, "-s", "--", str(module), "cambiumnetworks," + board,
                     str(slot), failure, volume], input=fixture, text=True).strip()
                assert output == f"9|{1-slot}|old-trial||none", (board, slot, volume, failure, output)
                passed += 1
            for failure in ("none", "nand", "mtdids", "mtdparts", "ubi-part", "ubi-read", "bootargs"):
                output = subprocess.check_output(
                    [*shell_command, "-s", "--", str(module), "cambiumnetworks," + board,
                     str(slot), failure, volume], input=fixture, text=True).strip()
                count, image, command, events, next_image = output.split("|")
                assert (count, image, command, next_image) == ("0", str(1-slot), "bootipq", str(1-slot)), output
                assert events.startswith("save,") and events.endswith("reset,"), output
                assert "oem," not in events, output
                if failure != "none":
                    assert "bootm," not in events, output
                passed += 1
print(f"{passed} passed, 0 failed ({shell})")
