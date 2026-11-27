#!/usr/bin/env python3
"""Unit tests for the CI simulator selector using a saved simctl payload."""

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / ".github/scripts/select_simulator.py"
spec = importlib.util.spec_from_file_location("select_simulator", SCRIPT)
selector = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(selector)

PAYLOAD = {
    "devices": {
        "com.apple.CoreSimulator.SimRuntime.iOS-17-0": [
            {"name": "iPhone 15", "udid": "ios17", "isAvailable": True, "state": "Shutdown"},
        ],
        "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
            {"name": "iPhone 17 Pro", "udid": "ios26", "isAvailable": True, "state": "Shutdown"},
        ],
        "com.apple.CoreSimulator.SimRuntime.tvOS-26-0": [
            {"name": "Apple TV", "udid": "tvos", "isAvailable": True, "state": "Shutdown"},
        ],
    }
}


class SelectorTests(unittest.TestCase):
    def test_only_iphone_devices_are_candidates(self):
        found = selector.candidates(PAYLOAD)
        self.assertEqual({item[1]["udid"] for item in found}, {"ios17", "ios26"})

    def test_newest_runtime_wins_by_default(self):
        key, device, runtime, name = max(selector.candidates(PAYLOAD), key=lambda item: item[0])
        self.assertEqual(device["udid"], "ios26")
        self.assertEqual(selector.runtime_version(runtime), (26, 0))
        self.assertEqual(name, "iPhone 17 Pro")

    def test_minimum_runtime_filters_older_devices(self):
        found = [item for item in selector.candidates(PAYLOAD)
                 if selector.runtime_at_least(item[0][0], selector.parse_runtime("17.0"))]
        self.assertEqual(max(found, key=lambda item: item[0])[1]["udid"], "ios26")
        found = [item for item in selector.candidates(PAYLOAD)
                 if selector.runtime_at_least(item[0][0], selector.parse_runtime("26.0"))]
        self.assertEqual({item[1]["udid"] for item in found}, {"ios26"})

    def test_invalid_runtime_is_rejected(self):
        for value in ["", "seventeen", "17.0.1", "17.x"]:
            with self.assertRaises(SystemExit):
                selector.parse_runtime(value)


if __name__ == "__main__":
    unittest.main()
