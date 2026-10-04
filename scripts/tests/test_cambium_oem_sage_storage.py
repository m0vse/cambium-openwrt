"""Synthetic source mounts; no storage mutation or hardware qualification."""
import os
from pathlib import Path
import subprocess
import unittest
import test_cambium_oem_sage_prepare as captures

SCRIPT = Path(__file__).resolve().parents[1] / 'cambium-oem-sage-storage-check.sh'


class SourceStorageTests(unittest.TestCase):
    def setUp(self):
        self.capture = captures.CaptureTests()
        self.capture.setUp()
        self.addCleanup(self.capture.tearDown)
        self.root = self.capture.root
        self.capture.put('etc/version', 'PRODUCT=sage\nVERSION=4.2.3.3-r10\n')
        (self.root / 'root').mkdir()
        self.capture.put('proc/mounts', 'ubi0:rootfs0 / ubifs rw,relatime 0 0\nubi0:nvram /mnt/flash ubifs rw 0 0\n')

    def check(self):
        before = {str(p): p.read_bytes() for p in self.root.rglob('*') if p.is_file()}
        result = subprocess.run(['sh', str(SCRIPT), 'inspect-capture', str(self.root)],
                                text=True, capture_output=True,
                                env={**os.environ, 'PATH': str(self.capture.bin) + ':' + os.environ['PATH']})
        self.assertEqual(before, {str(p): p.read_bytes() for p in self.root.rglob('*') if p.is_file()})
        return result

    def test_direct_active_ubifs_with_shared_etc_overlay_is_allowed_as_evidence(self):
        self.capture.put('proc/mounts', 'ubi0:rootfs0 / ubifs rw 0 0\noverlay /etc overlay rw,upperdir=/mnt/flash/etc 0 0\n')
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('storage_check=passed', result.stdout)
        self.assertIn('write_enabled=no', result.stdout)
        self.assertFalse((self.root / 'root/.cambium-installer-source').exists())

    def test_other_bank_by_numeric_device(self):
        self.capture.put('environment/image', '1\n')
        self.capture.put('proc/cmdline', 'ubi.mtd=fs root=ubi0:rootfs1\n')
        self.capture.put('proc/mounts', '/dev/ubi0_3 / ubifs rw 0 0\n')
        self.assertEqual(self.check().returncode, 0)

    def test_wrong_volatile_readonly_shared_and_covering_mounts_refused(self):
        mounts = ('ubi0:rootfs1 / ubifs rw 0 0\n', 'tmpfs / tmpfs rw 0 0\n',
                  'ubi0:rootfs0 / ubifs ro 0 0\n', 'ubi0:nvram / ubifs rw 0 0\n',
                  'ubi0:rootfs0 / ubifs rw 0 0\ntmpfs /root tmpfs rw 0 0\n',
                  'ubi0:rootfs0 / ubifs rw 0 0\nubi0:rootfs1 /root/key ubifs rw 0 0\n',
                  'ubi0:rootfs0 / ubifs rw 0 0\nubi0:rootfs0 / ubifs rw 0 0\n')
        for value in mounts:
            with self.subTest(mounts=value):
                self.capture.put('proc/mounts', value)
                self.assertNotEqual(self.check().returncode, 0)

    def test_unknown_or_duplicate_release_refused(self):
        for value in ('PRODUCT=sage\nVERSION=4.2.3.1-r17\n',
                      'PRODUCT=sage\nVERSION=4.2.3.3-r10\nVERSION=4.2.3.3-r10\n'):
            self.capture.put('etc/version', value)
            self.assertNotEqual(self.check().returncode, 0)

    def test_standalone_context_uses_factory_label_mac_without_stock_libraries(self):
        context = SCRIPT.with_name('cambium-oem-sage-context.sh')
        self.capture.put('dev/mtd6ro', bytes.fromhex('05ca01000c00') + b'000456abcdef' + b'\0PL-E410XXXB-EU\0')
        def run():
            return subprocess.run(['sh', str(context), 'inspect-capture', str(self.root)], capture_output=True, text=True)
        result = run()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.rstrip('\n').split('\t'), ['000456abcdef', 'sage', 'E410B', '0', '', '', ''])
        self.capture.put('environment/sage_installer_target', '1')
        self.assertNotEqual(run().returncode, 0, 'incomplete pending transaction must refuse')
        self.capture.put('environment/sage_installer_job', 'a' * 32)
        self.capture.put('environment/sage_installer_image', 'b' * 64)
        self.assertEqual(run().returncode, 0)
        self.capture.put('dev/mtd6ro', bytes.fromhex('05ca01000c00') + b'010456abcdef' + b'\0PL-E410XXXB-EU\0')
        self.assertNotEqual(run().returncode, 0, 'multicast factory identity must refuse')


if __name__ == '__main__':
    unittest.main()
