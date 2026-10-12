#!/usr/bin/env python3
"""Execute stock producers and hooks with separate volatile/durable OEM state."""
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(os.environ.get('CAMBIUM_TEST_ROOT', Path(__file__).resolve().parents[2]))
SHELL = os.environ.get('CAMBIUM_TEST_SHELL', 'sh')
COMMAND = [SHELL, 'sh'] if Path(SHELL).name == 'busybox' else [SHELL]
INSTALLER = ROOT / 'cambium/site/cambium-install.sh'


def function(name):
    source = INSTALLER.read_text()
    start = source.index(name + '() {')
    end = source.index('\n}', start) + 2
    return source[start:end]


SETUP = r'''
. "$1"
family=$2; G_SLOT=$3; fault=$4
G_COUNT=9; G_IMAGE=$((1-G_SLOT)); saved_count=9; saved_image=$G_IMAGE
G_BOOT=bootipq; [ "$family" != thor ] || G_BOOT='aq_load_fw&&bootipq'
AB_STOCK_BOOTCMD=$G_BOOT
ab_bank_hex() { echo 0x6000000; }
ab_getenv() {
    case "$1" in
    image) [ "$fault" != read-image ] || return 1; echo "$G_IMAGE";;
    bootcount) [ "$fault" != read-count ] || return 1; echo "$G_COUNT";;
    bootcmd) echo "$G_BOOT";;
    *) printenv "$1";;
    esac
}
setenv() {
    key=$1; shift
    [ "$fault" != "$key" ] || return 1
    case "$key" in bootcount) G_COUNT=$1;; image) G_IMAGE=$1;; bootcmd) G_BOOT="$*";; esac
}
saveenv() {
    [ "$fault" != saveenv ] || return 1
    saved_count=$G_COUNT; saved_image=$G_IMAGE
}
# U-Boot accepts bare parentheses in mtdparts tokens; POSIX shells require
# quoting them. Only adapt that token, leaving the actual command flow intact.
run() { for name; do eval "$(printenv "$name" | sed 's/\(mtdparts=nand0:[^ ;]*\)/"\1"/g')" || return; done; }
nand() { echo candidate; return 1; }
ubi() { echo candidate; return 1; }
bootm() { echo candidate; return 1; }
aq_load_fw() { :; }
bootipq() { echo "oem:$saved_count:$saved_image"; }
reset() { echo "reset:$saved_count:$saved_image"; }
sync() { :; }
ab_running_slot() { echo "$G_SLOT"; }
if [ "$family" = thor ]; then ab_thor_board cambiumnetworks,xv3-8;
else ab_miami_board cambiumnetworks,x7-35x; fi
'''


