#!/usr/bin/env python3
"""Regression checks for the read-only E400 raw NAND parity verifier."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    "verify_gambit_ecc", Path(__file__).resolve().parents[1] / "scripts/verify-gambit-ecc.py")
ecc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ecc)


class Hamming(unittest.TestCase):
    def test_erased_page(self):
        self.assertEqual(ecc.verify(b"\xff" * 2112), 1)

    def test_zero_step(self):
        self.assertEqual(ecc.hamming256(bytes(256)), b"\xff" * 3)

    def test_single_bit_vector(self):
        self.assertEqual(ecc.hamming256(b"\x01" + bytes(255)), b"\xaa\xaa\xab")

    def test_wrong_oob_rejected(self):
        with self.assertRaises(ValueError):
            ecc.verify(b"\xff" * 2111 + b"\x00")

    def test_incomplete_page_rejected(self):
        with self.assertRaises(ValueError):
            ecc.verify(b"\xff" * 2048)


if __name__ == "__main__":
    unittest.main()
