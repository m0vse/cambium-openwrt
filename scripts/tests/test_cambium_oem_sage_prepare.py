#!/usr/bin/env python3
"""Synthetic read-only captures: these tests do not qualify OEM or hardware."""
import pathlib
import os
import struct
import subprocess
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'cambium-oem-sage-prepare.sh'


class CaptureTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name)
        self.bin = self.root / 'test-bin'
        self.bin.mkdir()
        for command in ('fw_setenv', 'ubiupdatevol', 'ubiformat', 'flash_erase', 'reboot', 'sysupgrade'):
            path = self.bin / command
            path.write_text('#!/bin/sh\necho invoked >> "' + str(self.root / 'MUTATOR_INVOKED') + '"\nexit 77\n')
            path.chmod(0o755)
        self.put('proc/mtd', '''dev: size erasesize name
mtd2: 00010000 00010000 "0:APPSBLENV"
mtd4: 00010000 00010000 "0:ART"
mtd6: 00010000 00010000 "mfginfo"
mtd9: 08000000 00020000 "fs"
''')
        self.put('etc/fw_env.config', '/dev/mtd2 0x0 0x00010000 0x00010000 1\n')
        self.put('dev/mtd6ro', b'\0PL-E410XXXB-EU\0')
        self.put('sys/firmware/devicetree/base/cambium-platform/board-sku', struct.pack('>I', 21))
        self.put('proc/cmdline', 'console=ttyMSM0 ubi.mtd=fs root=ubi0:rootfs0 rootfstype=ubifs\n')
        self.put('environment/image', '0\n')
        self.put('environment/bootcmd', 'bootipq\n')
        for name, value in {'mtd_num': 9, 'eraseblock_size': 126976, 'min_io_size': 2048}.items():
            self.put(f'sys/class/ubi/ubi0/{name}', f'{value}\n')
        for index, name in enumerate(('linux0', 'rootfs0', 'linux1', 'rootfs1')):
            base = f'sys/class/ubi/ubi0_{index}'
            for key, value in {'name': name, 'reserved_ebs': 34 if index % 2 == 0 else 372,
                               'usable_eb_size': 126976}.items():
                self.put(f'{base}/{key}', f'{value}\n')

    def tearDown(self):
        self.tmp.cleanup()

    def put(self, name, data):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data.encode() if isinstance(data, str) else data)

    def run_capture(self):
        before = {str(p): p.read_bytes() for p in self.root.rglob('*') if p.is_file()}
        result = subprocess.run(['sh', str(SCRIPT), 'inspect-capture', str(self.root)],
                                capture_output=True, text=True,
                                env={**os.environ, 'PATH': str(self.bin) + ':' + os.environ['PATH']})
        after = {str(p): p.read_bytes() for p in self.root.rglob('*') if p.is_file()}
        self.assertEqual(before, after, 'inspection must not modify captured evidence')
        return result

    def test_e410b_variable_indices_and_factory_capacity(self):
        result = self.run_capture()
        self.assertEqual(result.returncode, 0, result.stderr)
        for expected in ('evidence=offline', 'model=E410B', 'inactive_bank=1',
                         'root_capacity=47235072', 'write_enabled=no'):
            self.assertIn(expected, result.stdout)

    def test_alternate_running_bank_and_reduced_capacity(self):
        self.put('dev/mtd6ro', b'\0PL-E410XXXA-EU\0')
        self.put('sys/firmware/devicetree/base/cambium-platform/board-sku', struct.pack('>I', 10))
        self.put('environment/image', '1\n')
        self.put('proc/cmdline', 'ubi.mtd=fs root=ubi0:rootfs1\n')
        self.put('sys/class/ubi/ubi0_1/reserved_ebs', '305\n')
        result = self.run_capture()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('model=E410\n', result.stdout)
        self.assertIn('inactive_bank=0', result.stdout)
        self.assertIn('root_capacity=38727680', result.stdout)

    def test_refusals(self):
        mutations = [
            ('proc/mtd', 'mtd9: 08000000 00020000 "fs"\nmtd8: 08000000 00020000 "fs"\n', 'duplicate'),
            ('environment/image', '1\n', 'disagree'),
            ('environment/bootcmd', 'run trial\n', 'boot state'),
            ('sys/class/ubi/ubi0/mtd_num', '10\n', 'disagree'),
            ('sys/class/ubi/ubi0/min_io_size', '4096\n', 'minimum I/O'),
            ('sys/class/ubi/ubi0_2/name', 'linux0\n', 'volume ID'),
            ('sys/class/ubi/ubi0_3/reserved_ebs', '999999\n', 'capacity'),
            ('sys/class/ubi/ubi0_3/reserved_ebs', 'bad\n', 'numeric'),
            ('etc/fw_env.config', '/dev/mtd8 0x0 0x10000 0x10000\n', 'APPSBLENV'),
            ('etc/fw_env.config', '/dev/mtd2 0x10000 0x10000 0x10000\n', 'offset/geometry'),
            ('dev/mtd6ro', b'\0PL-E510XXX-EU\0', 'unsupported'),
            ('dev/mtd6ro', b'\0PL-E410XXX-EU\0', 'unsupported'),
            ('dev/mtd6ro', b'\0PL-E410XXXB-EU\0PL-E410XXXB-US\0', 'ambiguous'),
            ('sys/firmware/devicetree/base/cambium-platform/board-sku', struct.pack('>I', 10), 'SKU disagree'),
            ('proc/cmdline', 'ubi.mtd=fs root=ubi0:rootfs0 root=ubi0:rootfs1', 'duplicate root'),
            ('proc/cmdline', 'ubi.mtd=fs ubi.mtd=rootfs root=ubi0:rootfs0', 'duplicate ubi'),
            ('proc/cmdline', 'ubi.mtd=rootfs root=ubi0:rootfs0', 'attachment'),
        ]
        for name, data, expected in mutations:
            with self.subTest(name=name, expected=expected):
                path = self.root / name
                original = path.read_bytes()
                self.put(name, data)
                result = self.run_capture()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected, result.stderr)
                self.assertNotIn('write_enabled', result.stdout)
                path.write_bytes(original)

    def test_second_attachment_refused(self):
        self.put('sys/class/ubi/ubi1/mtd_num', '9\n')
        result = self.run_capture()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('multiple UBI', result.stderr)

    def test_openwrt_refused(self):
        self.put('etc/openwrt_release', "DISTRIB_ID='OpenWrt'\n")
        self.assertIn('refuses an OpenWrt', self.run_capture().stderr)

if __name__ == '__main__':
    unittest.main()
