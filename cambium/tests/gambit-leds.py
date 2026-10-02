#!/usr/bin/env python3
"""Regression checks for the hardware-verified E400 LED map."""
import importlib.util
from pathlib import Path
import struct
import unittest

spec = importlib.util.spec_from_file_location(
    "verify_gambit", Path(__file__).resolve().parents[1] / "scripts/verify-gambit.py")
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


class Leds(unittest.TestCase):
    def setUp(self):
        self.nodes = {
            "/gpio": {"phandle": struct.pack(">I", 1), "gpio-controller": b"",
                      "compatible": b"qca,ar9340-gpio\0"},
            "/aliases": {"led-boot": b"/leds/power-green\0",
                         "led-running": b"/leds/power-green\0",
                         "led-failsafe": b"/leds/power-amber\0",
                         "led-upgrade": b"/leds/power-amber\0"}}
        for name, label, pin, polarity in (
                ("power-green", "green:status", 19, 1),
                ("power-amber", "amber:status", 22, 0),
                ("network-green", "green:lan", 20, 1),
                ("network-amber", "amber:lan", 18, 1)):
            self.nodes["/leds/" + name] = {
                "label": label.encode() + b"\0",
                "gpios": struct.pack(">III", 1, pin, polarity),
                "default-state": b"off\0"}

    def test_verified_map(self):
        verifier.verify_leds(self.nodes)

    def test_oem_table_polarity_rejected(self):
        self.nodes["/leds/power-amber"]["gpios"] = struct.pack(">III", 1, 22, 1)
        with self.assertRaises(SystemExit):
            verifier.verify_leds(self.nodes)

    def test_reset_gpio_rejected(self):
        self.nodes["/leds/power-green"]["gpios"] = struct.pack(">III", 1, 23, 1)
        with self.assertRaises(SystemExit):
            verifier.verify_leds(self.nodes)

    def test_wrong_controller_rejected(self):
        self.nodes["/gpio"]["compatible"] = b"unrelated-gpio\0"
        with self.assertRaises(SystemExit):
            verifier.verify_leds(self.nodes)

    def test_wrong_alias_rejected(self):
        self.nodes["/aliases"]["led-failsafe"] = b"/leds/network-amber\0"
        with self.assertRaises(SystemExit):
            verifier.verify_leds(self.nodes)

    def test_missing_channel_rejected(self):
        del self.nodes["/leds/network-amber"]
        with self.assertRaises(SystemExit):
            verifier.verify_leds(self.nodes)


if __name__ == "__main__":
    unittest.main()
