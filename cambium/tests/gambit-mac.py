#!/usr/bin/env python3
"""Regression checks for the E400 image verifier's OEM Ethernet MAC mapping."""
import importlib.util
from pathlib import Path
import struct
import unittest

spec = importlib.util.spec_from_file_location(
    "verify_gambit", Path(__file__).resolve().parents[1] / "scripts/verify-gambit.py")
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


def cells(*values):
    return struct.pack(">" + "I" * len(values), *values)


class FactoryMac(unittest.TestCase):
    def setUp(self):
        self.ethernet = {"nvmem-cell-names": b"mac-address\0",
                         "nvmem-cells": cells(1, 0)}
        self.partition = {"label": b"mfginfo\0"}
        self.cell = {"phandle": cells(1), "compatible": b"mac-base\0",
                     "reg": cells(6, 12), "#nvmem-cell-cells": cells(1)}
        self.nodes = {"/ahb/eth@19000000": self.ethernet,
                      "/flash/partition@7e0000": self.partition,
                      "/flash/partition@7e0000/nvmem-layout/macaddr@6": self.cell}

    def test_oem_mapping(self):
        verifier.verify_factory_mac(self.nodes)

    def test_radio_partition_rejected(self):
        self.partition["label"] = b"ART\0"
        with self.assertRaises(SystemExit):
            verifier.verify_factory_mac(self.nodes)

    def test_radio_offset_rejected(self):
        self.cell["reg"] = cells(0x1002, 6)
        with self.assertRaises(SystemExit):
            verifier.verify_factory_mac(self.nodes)

    def test_increment_rejected(self):
        self.ethernet["nvmem-cells"] = cells(1, 1)
        with self.assertRaises(SystemExit):
            verifier.verify_factory_mac(self.nodes)

    def test_missing_hex_decoder_rejected(self):
        del self.cell["compatible"]
        with self.assertRaises(SystemExit):
            verifier.verify_factory_mac(self.nodes)

    def test_previous_unindexed_cell_rejected(self):
        self.ethernet["nvmem-cells"] = cells(1)
        with self.assertRaises(SystemExit):
            verifier.verify_factory_mac(self.nodes)


if __name__ == "__main__":
    unittest.main()