class CounterTests(unittest.TestCase):
    def run_case(self, family, slot, fault, body, helpers=''):
        module = ROOT / f'package/cambium/cambium-{family}-support/files/cambium-ab-{family}.sh'
        result = subprocess.run(COMMAND + ['-s', '--', str(module), family, str(slot), fault],
                                input=SETUP + '\n' + helpers + '\n' + body,
                                text=True, capture_output=True)
        return result

    def miami_helpers(self):
        return function('miami_oneshot') + r'''
TOFF=0xc0000; [ "$G_SLOT" != 1 ] || TOFF=0x60c0000
TSLOT=$G_SLOT; CONFIG=config@mi01.6-acadia-slot$G_SLOT
getenv() { echo original-oem-value; }
setenv_checked() { export "$1=$2"; }
arm() { export armed="$1"; }
miami_oneshot kernel "console=ttyMSM0 ubi.mtd=$([ "$G_SLOT" = 0 ] && echo rootfs || echo rootfs_1) rootwait" "$CONFIG"
'''

    def test_thor_each_prefix_failure_stops_before_every_boot(self):
        for slot in (0, 1):
            for fault in ('bootcount', 'image', 'bootcmd', 'changing_bootcmd', 'saveenv'):
                with self.subTest(slot=slot, fault=fault):
                    result = self.run_case('thor', slot, fault,
                        'cmd=$(ab_thor_guarded_command "$G_SLOT") || exit 1; eval "$cmd"; :')
                    self.assertEqual(result.stdout, '')

    def test_thor_success_saves_safe_route_before_candidate_and_fallback(self):
        for slot in (0, 1):
            result = self.run_case('thor', slot, 'ok',
                'cmd=$(ab_thor_guarded_command "$G_SLOT") || exit 1; eval "$cmd"')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), f'candidate\noem:0:{1-slot}')

    def test_thor_installer_ram_and_persistent_prefix_failures(self):
        helpers = function('thor_oneshot') + '\nCONFIG=config@hk02\n'
        for volume in ('openwrt', 'kernel'):
            for fault in ('bootcount', 'image', 'bootcmd', 'changing_bootcmd', 'saveenv'):
                result = self.run_case('thor', 0, fault,
                    f'cmd=$(thor_oneshot {volume}); eval "$cmd"; :', helpers)
                self.assertEqual(result.stdout, '')

    def test_miami_installer_and_guard_contract_match_both_slots(self):
        for slot in (0, 1):
            result = self.run_case('miami', slot, 'ok',
                'guarded=$(ab_miami_guarded_command "$G_SLOT") || exit 1; '
                '[ "$guarded" = "$armed" ] || exit 2; eval "$guarded"', self.miami_helpers())
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), f'candidate\nreset:0:{1-slot}')

    def test_miami_each_start_failure_cannot_reset_to_old_durable_nine(self):
        for slot in (0, 1):
            for fault in ('bootcount', 'image', 'bootcmd', 'changing_bootcmd', 'miami_trial', 'saveenv'):
                with self.subTest(slot=slot, fault=fault):
                    result = self.run_case('miami', slot, fault,
                        'eval "$armed"; :', self.miami_helpers())
                    self.assertEqual(result.stdout, '')

    def test_miami_old_counterless_start_is_refused(self):
        result = self.run_case('miami', 1, 'ok',
            'export miami_start="setenv bootcmd bootipq; setenv changing_bootcmd; '
            'setenv miami_trial entered; saveenv"; ab_miami_guarded_command 1', self.miami_helpers())
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')

    def test_family_hooks_preserve_oem_and_check_write_readback(self):
        for family in ('thor', 'miami'):
            for slot in (0, 1):
                for fault in ('ok', 'write', 'stale', 'moved', 'read-image', 'read-count', 'selector'):
                    body = r'''
[ "$fault" != selector ] || G_IMAGE=$G_SLOT
ab_setenv() {
    [ "$fault" != write ] || return 1
    [ "$fault" != stale ] || return 0
    G_COUNT=$2
    [ "$fault" != moved ] || G_IMAGE=$G_SLOT
}
"ab_${family}_stock_prepare"
rc=$?
echo "$rc:$G_COUNT:$G_IMAGE"
'''
                    result = self.run_case(family, slot, fault, body)
                    expected = 0 if fault == 'ok' else 1
                    self.assertTrue(result.stdout.startswith(f'{expected}:'), (family, slot, fault, result))
                    if fault == 'ok':
                        self.assertEqual(result.stdout.strip(), f'0:0:{1-slot}')

    def test_shared_guard_sanitizes_before_unhealthy_reboot(self):
        guard = ROOT / 'package/cambium/cambium-ab/files/cambium-ab-guard'
        for family in ('thor', 'miami'):
            helpers = self.miami_helpers() if family == 'miami' else ''
            for fault in ('ok', 'write', 'selector', 'independent'):
                body = f'''
export CAMBIUM_SYSTEM_FUNCTIONS=/dev/null CAMBIUM_AB_LIB="$1" AB_GUARD_SOURCE_ONLY=1
. "{guard}"
AB_FAMILY=$family
[ "$fault" != selector ] || G_IMAGE=$G_SLOT
[ "$fault" != independent ] || G_BOOT=independent
ab_hook() {{ command -v "ab_${{AB_FAMILY}}_$1" >/dev/null; }}
ab_guarded_command() {{ "ab_${{family}}_guarded_command" "$1"; }}
ab_setenv() {{ [ "$fault" != write ] || return 1; G_COUNT=$2; }}
wait_healthy() {{ return 1; }}
log() {{ :; }}
do_reboot() {{ echo "reboot:$G_COUNT:$G_IMAGE"; }}
legacy_guard
rc=$?; echo "rc:$rc"
'''
                result = self.run_case(family, 0, fault, body, helpers)
                self.assertEqual(result.stdout.strip(), 'reboot:0:1\nrc:0' if fault == 'ok' else 'rc:1', (family, fault, result.stderr))


if __name__ == '__main__':
    unittest.main()
