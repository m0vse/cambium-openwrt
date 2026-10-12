#!/usr/bin/env python3
"""E400's own nboot counter hazard: only mocked environment and flash calls."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
MODULE = ROOT / 'package/cambium/cambium-gambit-support/files/cambium-ab-gambit.sh'
SHELL = os.environ.get('CAMBIUM_TEST_SHELL', 'sh')
COMMAND = [SHELL, 'sh'] if Path(SHELL).name == 'busybox' else [SHELL]


class CounterTests(unittest.TestCase):
    def run_module(self, code):
        return subprocess.run(COMMAND + ['-c', '. ' + shlex.quote(str(MODULE)) + '\n' + code],
                              text=True, capture_output=True)

    def test_each_bank_clears_before_args_and_nboot(self):
        for slot, offset in ((0, '0x00000000'), (1, '0x03000000')):
            result = self.run_module(f'ab_gambit_boot_command {slot}')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(result.stdout.startswith('setenv bootcount 0; setenv bootargs '))
            self.assertIn(f'ubi.mtd=rootfs{slot} root=/dev/ubiblock0_1', result.stdout)
            self.assertTrue(result.stdout.rstrip().endswith(f'nboot 0x83000000 0 {offset}'))

    def test_guard_saves_cleared_counter_before_runtime_args(self):
        for oem in (0, 1):
            result = self.run_module(f'''ab_getenv() {{ echo {oem}; }}
AB_STOCK_BOOTCMD="nboot 0x81000000 0 0x{'00000000' if oem == 0 else '03000000'}"
ab_gambit_guarded_command {1-oem}''')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('; setenv bootcount 0; saveenv; setenv bootcount 0; setenv bootargs ', result.stdout)

    def test_wrong_guard_bank_refused(self):
        result = self.run_module('ab_getenv() { echo 0; }; ab_gambit_guarded_command 0')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')

    def writer(self, count, failure=0, valid=True):
        with tempfile.TemporaryDirectory(prefix='gambit-counter-test-') as directory:
            root = Path(directory) / 'root'
            root.write_bytes(b'hsqs')
            return self.run_module(f'''
AB_ACTIVE=0 AB_TARGET=1 AB_KERNEL_MTD1=2 AB_MTD1=3 AB_TARGET_MTD=3
AB_ROOT={shlex.quote(str(root))} AB_KERNEL=mock AB_KERNEL_SIZE=64 AB_ROOT_SIZE=4
ab_gambit_layout() {{ return 0; }}
ab_gambit_check_kernel() {{ return {0 if valid else 1}; }}
ab_gambit_image_fits() {{ return 0; }}
ab_mtd_writable() {{ return 0; }}
ab_ubi_for_mtd() {{ return 1; }}
ab_getenv() {{ printf '%s\\n' {shlex.quote(count)}; }}
ab_setenv() {{ echo "env:$1=$2"; return {failure}; }}
ab_step() {{ echo "step:$1"; return 1; }}
ab_gambit_write_target_inner''')

    def test_eight_and_nine_reset_precede_first_erase(self):
        for count in ('8', '9'):
            result = self.writer(count)
            self.assertEqual(result.stdout.splitlines(), ['env:bootcount=0', 'step:erase linux1'])

    def test_reset_failure_prevents_every_flash_step(self):
        result = self.writer('9', failure=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout.splitlines(), ['env:bootcount=0'])

    def test_invalid_image_does_not_write_environment(self):
        result = self.writer('9', valid=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')

    def test_already_zero_does_not_rewrite_environment(self):
        result = self.writer('0')
        self.assertEqual(result.stdout.splitlines(), ['step:erase linux1'])

    def test_healthy_boot_still_clears_counter(self):
        result = self.run_module('ab_getenv() { echo 9; }; ab_setenv() { echo "$1=$2"; }; ab_gambit_healthy_boot')
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), 'bootcount=0')


if __name__ == '__main__':
    unittest.main()
