#!/usr/bin/env python3
"""Exercise the real shell wrapper with synthetic BDFs, never OEM/ART data."""
import hashlib
import os
from pathlib import Path
import shlex
import struct
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).parents[1] / 'files/cambium-board-data'
SCRIPT = SOURCE.read_text()
FUNCTIONS = SCRIPT[SCRIPT.index('bdf_le32() {'):SCRIPT.index('missing_files() {')]
KEY = b'bus=pci,qmi-chip-id=0,qmi-board-id=255,variant=CambiumNetworks-XE34'


class WrapperTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='xe34-api2-test.')
        self.root = Path(self.tmp.name)
        self.fw = self.root / 'ath11k/QCN9074/hw1.0'
        self.fw.mkdir(parents=True)
        self.raw = self.fw / 'board.bin'
        self.target = self.fw / 'board-2.bin'
        self.payload = bytes(range(256)) * 512

    def tearDown(self):
        self.tmp.cleanup()

    def run_wrapper(self, model='cambiumnetworks,xe3-4', fault=''):
        env = dict(os.environ, TEST_FW=str(self.root), TEST_MODEL=model)
        script = 'FW_DIR="$TEST_FW"\nboard_name() { printf "%s" "$TEST_MODEL"; }\nlog() { :; }\nsha256() { sha256sum "$1" | cut -d " " -f1; }\n'
        shell = shlex.split(os.environ.get('BDF_TEST_SHELL', '/bin/sh'))
        return subprocess.run(shell, input=script + FUNCTIONS + '\n' + fault + '\nxe34_pci_api2\n', text=True, env=env, capture_output=True)

    def test_exact_key_and_unchanged_payload(self):
        self.raw.write_bytes(self.payload)
        self.assertEqual(self.run_wrapper().returncode, 0)
        data = self.target.read_bytes()
        self.assertEqual(data[:20], b'QCA-ATH11K-BOARD\0\0\0\0')
        outer_id, outer_len = struct.unpack_from('<II', data, 20)
        self.assertEqual((outer_id, outer_len), (0, len(data) - 28))
        name_id, name_len = struct.unpack_from('<II', data, 28)
        self.assertEqual((name_id, name_len), (0, len(KEY)))
        self.assertEqual(data[36:36 + name_len], KEY)
        offset = 36 + (name_len + 3) // 4 * 4
        data_id, data_len = struct.unpack_from('<II', data, offset)
        self.assertEqual((data_id, data_len), (1, 131072))
        self.assertEqual(data[offset + 8:], self.payload)
        self.assertEqual(self.raw.read_bytes(), self.payload)
        self.assertEqual(self.target.stat().st_mode & 0o777, 0o644)
        self.assertFalse(list(self.fw.glob('*.tmp.*')))

    def test_repeated_run_does_not_replace_identical_container(self):
        self.raw.write_bytes(self.payload)
        self.assertEqual(self.run_wrapper().returncode, 0)
        before = self.target.stat()
        self.assertEqual(self.run_wrapper().returncode, 0)
        after = self.target.stat()
        self.assertEqual((before.st_ino, before.st_mtime_ns), (after.st_ino, after.st_mtime_ns))

    def test_changes_only_selected_model(self):
        for model in ['cambiumnetworks,xe3-4tn', 'cambiumnetworks,xv2-2t1', 'cambiumnetworks,xv3-8', 'unknown']:
            self.target.write_bytes(b'original')
            self.assertEqual(self.run_wrapper(model).returncode, 0)
            self.assertEqual(self.target.read_bytes(), b'original')

    def test_missing_or_wrong_size_preserves_existing_container(self):
        for size in [None, 0, 65536, 131071, 131073]:
            if self.raw.exists():
                self.raw.unlink()
            if size is not None:
                self.raw.write_bytes(b'\x55' * size)
            self.target.write_bytes(b'original')
            self.assertNotEqual(self.run_wrapper().returncode, 0)
            self.assertEqual(self.target.read_bytes(), b'original')
            self.assertFalse(list(self.fw.glob('*.tmp.*')))

    def test_failed_commit_preserves_source(self):
        self.raw.write_bytes(self.payload)
        self.target.mkdir()
        (self.target / 'nonempty').write_bytes(b'existing')
        result = self.run_wrapper()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(hashlib.sha256(self.raw.read_bytes()).digest(), hashlib.sha256(self.payload).digest())

    def test_source_read_chmod_and_rename_failures_are_atomic(self):
        self.raw.write_bytes(self.payload)
        for fault in ['cat() { return 1; }', 'chmod() { return 1; }', 'mv() { return 1; }']:
            self.target.write_bytes(b'original')
            self.assertNotEqual(self.run_wrapper(fault=fault).returncode, 0)
            self.assertEqual(self.target.read_bytes(), b'original')
            self.assertEqual(self.raw.read_bytes(), self.payload)
            self.assertFalse(list(self.fw.glob('*.tmp.*')))

    def test_generator_write_failure_preserves_target(self):
        self.raw.write_bytes(self.payload)
        self.target.write_bytes(b'original')
        # Only the initial container printf fails; the payload cannot mask it.
        fault = 'printf() { case "$1" in QCA-ATH11K-BOARD*) return 1;; esac; command printf "$@"; }'
        self.assertNotEqual(self.run_wrapper(fault=fault).returncode, 0)
        self.assertEqual(self.target.read_bytes(), b'original')
        self.assertFalse(list(self.fw.glob('*.tmp.*')))

    def test_target_symlink_is_replaced_without_modifying_referent(self):
        self.raw.write_bytes(self.payload)
        other = self.root / 'other-board'
        other.write_bytes(b'other')
        self.target.symlink_to(other)
        self.assertEqual(self.run_wrapper().returncode, 0)
        self.assertFalse(self.target.is_symlink())
        self.assertEqual(other.read_bytes(), b'other')
        self.assertEqual(self.raw.read_bytes(), self.payload)


if __name__ == '__main__':
    unittest.main()
