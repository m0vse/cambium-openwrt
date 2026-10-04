#!/usr/bin/env python3
"""Family distinctions and unsafe-bank refusals, using synthetic OEM captures."""
import os
import pathlib
import struct
import subprocess
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'cambium-oem-prepare.sh'


class FamilyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def put(self, path, data):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data.encode() if isinstance(data, str) else data)

    def capture(self, sku, size='06000000', boot='bootipq', slot=1):
        self.put('sys/firmware/devicetree/base/cambium-platform/board-sku', struct.pack('>I', sku))
        self.put('proc/mtd', f'''mtd7: {size} 00020000 "rootfs"
mtd9: {size} 00020000 "rootfs_1"
mtd12: 00010000 00001000 "0:APPSBLENV"
''')
        self.put('tmp/fw_env.config', '/dev/mtd12 0x0 0x00010000 0x00010000 1\n')
        self.put('environment/image', str(slot))
        self.put('environment/bootcmd', boot)
        self.put('proc/cmdline', 'ubi.mtd=' + ('rootfs_1' if slot else 'rootfs') + ' root=mtd:ubi_rootfs')
        for key, value in {'mtd_num': 9 if slot else 7, 'eraseblock_size': 126976, 'min_io_size': 2048}.items():
            self.put('sys/class/ubi/ubi0/' + key, str(value))
        self.put('sys/class/ubi/ubi0_0/name', 'kernel')
        self.put('sys/class/ubi/ubi0_1/name', 'ubi_rootfs')

    def run_capture(self):
        before = {str(p): p.read_bytes() for p in self.root.rglob('*') if p.is_file()}
        result = subprocess.run(['sh', str(SCRIPT), 'inspect-capture', str(self.root)], capture_output=True, text=True)
        self.assertEqual(before, {str(p): p.read_bytes() for p in self.root.rglob('*') if p.is_file()})
        return result

    def test_qualified_capture_models(self):
        for sku, size, boot, model in ((20, '03400000', 'bootipq', 'XV2-2'),
                                      (31, '06000000', 'bootipq', 'XV2-2T1'),
                                      (32, '06000000', 'bootipq', 'XE3-4'),
                                      (35, '06000000', 'bootipq', 'XV2-21X'),
                                      (19, '06000000', 'aq_load_fw&&bootipq', 'XV3-8')):
            for slot in (0, 1):
                with self.subTest(model=model, slot=slot):
                    self.capture(sku, size, boot, slot)
                    result = self.run_capture()
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn('model=' + model, result.stdout)
                    self.assertIn('running_bank=' + str(slot), result.stdout)
                    self.assertIn('write_enabled=no', result.stdout)

    def test_unknown_profile_geometries_are_named(self):
        for sku, model in ((11, 'E600'), (13, 'E430W'), (14, 'E700'), (15, 'E430H'),
                           (16, 'E510'), (22, 'XV2-2T0'), (33, 'XE3-4TN'),
                           (34, 'XV2-22H'), (36, 'XV2-23T')):
            self.capture(sku)
            result = self.run_capture()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(model, result.stderr)

    def test_xv2_2_cannot_inherit_96mib_geometry(self):
        self.capture(20)
        self.assertIn('geometry rootfs', self.run_capture().stderr)

    def test_thor_phy_boot_requirement(self):
        self.capture(19)
        self.assertIn('boot command', self.run_capture().stderr)

    def test_bank_and_configuration_refusals(self):
        self.capture(35)
        mutations = [('environment/image', '0', 'disagreement'),
                     ('sys/class/ubi/ubi0/mtd_num', '7', 'disagree'),
                     ('sys/class/ubi/ubi0_0/name', 'ubi_rootfs', 'identity'),
                     ('etc/fw_env.config', '/dev/mtd17 0x0 0x10000 0x10000', 'competing'),
                     ('proc/cmdline', 'ubi.mtd=rootfs_1 ubi.mtd=rootfs root=mtd:ubi_rootfs', 'duplicate')]
        for path, value, message in mutations:
            target = self.root / path
            old = target.read_bytes() if target.exists() else None
            self.put(path, value)
            result = self.run_capture()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(message, result.stderr)
            if old is None:
                target.unlink()
            else:
                target.write_bytes(old)

    def test_gambit_oem_raw_layout(self):
        self.capture(6)
        self.put('tmp/fw_env.config', '/dev/mtd1 0x0 0x10000 0x10000')
        self.put('proc/mtd', '''mtd1: 00010000 00010000 "u-boot-env"
mtd3: 00010000 00010000 "mfginfo"
mtd4: 00010000 00010000 "ART"
mtd6: 00300000 00020000 "linux0"
mtd7: 02d00000 00020000 "rootfs0"
mtd8: 00300000 00020000 "linux1"
mtd9: 02d00000 00020000 "rootfs1"
''')
        self.put('environment/bootcmd', 'nboot 0x81000000 0 ${load_addr}')
        self.put('environment/load_addr', '0x03000000')
        self.put('proc/cmdline', 'console=ttyS0 root=/dev/mtdblock9 rootfstype=yaffs2')
        result = self.run_capture()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('family=gambit', result.stdout)
        self.put('environment/load_addr', '0x00000000')
        self.assertIn('banks disagree', self.run_capture().stderr)

    def test_unknown_sku(self):
        self.capture(99)
        self.assertIn('unknown unsupported SKU', self.run_capture().stderr)


if __name__ == '__main__':
    unittest.main()
