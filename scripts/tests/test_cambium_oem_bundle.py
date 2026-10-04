#!/usr/bin/env python3
"""Real signature checks with a temporary synthetic signer, never real keys."""
import hashlib
import importlib.util
import json
import pathlib
import shutil
import subprocess
import tempfile
import unittest

PATH = pathlib.Path(__file__).resolve().parents[1] / 'cambium-oem-verify-bundle.py'
SPEC = importlib.util.spec_from_file_location('bundle', PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


@unittest.skipUnless(shutil.which('openssl'), 'requires workstation OpenSSL')
class BundleTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name)
        self.bundle = self.root / 'bundle'
        self.bundle.mkdir()
        self.private = self.root / 'synthetic.key'
        self.public = self.root / 'synthetic.pub'
        self.command('openssl', 'genpkey', '-algorithm', 'EC', '-pkeyopt', 'ec_paramgen_curve:P-256', '-out', str(self.private))
        self.command('openssl', 'pkey', '-in', str(self.private), '-pubout', '-out', str(self.public))
        self.manifest = {'schema': 1, 'model': 'E410', 'sku_hex': '0000000a',
                         'image_compatible': 'cambiumnetworks,e410', 'payloads': []}
        for role in ('kernel', 'rootfs'):
            data = ('synthetic ' + role).encode()
            (self.bundle / (role + '.bin')).write_bytes(data)
            self.manifest['payloads'].append({'role': role, 'file': role + '.bin', 'size': len(data),
                                              'sha256': hashlib.sha256(data).hexdigest()})
        self.sign()

    def tearDown(self):
        self.tmp.cleanup()

    def command(self, *args):
        subprocess.run(args, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def sign(self):
        path = self.bundle / 'manifest.json'
        path.write_text(json.dumps(self.manifest))
        self.command('openssl', 'dgst', '-sha256', '-sign', str(self.private),
                     '-out', str(self.bundle / 'manifest.sig'), str(path))

    def verify(self, model='E410', sku='0000000a'):
        return MODULE.verify(self.bundle, self.public, model, sku)

    def test_signed_payloads_remain_write_disabled(self):
        result = self.verify()
        self.assertTrue(result['authenticated_payloads'])
        self.assertFalse(result['write_enabled'])

    def test_substituted_manifest_or_payload_refused(self):
        (self.bundle / 'manifest.json').write_text('{}')
        with self.assertRaisesRegex(ValueError, 'signature'):
            self.verify()
        self.sign()
        (self.bundle / 'kernel.bin').write_bytes(b'x' * self.manifest['payloads'][0]['size'])
        with self.assertRaisesRegex(ValueError, 'digest mismatch'):
            self.verify()

    def test_wrong_model_and_self_supplied_trust_refused(self):
        with self.assertRaisesRegex(ValueError, 'different exact model'):
            self.verify('E410B', '00000015')
        key = self.bundle / 'bundled.pub'
        shutil.copyfile(self.public, key)
        with self.assertRaisesRegex(ValueError, 'independently'):
            MODULE.verify(self.bundle, key, 'E410', '0000000a')

    def test_unsupported_model_refused_before_opening_bundle(self):
        with self.assertRaisesRegex(ValueError, 'currently unsupported'):
            MODULE.verify(self.root / 'does-not-exist', self.root / 'no-key', 'XE3-4TN', '00000021')

    def test_signed_path_and_role_abuse_refused(self):
        for key, value, message in (('file', '../outside.bin', 'traversal'),
                                    ('role', 'rootfs', 'duplicate'),
                                    ('size', True, 'size or digest')):
            original = self.manifest['payloads'][0][key]
            self.manifest['payloads'][0][key] = value
            self.sign()
            with self.assertRaisesRegex(ValueError, message):
                self.verify()
            self.manifest['payloads'][0][key] = original

    def test_payload_symlink_refused(self):
        target = self.root / 'outside.bin'
        target.write_bytes((self.bundle / 'kernel.bin').read_bytes())
        (self.bundle / 'kernel.bin').unlink()
        (self.bundle / 'kernel.bin').symlink_to(target)
        with self.assertRaisesRegex(ValueError, 'linked'):
            self.verify()


if __name__ == '__main__':
    unittest.main()
