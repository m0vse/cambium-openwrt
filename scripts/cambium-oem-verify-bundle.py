#!/usr/bin/env python3
"""Workstation-side authenticated payload verification; never authorizes writes."""
import argparse
import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile


def verify(bundle, public_key, model, sku):
    rows = [line.split('\t') for line in pathlib.Path(__file__).with_name('cambium-oem-models.tsv').read_text().splitlines()
            if line and not line.startswith('#')]
    matches = [row for row in rows if len(row) == 9 and row[0] == sku and row[2] == model]
    if len(matches) != 1:
        raise ValueError('model/SKU is not in the reviewed source manifest')
    if matches[0][8] == 'unsupported':
        raise ValueError('known model is currently unsupported; no changes permitted')
    bundle = pathlib.Path(bundle).resolve(strict=True)
    public_key = pathlib.Path(public_key).resolve(strict=True)
    if public_key == bundle or bundle in public_key.parents:
        raise ValueError('trusted public key must be supplied independently of the bundle')
    manifest_path = bundle / 'manifest.json'
    signature_path = bundle / 'manifest.sig'
    for path in (manifest_path, signature_path):
        if path.is_symlink() or not path.is_file():
            raise ValueError('manifest and signature must be ordinary files')
    if manifest_path.stat().st_size > 65536 or signature_path.stat().st_size > 16384:
        raise ValueError('manifest/signature exceeds the size limit')
    # Verify the same immutable bytes we parse, not a file which can be changed
    # between a signature subprocess and a subsequent JSON read.
    manifest_bytes = manifest_path.read_bytes()
    signature_bytes = signature_path.read_bytes()
    if len(manifest_bytes) > 65536 or len(signature_bytes) > 16384:
        raise ValueError('manifest/signature exceeds the size limit')
    with tempfile.TemporaryDirectory(prefix='cambium-oem-verify-') as temporary:
        frozen_key = pathlib.Path(temporary) / 'trusted.pub'
        frozen_signature = pathlib.Path(temporary) / 'manifest.sig'
        frozen_key.write_bytes(public_key.read_bytes())
        frozen_signature.write_bytes(signature_bytes)
        result = subprocess.run(['openssl', 'dgst', '-sha256', '-verify', str(frozen_key),
                                 '-signature', str(frozen_signature)], input=manifest_bytes,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise ValueError('manifest signature does not match the independently trusted key')
    def unique_object(pairs):
        value = {}
        for key, item in pairs:
            if key in value:
                raise ValueError('duplicate JSON key in authenticated manifest')
            value[key] = item
        return value
    manifest = json.loads(manifest_bytes, object_pairs_hook=unique_object)
    if not isinstance(manifest, dict):
        raise ValueError('manifest must be a JSON object')
    if type(manifest.get('schema')) is not int or manifest['schema'] != 1:
        raise ValueError('unsupported bundle schema')
    if manifest.get('model') != model or manifest.get('sku_hex') != sku:
        raise ValueError('authenticated manifest is for a different exact model/SKU')
    if manifest.get('image_compatible') != matches[0][5]:
        raise ValueError('model/SKU/image compatibility is not in the reviewed source manifest')
    payloads = manifest.get('payloads')
    if not isinstance(payloads, list) or len(payloads) != 2:
        raise ValueError('exactly kernel and rootfs payloads are required')
    roles = set()
    names = set()
    for payload in payloads:
        if not isinstance(payload, dict):
            raise ValueError('invalid payload record')
        role = payload.get('role')
        name = payload.get('file')
        size = payload.get('size')
        digest = payload.get('sha256')
        if role not in ('kernel', 'rootfs') or role in roles:
            raise ValueError('missing or duplicate payload role')
        if not isinstance(name, str) or pathlib.PurePath(name).name != name or name in ('', '.', '..') or name in names:
            raise ValueError('payload must have a unique direct filename without path traversal')
        roles.add(role)
        names.add(name)
        if type(size) is not int or size <= 0 or not isinstance(digest, str) or len(digest) != 64:
            raise ValueError('invalid payload size or digest')
        if any(c not in '0123456789abcdef' for c in digest):
            raise ValueError('payload digest must be lowercase SHA256')
        path = bundle / name
        if path.is_symlink() or not path.is_file() or path.stat().st_size != size:
            raise ValueError('payload is missing, linked or has the wrong length')
        checksum = hashlib.sha256()
        with path.open('rb') as data:
            while chunk := data.read(1024 * 1024):
                checksum.update(chunk)
        if checksum.hexdigest() != digest:
            raise ValueError('authenticated payload digest mismatch')
    return {'schema': 1, 'model': model, 'sku_hex': sku,
            'authenticated_payloads': True, 'write_enabled': False,
            'remaining': ['FIT/uImage and rootfs semantics', 'actual inactive-volume capacity',
                          'current OEM capability contract', 'critical recovery and trial rollback']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle')
    parser.add_argument('--public-key', required=True, help='independently pinned release signing public key')
    parser.add_argument('--model', required=True)
    parser.add_argument('--sku-hex', required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(verify(args.bundle, args.public_key, args.model, args.sku_hex), sort_keys=True))
    except (ValueError, OSError, KeyError, TypeError, json.JSONDecodeError) as error:
        print(f'cambium-oem-verify-bundle: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
