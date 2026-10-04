"""Execute the real POSIX writer with isolated command/device fixtures.

No test can reach an AP or a real UBI device. Every mutation command is replaced
by a bounded fixture executable. These are failure-boundary tests, not hardware
qualification or proof of real flash power-loss semantics.
"""
import hashlib
from pathlib import Path
import subprocess
import tempfile
import unittest

LIB = Path(__file__).resolve().parents[1] / 'lib/cambium-sage-pair-write.sh'
MOCK = r'''
import json, os, pathlib, sys
base = pathlib.Path(os.environ['FIXTURE'])
command, args = sys.argv[1], sys.argv[2:]
log = base / 'events'
events = log.read_text().splitlines() if log.exists() else []
events.append(command + ' ' + ' '.join(args))
log.write_text('\n'.join(events) + '\n')
if len(events) == int(os.environ.get('FAIL_STEP', '0')):
    sys.exit(1)
sysdir = base / 'sys'
dev = base / 'dev'
if command == 'ubirmvol':
    volume = int(args[2])
    node = sysdir / ('ubi0_' + str(volume))
    assert node.joinpath('name').read_text().strip() == 'rootfs_data' + os.environ['TARGET']
    import shutil
    shutil.rmtree(node)
    (dev / ('ubi0_' + str(volume))).unlink()
elif command == 'ubiupdatevol':
    if args[0] == '-t':
        pathlib.Path(args[1]).write_bytes(b'')
    else:
        data = pathlib.Path(args[1]).read_bytes()
        if os.environ.get('CORRUPT') == '1': data += b'bad'; data = b'BAD!' + data[4:]
        pathlib.Path(args[0]).write_bytes(data)
elif command == 'ubirsvol':
    volume, size = int(args[2]), int(args[4])
    assert volume == 2 * int(os.environ['TARGET']) + 1
    (sysdir / ('ubi0_' + str(volume)) / 'reserved_ebs').write_text(str(size // 126976))
elif command == 'ubimkvol':
    volume, name, size = int(args[2]), args[4], int(args[6])
    assert name == 'rootfs_data' + os.environ['TARGET']
    node = sysdir / ('ubi0_' + str(volume))
    node.mkdir()
    for key, value in [('name', name), ('reserved_ebs', str(size // 126976)), ('usable_eb_size', '126976')]:
        (node / key).write_text(value)
    (dev / ('ubi0_' + str(volume))).write_bytes(b'')
elif command != 'sync':
    raise AssertionError(command)
'''


class PairWriterTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)

    def fixture(self, active=0, source='target', free=41):
        for directory in ('sys', 'dev', 'source-key'):
            (self.base / directory).mkdir()
        self.active = active
        self.target = 1 - active
        (self.base / 'source-key/key.pem').write_bytes(b'original unique device key sentinel')
        (self.base / 'dev/art').write_bytes(b'own calibration')
        (self.base / 'dev/manufacturing').write_bytes(b'own revision serial MAC')
        (self.base / 'dev/appsblenv').write_bytes(b'current running boot environment')
        root_lebs = 285 if source == 'target' else 372
        volumes = {0: ('linux0', 34), 1: ('rootfs0', root_lebs),
                   2: ('linux1', 34), 3: ('rootfs1', root_lebs), 4: ('nvram', 167)}
        if source == 'target':
            volumes.update({5: ('rootfs_data1', 67), 6: ('rootfs_data0', 67), 7: ('shared', 20)})
        for volume, (name, lebs) in volumes.items():
            node = self.base / 'sys' / f'ubi0_{volume}'
            node.mkdir()
            for key, value in [('name', name), ('reserved_ebs', str(lebs)), ('usable_eb_size', '126976')]:
                (node / key).write_text(value)
            (self.base / 'dev' / f'ubi0_{volume}').write_bytes(f'original {name}'.encode())
        ubi = self.base / 'sys/ubi0'
        ubi.mkdir()
        for key, value in [('eraseblock_size', '126976'), ('min_io_size', '2048'),
                           ('mtd_num', '11'), ('avail_eraseblocks', str(free))]:
            (ubi / key).write_text(value)
        (self.base / 'cmdline').write_text(f'ubi.mtd=fs root=ubi0:rootfs{active} rootfstype=ubifs\n')
        (self.base / 'mounts').write_text(f'ubi0:rootfs{active} / ubifs rw 0 0\n')
        (self.base / 'kernel').write_bytes(bytes.fromhex('d00dfeed') + b'fit payload')
        (self.base / 'root').write_bytes(bytes.fromhex('31181006') + b'ubifs payload')
        (self.base / 'mock.py').write_text(MOCK)
        protected = [self.base / 'source-key/key.pem']
        protected += [self.base / 'dev' / name for name in ('art', 'manufacturing', 'appsblenv')]
        protected += [self.base / 'dev' / f'ubi0_{i}' for i in volumes
                      if i not in (2 * self.target, 2 * self.target + 1, 6 - self.target)]
        self.protected = {p: hashlib.sha256(p.read_bytes()).digest() for p in protected}

    def run_writer(self, lebs=372, fmt='ubifs', fail=0, corrupt=False, admission='qualified'):
        import os
        env = dict(os.environ, FIXTURE=str(self.base), TARGET=str(self.target),
                   FAIL_STEP=str(fail), CORRUPT=str(int(corrupt)))
        script = '''
set -u
. "$1"
CSP_SYS="$FIXTURE/sys" CSP_DEV="$FIXTURE/dev" CSP_CMDLINE="$FIXTURE/cmdline" CSP_MOUNTS="$FIXTURE/mounts"
CSP_ACTIVE="$2" CSP_FS_MTD=11 CSP_WRITE_ADMISSION="$5"
ubirmvol() { python3 "$FIXTURE/mock.py" ubirmvol "$@"; }
ubiupdatevol() { python3 "$FIXTURE/mock.py" ubiupdatevol "$@"; }
ubirsvol() { python3 "$FIXTURE/mock.py" ubirsvol "$@"; }
ubimkvol() { python3 "$FIXTURE/mock.py" ubimkvol "$@"; }
sync() { python3 "$FIXTURE/mock.py" sync; }
csp_stage_pair "$FIXTURE/kernel" "$FIXTURE/root" "$3" "$4"
'''
        return subprocess.run(['sh', '-c', script, 'test', str(LIB), str(self.active), str(lebs), fmt, admission],
                              env=env, text=True, capture_output=True)

    def assert_protected(self):
        for path, expected in self.protected.items():
            self.assertEqual(hashlib.sha256(path.read_bytes()).digest(), expected, str(path))

    def test_restore_both_inactive_pairs(self):
        for active in (0, 1):
            with self.subTest(active=active):
                if active:
                    import shutil
                    for path in self.base.iterdir():
                        shutil.rmtree(path) if path.is_dir() else path.unlink()
                self.fixture(active)
                result = self.run_writer()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f'inactive_pair_staged={1-active}', result.stdout)
                self.assertIn('boot_state_changed=no', result.stdout)
                self.assert_protected()

    def test_every_write_failure_preserves_active_bank_key_and_factory_data(self):
        for fail in range(1, 7):
            with self.subTest(fail=fail):
                import shutil
                for path in self.base.iterdir():
                    shutil.rmtree(path) if path.is_dir() else path.unlink()
                self.fixture()
                result = self.run_writer(fail=fail)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('inactive_pair_staged=', result.stdout)
                self.assert_protected()

    def test_squashfs_stage_reclaims_only_inactive_root_and_allocates_overlay(self):
        self.fixture(source='oem', free=0)
        (self.base / 'root').write_bytes(b'hsqs' + b'squashfs payload')
        result = self.run_writer(lebs=285, fmt='squashfs')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.base / 'sys/ubi0_5/name').read_text(), 'rootfs_data1')
        self.assert_protected()

    def test_squashfs_allocation_and_sync_failures_preserve_source(self):
        for fail in range(1, 7):
            with self.subTest(fail=fail):
                import shutil
                for path in self.base.iterdir():
                    shutil.rmtree(path) if path.is_dir() else path.unlink()
                self.fixture(source='oem', free=0)
                (self.base / 'root').write_bytes(b'hsqs' + b'squashfs payload')
                result = self.run_writer(lebs=285, fmt='squashfs', fail=fail)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('inactive_pair_staged=', result.stdout)
                self.assert_protected()

    def test_readback_corruption_never_reports_completion(self):
        self.fixture()
        result = self.run_writer(corrupt=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('inactive_pair_staged=', result.stdout)
        self.assert_protected()

    def test_unqualified_transaction_has_zero_mutations(self):
        self.fixture()
        result = self.run_writer(admission='unqualified')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.base / 'events').exists())
        self.assert_protected()

    def test_bad_identity_capacity_attachment_mount_and_payload_refuse_before_writes(self):
        cases = [('cmdline', 'ubi.mtd=fs root=ubi0:rootfs1'),
                 ('sys/ubi0/mtd_num', '12'), ('sys/ubi0/avail_eraseblocks', '0'),
                 ('mounts', 'ubi0:rootfs1 /candidate ubifs rw 0 0'),
                 ('sys/ubi0_2/name', 'linux0'), ('kernel', 'not a FIT'),
                 ('cmdline', 'ubi.mtd=fs root=ubi0:rootfs0 root=ubi0:rootfs1'),
                 ('cmdline', 'ubi.mtd=fs2 root=ubi0:rootfs0')]
        for relative, value in cases:
            with self.subTest(relative=relative):
                import shutil
                for path in self.base.iterdir():
                    shutil.rmtree(path) if path.is_dir() else path.unlink()
                self.fixture()
                (self.base / relative).write_text(value)
                result = self.run_writer()
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.base / 'events').exists())
                self.assert_protected()


if __name__ == '__main__':
    unittest.main()
