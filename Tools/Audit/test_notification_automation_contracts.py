#!/usr/bin/env python3
"""Portable source contracts for notifications, background work and automation.

These checks run on Linux in CI's quick job. They do not replace the macOS
build, simulator tests or physical-device evidence; they pin the invariants
that are cheap to verify and easy to lose in a later edit.
"""

from __future__ import annotations

import plistlib
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def source(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8", errors="ignore")


class NotificationAutomationContracts(unittest.TestCase):
    def test_background_identifiers_and_modes_are_declared(self) -> None:
        with (ROOT / "Config/BuildSettings/iOS/Info.plist").open("rb") as handle:
            info = plistlib.load(handle)
        identifiers = set(info.get("BGTaskSchedulerPermittedIdentifiers", []))
        for expected in (
            "com.vexsign.background.maintenance",
            "com.vexsign.background.refresh",
            "com.vexsign.background.download",
            "com.vexsign.ecosystem.refresh",
        ):
            self.assertIn(expected, identifiers)
        modes = set(info.get("UIBackgroundModes", []))
        self.assertTrue({"fetch", "processing", "remote-notification", "download"} <= modes)

    def test_one_notification_service_owns_posting(self) -> None:
        service = source("VexSign/Services/Notifications/VexSignNotificationService.swift")
        self.assertIn("setNotificationCategories", source("VexSign/Services/Notifications/NotificationCenterServicing.swift"))
        self.assertIn("shouldPost", service)
        self.assertIn("vxs_setCategories", service)
        self.assertIn("history.record", service)
        # No poster invents a random identifier for a repeated event.
        for path in (
            "VexSign/System/Notifications/SelfUpdateNotifier.swift",
            "VexSign/Services/Identity/CertificateExpiryMonitor.swift",
        ):
            self.assertNotIn("UUID()", source(path), f"{path} must use a stable notification identifier")

    def test_expiry_math_uses_calendar_days(self) -> None:
        planner = source("VexSign/Services/Notifications/ExpiryReminderScheduler.swift")
        self.assertIn("calendar.date(byAdding: .day", planner)
        self.assertIn("calendar.dateComponents([.day]", planner)
        self.assertNotIn("86_400", planner)
        for milestone in ("days30", "days14", "days7", "days1", "expired"):
            self.assertIn("case " + milestone, planner)

    def test_persistent_jobs_are_bounded_and_actor_safe(self) -> None:
        engine = source("VexSign/Services/Automation/PersistentAutomationEngine.swift")
        self.assertIn("actor PersistentAutomationEngine", engine)
        self.assertIn("struct AutomationJobDefinition: Codable", engine)
        self.assertIn("running.contains(id)", engine)
        self.assertIn("Task.checkCancellation()", engine)
        self.assertIn("AutomationEnginePolicy.backoff", engine)
        self.assertIn("maximumFailures", engine)

    def test_domain_events_use_the_existing_notification_center(self) -> None:
        events = source("VexSign/Services/Automation/AutomationDomainEvents.swift")
        self.assertIn("NotificationCenter.default.post", events)
        self.assertNotIn("class EventBus", events)
        self.assertNotIn("struct EventBus", events)

    def test_tests_and_documentation_exist(self) -> None:
        for path in (
            "VexSignTests/UnitTests/Notifications/NotificationServiceTests.swift",
            "VexSignTests/UnitTests/Notifications/ExpiryReminderTests.swift",
            "VexSignTests/UnitTests/Updates/UpdateAvailabilityTests.swift",
            "VexSignTests/UnitTests/Automation/PersistentAutomationEngineTests.swift",
            "VexSignTests/UnitTests/Automation/AutomationIntegrationTests.swift",
            "Docs/Automation/notifications-automation.md",
        ):
            self.assertTrue((ROOT / path).is_file(), f"missing {path}")


if __name__ == "__main__":
    unittest.main()
