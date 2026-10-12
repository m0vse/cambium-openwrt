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
    image) [ "$fault" != read-image ] || return 1; echo "$G_IMAGE"; [ "$fault" != read-image-valid ];;
    bootcount) [ "$fault" != read-count ] || return 1; echo "$G_COUNT"; [ "$fault" != read-count-valid ];;
    bootcmd) echo "$G_BOOT"; [ "$fault" != read-boot-valid ];;
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

    def test_thor_late_failures_can_fall_back_only_after_safe_save(self):
        body = r'''
G_AQ=0
aq_load_fw() {
    G_AQ=$((G_AQ+1))
    [ "$fault:$G_AQ" != first-aq:1 ] && [ "$fault:$G_AQ" != fallback-aq:2 ]
}
nand() { echo nand; [ "$fault" != nand ]; }
ubi() { echo "$1"; [ "$fault" != "$1" ]; }
bootm() { echo bootm; return 1; }
cmd=$(ab_thor_guarded_command "$G_SLOT") || exit 1
eval "$cmd"
:
'''
        events = {
            'first-aq': [], 'nand': ['nand'], 'part': ['nand', 'part'],
            'read': ['nand', 'part', 'read'],
            'bootm': ['nand', 'part', 'read', 'bootm'],
            'fallback-aq': ['nand', 'part', 'read', 'bootm'],
        }
        for slot in (0, 1):
            for fault, before in events.items():
                result = self.run_case('thor', slot, fault, body)
                expected = before + ([] if fault == 'fallback-aq' else [f'oem:0:{1-slot}'])
                self.assertEqual(result.stdout.splitlines(), expected, (slot, fault, result.stderr))

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
                for fault in ('ok', 'write', 'stale', 'moved', 'read-image', 'read-count', 'read-image-valid', 'read-count-valid', 'selector'):
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
            for fault in ('ok', 'write', 'selector', 'independent', 'read-boot-valid'):
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

    def test_complete_stock_consumer_orders_sanitation_before_changes(self):
        stock = (ROOT / 'package/cambium/cambium-ab/files/cambium-ab-stock').read_text()
        body = r'''
export CAMBIUM_SYSTEM_FUNCTIONS=/dev/null CAMBIUM_AB_LIB="$1" AB_GUARD_INIT=guard_stop
AB_FAMILY=$family AB_LAYOUT=banks AB_MARKER=1
G_BOOT=guarded-trial
ab_family() { return 0; }
board_name() { echo mocked-board; }
ab_board() { return 0; }
ab_converted() { [ "$fault" = converted ]; }
ab_hook() { command -v "ab_${AB_FAMILY}_$1" >/dev/null; }
[ "$fault" != selector ] || G_IMAGE=$G_SLOT
ab_setenv() {
    echo "action:set:$1"
    [ "$fault" != write ] || return 1
    [ "$fault" != stale ] || return 0
    case "$1" in bootcount) G_COUNT=$2;; bootcmd) G_BOOT=$2;; esac
    [ "$fault" != moved ] || G_IMAGE=$G_SLOT
}
guard_stop() { echo action:guard-stop; }
logger() { :; }
set -- --yes
[ "$fault" != dry-run ] || set --
'''
        for family in ('thor', 'miami'):
            for slot in (0, 1):
                for fault in ('ok', 'write', 'stale', 'moved', 'selector', 'converted', 'dry-run'):
                    result = self.run_case(family, slot, fault, body + '\n' + stock)
                    actions = [line for line in result.stdout.splitlines() if line.startswith('action:')]
                    if fault == 'ok':
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertEqual(actions, ['action:set:bootcount', 'action:guard-stop',
                            'action:set:bootcmd', 'action:set:changing_bootcmd'])
                    elif fault == 'dry-run':
                        self.assertEqual(result.returncode, 0)
                        self.assertEqual(actions, [])
                    else:
                        self.assertNotEqual(result.returncode, 0)
                        self.assertEqual(actions, ['action:set:bootcount']
                            if fault in ('write', 'stale', 'moved') else [], (family, slot, fault))

    def test_installer_helpers_reject_expected_output_with_error_status(self):
        helpers = '\n'.join(function(name) for name in (
            'setenv_checked', 'jaguar_clear_bootcount', 'cheetah_clear_bootcount', 'thor_miami_clear_bootcount'))
        for family in ('jaguar', 'cheetah', 'thor', 'miami'):
            for failure in ('already-zero', 'post-write', 'post-write-image'):
                body = helpers + r'''
FAMILY=$1; fault=$2; G_VALUE=9
[ "$fault" != already-zero ] || G_VALUE=0
RUN=2 R0=1
die() { exit 1; }
getenv() {
    case "$1" in
    image) echo 1; [ "$fault:$G_VALUE" != post-write-image:0 ];;
    bootcount) echo "$G_VALUE"; [ "$fault" != already-zero ] && [ "$fault:$G_VALUE" != post-write:0 ];;
    esac
}
fw_setenv() { G_VALUE=$2; }
step() { shift; "$@"; }
case "$FAMILY" in
jaguar) jaguar_clear_bootcount;; cheetah) cheetah_clear_bootcount;; *) thor_miami_clear_bootcount;;
esac
'''
                result = subprocess.run(COMMAND + ['-s', '--', family, failure], input=body,
                                        text=True, capture_output=True)
                if failure == 'post-write-image' and family == 'jaguar':
                    continue  # Jaguar's family selector policy is checked separately.
                self.assertNotEqual(result.returncode, 0, (family, failure, result))

    def test_core_verified_value_write_checks_getter_status(self):
        source = (ROOT / 'package/cambium/cambium-ab/files/cambium-ab.sh').read_text()
        start = source.index('ab_setenv() {')
        stop = source.index('\n}', start) + 2
        program = source[start:stop] + r'''
ab_env_config() { AB_ENV_CONFIG=mock; }
fw_setenv() { return 0; }
ab_getenv() { echo 0; return 1; }
ab_setenv bootcount 0
'''
        result = subprocess.run(COMMAND + ['-s'], input=program, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
