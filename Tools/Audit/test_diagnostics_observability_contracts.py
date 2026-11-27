#!/usr/bin/env python3
"""Portable wiring contracts for diagnostics, crash reporting and performance.

This suite does not compile Swift (no Xcode toolchain is available in the
portable CI job). It asserts that the real implementations remain wired into the
app: a structured event model and bounded journal, privacy-aware OSLog
interpolation, task/operation correlation, MetricKit payload handling with
call stacks excluded, signpost/ContinuousClock intervals, safe network context,
a live Troubleshooting Center, filtered/sanitized export, and real recovery
copy. Pure policy behaviour is additionally covered by VexSignTests.

    python3 Tools/Audit/test_diagnostics_observability_contracts.py
"""

from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


def source(path):
    return (ROOT / path).read_text(encoding="utf-8")


class DiagnosticsObservabilityContracts(unittest.TestCase):
    def test_structured_event_model_has_stable_codes_and_bounded_fields(self):
        model = source("VexSign/Services/Diagnostics/DiagnosticEvent.swift")
        for token in (
            "enum DiagnosticSeverity", "enum DiagnosticCategory",
            "enum DiagnosticEventCode", "var eventID", "var code",
            "var operationID", "var timestamp", "var userMessage",
            "var developerDetail", "var recoverySuggestion", "var metadata",
            "enum DiagnosticEventSanitizer", "maximumTextLength",
            "maximumMetadataEntries", "LogRedaction.redact",
        ):
            self.assertIn(token, model, token)
        for code in (
            "VEX-SIGN-001", "VEX-IPA-001", "VEX-DOWN-001", "VEX-NET-001",
            "VEX-DEV-001", "VEX-INS-001", "VEX-BG-001", "VEX-AUTO-001",
            "VEX-SEC-001", "VEX-MK-001", "VEX-MK-004",
        ):
            self.assertIn(code, model, code)

    def test_vendored_error_hierarchy_is_reused_for_recovery(self):
        model = source("VexSign/Services/Diagnostics/DiagnosticEvent.swift")
        self.assertIn("enum DiagnosticRecoveryGuide", model)
        self.assertIn("suggestion(for code: VexSignError.Code)", model)
        guide = model[model.index("enum DiagnosticRecoveryGuide"):]
        for real_feature in ("Certificates", "Task Center", "Devices", "Downloads",
                             "Repositories", "Backup & Restore", "Troubleshooting Center"):
            self.assertIn(real_feature, guide, real_feature)

    def test_journal_bounds_rotates_migrates_and_quarantines(self):
        journal = source("VexSign/Services/Diagnostics/DiagnosticEventJournal.swift")
        for token in (
            "static let limit = 250", "static let maximumFileBytes",
            "schemaVersion: Int", "package.schemaVersion == 1",
            "unversioned", "corrupt.json",
            ".atomic, .completeFileProtectionUntilFirstUserAuthentication",
            "func exportJSON(filter: DiagnosticExportFilter? = nil)",
            "func matching(_ filter: DiagnosticExportFilter)",
        ):
            self.assertIn(token, journal, token)

    def test_dynamic_oslog_text_is_private_and_codes_are_public(self):
        recorder = source("VexSign/Services/Diagnostics/DiagnosticRecorder.swift")
        self.assertIn("\\(event.code, privacy: .public)", recorder)
        self.assertIn("\\(event.userMessage, privacy: .private)", recorder)
        self.assertIn("\\(detail, privacy: .private)", recorder)
        self.assertIn("ErrorBoundary.classify(error)", recorder)
        self.assertIn("DiagnosticRecoveryGuide.suggestion(for: classified.code)", recorder)
        error = source("VexSign/Shared/Errors/VexSignError.swift")
        self.assertIn("LogRedaction.redact(message), privacy: .private", error)
        self.assertNotIn("context, privacy: .public", error)

    def test_composition_root_wires_outcomes_tasks_security_and_transfers(self):
        container = source("VexSign/App/Composition/AppContainer.swift")
        self.assertIn("DiagnosticEventJournal()", container)
        self.assertIn("DiagnosticRecorder { event in", container)
        self.assertIn(".fromOutcome(", container)
        self.assertIn("NetworkTransferAdapter(securityPolicy: security, diagnostics: diagnosticRecorder)", container)
        self.assertIn("recorder: diagnosticRecorder", container)
        self.assertIn("func makeTroubleshootingViewModel()", container)
        center = source("VexSign/Services/Tasks/UnifiedTaskCenter.swift")
        self.assertIn("DiagnosticEventCode.taskFailed", center)
        self.assertIn("DiagnosticEventCode.taskCancelled", center)
        self.assertIn("operationID: taskID", center)
        automation = source("VexSign/Services/Automation/PersistentAutomationEngine.swift")
        self.assertIn("DiagnosticEventCode.automationFailure", automation)
        self.assertIn("func setDiagnostics(_ recorder: DiagnosticRecorder)", automation)
        devices = source("VexSign/Services/Devices/DeviceRegistryService.swift")
        self.assertIn("DiagnosticEventCode.deviceFailure", devices)
        self.assertIn("metadata: [\"failureCode\": code]", devices)
        security = source("VexSign/Services/Diagnostics/SecurityDiagnosticsService.swift")
        self.assertIn("recorder: DiagnosticRecorder? = nil", security)
        self.assertIn("guard reportedFailures.insert(row.id).inserted", security)

    def test_metrickit_handles_supported_diagnostics_without_raw_payloads(self):
        service = source("VexSign/Services/Diagnostics/MetricKitDiagnosticsService.swift")
        for token in (
            "import MetricKit", "MXMetricManagerSubscriber", "MXMetricManager.shared.add(self)",
            "payload.crashDiagnostics", "diagnostic.signal", "diagnostic.exceptionType",
            "payload.hangDiagnostics",
            "payload.cpuExceptionDiagnostics", "payload.appLaunchDiagnostics",
            "payload.diskWriteExceptionDiagnostics", "hangDuration",
            "totalCPUTime", "launchDuration",
        ):
            self.assertIn(token, service, token)
        for forbidden in ("jsonRepresentation", "callStackTree", "dictionaryRepresentation"):
            self.assertNotIn(forbidden, service, forbidden)
        self.assertIn("Delivery is controlled by iOS", service)
        app = source("VexSign/App/AppDelegate.swift")
        self.assertIn("metricKitDiagnostics.start()", app)
        self.assertIn("DiagnosticEventCode.appLaunched", app)

    def test_real_performance_instrumentation_uses_signposts_and_clock(self):
        stopwatch = source("VexSign/Services/Diagnostics/DiagnosticStopwatch.swift")
        self.assertIn("import OSLog", stopwatch)
        self.assertIn("OSSignposter(logger: logger)", stopwatch)
        self.assertIn("beginInterval(name, id: signpostID)", stopwatch)
        self.assertIn("endInterval(name, interval)", stopwatch)
        self.assertIn("ContinuousClock.now", stopwatch)
        self.assertIn("startedAt.duration(to: ContinuousClock.now)", stopwatch)
        adapter = source("VexSign/Networking/API/NetworkTransferAdapter.swift")
        self.assertIn("DiagnosticStopwatch(\"packageDownload\"", adapter)
        self.assertIn("DiagnosticStopwatch(\"firmwareDownload\"", adapter)
        self.assertIn("url.logSafeDescription", adapter)
        for forbidden in ("absoluteString", "URLSession.shared", "httpShouldUsePipelining"):
            self.assertNotIn(forbidden, adapter, forbidden)

    def test_background_failures_are_recorded(self):
        background = source("VexSign/App/AppDelegate+BackgroundTasks.swift")
        self.assertIn("_recordBackgroundFailure(", background)
        self.assertIn("DiagnosticEventCode.backgroundFailure", background)
        self.assertIn("DiagnosticRecorder.fileRecorder.record", background)
        self.assertGreaterEqual(background.count("_recordBackgroundFailure("), 7)

    def test_troubleshooting_center_uses_real_events_filters_and_task_titles(self):
        view = source("VexSign/Features/Dashboard/Diagnostics/TroubleshootingCenterView.swift")
        self.assertIn("TroubleshootingCenterContent", view)
        self.assertIn("ForEach(viewModel.filteredEvents)", view)
        self.assertIn("exportFilteredBundle()", view)
        self.assertIn("MetricKit reports arrive under iOS control", view)
        vm = source("VexSign/Features/Dashboard/Diagnostics/TroubleshootingCenterViewModel.swift")
        self.assertIn("await journal.all()", vm)
        self.assertIn("DiagnosticExportFilter(", vm)
        self.assertIn("taskCorrelation.correlatedTitles()", vm)
        self.assertNotIn("UnifiedTaskCenter.shared", vm)
        correlation = source("VexSign/Services/Tasks/TaskCorrelationService.swift")
        self.assertIn("UnifiedTaskCenter.shared", correlation)
        self.assertIn("signingTaskID", correlation)
        self.assertIn("importTaskID", correlation)
        center = source("VexSign/Features/Dashboard/About/DiagnosticsCenterView.swift")
        self.assertIn("TroubleshootingCenterView()", center)

    def test_export_is_sanitized_filtered_and_bounded(self):
        exporter = source("VexSign/Services/Diagnostics/DiagnosticBundleExporter.swift")
        self.assertIn("filter: DiagnosticExportFilter? = nil", exporter)
        self.assertIn("if filter == nil", exporter)
        self.assertIn("diagnostic-events.json", exporter)
        self.assertIn("exportJSON(filter: filter)", exporter)
        self.assertIn("filter.json", exporter)
        self.assertIn("LogRedaction.redact(text)", exporter)
        adapter = source("VexSign/Storage/Repositories/SubsystemAdapters.swift")
        self.assertIn("events: diagnosticEvents", adapter)

    def test_no_third_party_crash_or_network_debugger_dependency(self):
        project = source("VexSign.xcodeproj/project.pbxproj")
        for forbidden in ("Sentry", "Pulse", "Netfox", "OSLogViewer"):
            self.assertNotIn(forbidden, project, forbidden)
        self.assertFalse((ROOT / "Package.swift").exists())
        for path in (ROOT / "VexSign").rglob("*.swift"):
            text = path.read_text(encoding="utf-8", errors="replace")
            self.assertNotIn("import Sentry", text, str(path))
            self.assertNotIn("import Netfox", text, str(path))
            self.assertNotIn("import Pulse", text, str(path))

    def test_swift_tests_cover_the_pure_policies(self):
        event_tests = source("VexSignTests/UnitTests/Diagnostics/DiagnosticEventTests.swift")
        journal_tests = source("VexSignTests/UnitTests/Diagnostics/DiagnosticEventJournalTests.swift")
        filter_tests = source("VexSignTests/UnitTests/Diagnostics/DiagnosticFilterAndTimingTests.swift")
        self.assertIn("testEventIsSanitizedBeforeItCanBeStored", event_tests)
        self.assertIn("testStableDiagnosticCodesAreUnique", event_tests)
        self.assertIn("testJournalBoundsRetention", journal_tests)
        self.assertIn("testCorruptHistoryIsQuarantinedNotTrusted", journal_tests)
        self.assertIn("testLegacyUnversionedArrayIsMigrated", journal_tests)
        self.assertIn("testFilteredExportExcludesOtherCategories", journal_tests)
        self.assertIn("testStopwatchProducesObservedDurationAndSafeEvent", filter_tests)

    def test_portable_gate_is_registered_and_documented(self):
        makefile = source("Makefile")
        self.assertIn("python3 Tools/Audit/test_diagnostics_observability_contracts.py", makefile)
        ci = source(".github/workflows/ci.yml")
        self.assertIn("python3 Tools/Audit/test_diagnostics_observability_contracts.py", ci)
        report = source("Docs/Diagnostics/diagnostics-observability-2026-11.md")
        self.assertIn("MetricKit", report)
        self.assertIn("physical device", report)
        self.assertIn("Sentry Cocoa", report)
        self.assertIn("OSLogViewer", report)


if __name__ == "__main__":
    unittest.main(verbosity=2)
