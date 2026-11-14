#!/usr/bin/env python3
"""Regression guard: declared platform capabilities must stay disclosed.

`Info.plist` asks iOS for background modes, local-network access, Bonjour service types, Face ID
and an App Transport Security exception. Each of those is a promise to the user and, for a
distributed build, to App Review. The app's disclosure page (`Documentation/QA/BETA_READINESS.md`) explains what
each one is actually used for — including the one that is a distribution risk rather than a
feature: the `audio` background mode, which VexSign uses to extend background time for installs,
downloads and signing rather than to play audio.

That explanation cost real work to write and is easy to lose. This check keeps the two in step:
a capability cannot be declared without being disclosed, and a disclosure cannot be deleted while
the capability is still declared.
"""

from __future__ import annotations

import plistlib
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
INFO = ROOT / "App/iOS/VexSign/Resources/Info.plist"
ENTITLEMENTS = ROOT / "App/iOS/VexSign/Supporting Files/VexSign.entitlements"
DISCLOSURE = ROOT / "Documentation/QA/BETA_READINESS.md"
BACKGROUND_MANAGER = ROOT / "App/iOS/VexSign/Utilities/BackgroundTaskManager.swift"
README = ROOT / "README.md"


class CapabilityDisclosureTests(unittest.TestCase):
    def setUp(self) -> None:
        self.info = plistlib.loads(INFO.read_bytes())
        self.disclosure = DISCLOSURE.read_text()

    # ---- Background modes ---------------------------------------------------------------

    def test_every_declared_background_mode_is_disclosed(self) -> None:
        for mode in self.info.get("UIBackgroundModes", []):
            self.assertIn(
                mode,
                self.disclosure,
                f"UIBackgroundModes declares {mode!r}; Documentation/QA/BETA_READINESS.md must say what it is for",
            )

    def test_the_audio_mode_is_disclosed_as_a_risk_not_a_feature(self) -> None:
        # This is the claim that matters: the app does not play audio for the user, it uses the
        # audio session as a keep-alive. Presenting it as an audio feature would be false.
        self.assertIn("audio", self.info.get("UIBackgroundModes", []))
        self.assertIn("Not audio playback", self.disclosure)
        self.assertIn("distribution risk", self.disclosure.lower())
        self.assertTrue(BACKGROUND_MANAGER.exists(), "the keep-alive implementation this describes")
        self.assertIn("AVAudioSession", BACKGROUND_MANAGER.read_text())

    # ---- Usage descriptions and network policy ------------------------------------------

    def test_privacy_usage_descriptions_are_disclosed(self) -> None:
        for key in self.info:
            if key.startswith("NS") and key.endswith("UsageDescription"):
                self.assertTrue(key in self.disclosure, f"{key} is requested from the user and must be explained")

    def test_local_networking_and_bonjour_are_disclosed(self) -> None:
        for key in ("NSLocalNetworkUsageDescription", "NSBonjourServices"):
            self.assertIn(key, self.info)
            self.assertIn(key, self.disclosure)
        for service in self.info.get("NSBonjourServices", []):
            self.assertIn(service, self.disclosure)

    def test_transport_security_is_disclosed_as_local_only(self) -> None:
        ats = self.info.get("NSAppTransportSecurity", {})
        self.assertNotIn(
            "NSAllowsArbitraryLoads",
            ats,
            "arbitrary cleartext would contradict every HTTPS claim in the docs",
        )
        self.assertTrue(ats.get("NSAllowsLocalNetworking"), "the local-network exception is the declared policy")
        self.assertIn("NSAllowsLocalNetworking", self.disclosure)

    # ---- Entitlements -------------------------------------------------------------------

    def test_declared_entitlements_are_disclosed(self) -> None:
        entitlements = plistlib.loads(ENTITLEMENTS.read_bytes())
        for key in entitlements:
            self.assertTrue(key in self.disclosure, f"entitlement {key} must be explained")
        for group in entitlements.get("com.apple.security.application-groups", []):
            self.assertIn(group, self.disclosure)

    def test_a_distribution_build_does_not_allow_debugging(self) -> None:
        entitlements = plistlib.loads(ENTITLEMENTS.read_bytes())
        self.assertIs(entitlements.get("get-task-allow"), False)

    # ---- The claims the docs must not make ----------------------------------------------

    def test_no_document_promises_background_installation(self) -> None:
        # Apple offers no supported way to install while suspended; the README must not imply one.
        for claim in ("install while suspended", "install in the background", "background installation"):
            self.assertNotIn(claim, README.read_text().lower())
        self.assertIn("No background installation", self.disclosure)

    def test_the_disclosure_states_the_device_evidence_is_missing(self) -> None:
        # A beta page that does not say this is a beta page that overclaims.
        self.assertIn("Pending", self.disclosure)
        self.assertIn("Documentation/QA/QA_DEVICE_ACCEPTANCE.md", self.disclosure)

    def test_no_version_number_is_restated_in_the_disclosure(self) -> None:
        # The version lives in the project file; a copy in prose goes stale silently.
        project = (ROOT / "VexSign.xcodeproj/project.pbxproj").read_text()
        versions = set(re.findall(r"MARKETING_VERSION = ([^;]+);", project))
        for version in versions:
            self.assertNotIn(f"version {version}", self.disclosure.lower(), "do not restate the version in docs")


if __name__ == "__main__":
    unittest.main(verbosity=2)
