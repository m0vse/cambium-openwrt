#!/usr/bin/env python3
"""Manifest/source coverage fence: a new source model must receive a row."""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
MANIFEST = ROOT / 'scripts/cambium-oem-models.tsv'


class ManifestTests(unittest.TestCase):
    def test_source_coverage_and_schema(self):
        rows = [line.split('\t') for line in MANIFEST.read_text().splitlines()
                if line and not line.startswith('#')]
        identifiers = set()
        skus = set()
        for row in rows:
            self.assertEqual(len(row), 9, row)
            sku, family, model, layout, size, compatible, assets, status, production = row
            self.assertRegex(sku, r'^[0-9a-f]{8}$')
            self.assertNotIn(sku, skus)
            skus.add(sku)
            self.assertNotIn(compatible, identifiers)
            identifiers.add(compatible)
            self.assertIn(family, ('sage', 'jaguar', 'cheetah', 'thor', 'gambit'))
            self.assertIn(status, ('layout-only', 'uncaptured', 'identity-unqualified'))
            self.assertIn(production, ('unsupported', 'unqualified', 'qualified'))
            if status == 'uncaptured':
                self.assertEqual((layout, size, assets), ('-', '-', '-'))
                self.assertEqual(production, 'unsupported')
        source_identifiers = set()
        for source in (ROOT / 'target/linux').rglob('*.mk'):
            text = source.read_text().replace('\\\n', ' ')
            for devices in re.findall(r'^\s*SUPPORTED_DEVICES\s*[:+]?=\s*(.*)', text, re.M):
                source_identifiers.update(re.findall(r'cambium(?:networks)?,[a-z0-9-]+', devices))
        # Existing e410 alias points at the same physical model, not a new SKU.
        source_identifiers.discard('cambium,e410')
        self.assertEqual(identifiers, source_identifiers)


if __name__ == '__main__':
    unittest.main()
