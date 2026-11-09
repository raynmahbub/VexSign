#!/usr/bin/env python3
"""Regression guard: cosmetic blur must not depend on private Core Animation APIs."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "NimbleKit/Sources/NimbleViews/Views/NBVariableBlurView.swift"


class PublicBlurPolicyTests(unittest.TestCase):
    def test_blur_uses_supported_effect_and_has_a_nonfatal_mask_fallback(self) -> None:
        source = SOURCE.read_text()
        self.assertIn("UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))", source)
        self.assertIn("guard let gradientMask else", source)
        self.assertIn("effectView.mask = nil", source)
        self.assertIn("func updateUIView", source)

    def test_blur_does_not_resolve_private_classes_filters_or_selectors(self) -> None:
        source = SOURCE.read_text()
        forbidden = (
            "NSClassFromString",
            "filterWithTypeSelector",
            "takeUnretainedValue",
            "layer.filters",
            "setValue(",
            "forKey:",
        )
        for token in forbidden:
            with self.subTest(token=token):
                self.assertNotIn(token, source)


if __name__ == "__main__":
    unittest.main()
