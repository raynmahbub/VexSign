#!/usr/bin/env python3
"""Offline guard for exportable operation outcomes.

An operation outcome is only safe to export when it carries the correlation ID,
stage, status and a sanitized reason, and when the diagnostic bundle actually
writes those records. This gate reads source; it does not claim any device result.
"""

from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[3]
MODEL = ROOT / "VexSign/Shared/Models/Results/OperationOutcome.swift"
JOURNAL = ROOT / "VexSign/Services/Diagnostics/OperationOutcomeJournal.swift"
COORDINATOR = ROOT / "VexSign/Services/Accounts/ManualAccountRefreshCoordinator.swift"
EXPORTER = ROOT / "VexSign/Services/Diagnostics/DiagnosticBundleExporter.swift"
CONTAINER = ROOT / "VexSign/App/Composition/AppContainer.swift"
REFRESH_VIEW = ROOT / "VexSign/Features/Accounts/Views/ProvisioningFlowView+AccountRefresh.swift"
SETTINGS_VIEW = ROOT / "VexSign/Features/Settings/Views/SettingsView.swift"
INTENTS = ROOT / "VexSign/System/AppIntents/VexSignIntents+Actions.swift"
METHODS_VIEW = ROOT / "VexSign/Features/Signing/Views/SigningMethodsView.swift"
INSTALL_VIEW = ROOT / "VexSign/Features/Installation/Views/InstallationView.swift"
SOURCES_TABLE = ROOT / "VexSign/Features/Sources/Views/Apps/UIKit/SourceAppsTableRepresentableView.swift"
ANALYTICS_STORE = ROOT / "VexSign/Services/Diagnostics/AnalyticsStore.swift"
ANALYTICS_VIEW = ROOT / "VexSign/Features/Dashboard/Diagnostics/AnalyticsView.swift"
FEATURE_STATUS = ROOT / "VexSign/Services/Diagnostics/FeatureStatusRegistry.swift"
AUTO_SIGN_POLICY = ROOT / "VexSign/Shared/Services/AutoSignIdentityPolicy.swift"
DOWNLOAD_IMPORT = ROOT / "VexSign/Services/Download/DownloadManager+PackageImport.swift"
WEB_API = ROOT / "VexSign/Services/WebManager/WebManagerServer+API.swift"
AUTO_SIGN_TESTS = ROOT / "Tests/UnitTests/Signing/AutoSignIdentityPolicyTests.swift"
TABBAR = ROOT / "VexSign/App/Navigation/Tabs/TabbarView.swift"
PROVISIONING_VIEW = ROOT / "VexSign/Features/Accounts/Views/ProvisioningFlowView.swift"
AUTO_SIGN = ROOT / "VexSign/Services/Signing/Execution/AutoSignManager.swift"
DOWNLOAD_MANAGER = ROOT / "VexSign/Services/Download/DownloadManager.swift"
DOWNLOAD_IMPORT_RECORDER = ROOT / "VexSign/Services/Download/DownloadManager+PackageImport.swift"
EXPORTER = ROOT / "VexSign/Services/Diagnostics/DiagnosticBundleExporter.swift"
INSTALL_QUEUE = ROOT / "VexSign/Services/Installation/Installation/InstallQueueCore.swift"


class OperationOutcomePolicyTests(unittest.TestCase):
    def test_record_carries_the_required_fields(self):
        source = MODEL.read_text(encoding="utf-8")
        for field in ("correlationID", "stage", "status", "reason", "startedAt", "finishedAt"):
            self.assertIn(field, source)
        for status in ("succeeded", "unconfirmed", "failed", "cancelled"):
            self.assertIn(f"case {status}", source)

    def test_reasons_are_sanitised_at_the_model_and_actor_boundaries(self):
        self.assertIn("enum OperationOutcomeSanitizer", MODEL.read_text(encoding="utf-8"))
        for path in (JOURNAL, COORDINATOR):
            self.assertIn("OperationOutcomeSanitizer.reason", path.read_text(encoding="utf-8"))

    def test_journal_is_bounded_and_survives_a_new_instance(self):
        source = JOURNAL.read_text(encoding="utf-8")
        self.assertIn("actor OperationOutcomeJournal", source)
        self.assertIn("static let limit", source)
        self.assertIn("init(url: URL? = nil", source)
        self.assertIn("func exportJSON()", source)
        self.assertNotIn("static let shared", source)

    def test_every_stage_has_an_injected_recorder(self):
        # A source-text gate cannot prove a stage ran, but it can stop a recorder from
        # being removed or silently defaulting to a no-op again.
        self.assertIn("typealias OperationOutcomeRecording", MODEL.read_text(encoding="utf-8"))
        self.assertNotIn("= { _ in }", (ROOT / "VexSign/Services/Accounts/AccountRefreshPipeline.swift").read_text(encoding="utf-8"))
        self.assertNotIn("= { _ in }", COORDINATOR.read_text(encoding="utf-8"))
        self.assertIn("outcomeRecorder: OperationOutcomeRecording?", AUTO_SIGN.read_text(encoding="utf-8"))
        self.assertIn("outcomeRecorder: OperationOutcomeRecording?", DOWNLOAD_MANAGER.read_text(encoding="utf-8"))
        self.assertIn("recordImportOutcome(", DOWNLOAD_IMPORT_RECORDER.read_text(encoding="utf-8"))
        install = INSTALL_QUEUE.read_text(encoding="utf-8")
        self.assertIn("outcomeRecorder: OperationOutcomeRecording?", install)
        self.assertIn("_recordInstallOutcome(status: .succeeded", install)
        self.assertIn("_recordInstallOutcome(status: .cancelled", install)
        self.assertIn("outcomes: OperationOutcomeJournal? = nil", EXPORTER.read_text(encoding="utf-8"))
        container = (ROOT / "VexSign/App/Composition/AppContainer.swift").read_text(encoding="utf-8")
        self.assertIn("AutoSignManager.shared.outcomeRecorder = recordOutcome", container)
        self.assertIn("DownloadManager.shared.outcomeRecorder = recordOutcome", container)
        self.assertIn("InstallQueue.shared.outcomeRecorder = recordOutcome", container)

    def test_import_action_titles_follow_the_saved_signing_state(self):
        # Feather-family parity: the Get button must promise exactly what auto sign will do.
        manager = AUTO_SIGN.read_text(encoding="utf-8")
        button = (ROOT / "VexSign/Features/Sources/Views/Apps/DownloadButtonView.swift").read_text(encoding="utf-8")
        self.assertIn("enum Action: String, CaseIterable", manager)
        for title in ("Add to Library", "Sign", "Sign & Install"):
            self.assertIn(f'.localized("{title}")', manager)
        self.assertIn("AutoSignManager.Action.current", button)
        self.assertIn("action.systemImage", button)
        self.assertIn("action.title", button)

    def test_unattended_signing_obeys_the_selected_identity(self):
        policy = AUTO_SIGN_POLICY.read_text(encoding="utf-8")
        self.assertIn("case requireAttendedReview", policy)
        # The reviewed Apple Account exception is the only case that may fall through
        # to `.allow`. A guard with an `else { return .allow }` inverts that branch and
        # passed this gate before: assert the decision shape, not just the token names.
        self.assertIn(
            "if identity == .appleAccount, !attendedAppleAccountRefresh {\n"
            "            return .requireAttendedReview\n"
            "        }\n"
            "        return .allow",
            policy,
        )
        for path in (DOWNLOAD_IMPORT, WEB_API, INTENTS):
            self.assertIn("AutoSignIdentityPolicy.decide(", path.read_text(encoding="utf-8"))
        self.assertTrue(AUTO_SIGN_TESTS.exists())
        self.assertIn("requestProvisioningReview(for: app)", DOWNLOAD_IMPORT.read_text(encoding="utf-8"))
        self.assertIn("requestProvisioningReview(for: target)", INTENTS.read_text(encoding="utf-8"))
        self.assertIn("sheet(item: $tabSelection.provisioningReviewRequest)", TABBAR.read_text(encoding="utf-8"))
        self.assertIn("initialAppUUID: String?", PROVISIONING_VIEW.read_text(encoding="utf-8"))

    def test_ryuk_sign_parity_caveats_are_explicit(self):
        sources = SOURCES_TABLE.read_text(encoding="utf-8")
        self.assertIn("CombinedSourceNews.items(from: sources)", sources)
        self.assertNotIn("sources.first?.news", sources)
        self.assertIn("LocalAnalyticsPreferences.isEnabled", ANALYTICS_STORE.read_text(encoding="utf-8"))
        analytics = ANALYTICS_VIEW.read_text(encoding="utf-8")
        self.assertIn("Record local activity counts", analytics)
        self.assertIn("@AppStorage(LocalAnalyticsPreferences.enabledKey)", analytics)
        registry = FEATURE_STATUS.read_text(encoding="utf-8")
        for feature in ("combined-source-news", "local-analytics-opt-in", "paired-installation", "computer-free-bootstrap"):
            self.assertIn(f'id: "{feature}"', registry)

    def test_identity_and_delivery_selections_are_independent(self):
        methods = METHODS_VIEW.read_text(encoding="utf-8")
        self.assertIn("selectIdentity(.appleAccount)", methods)
        self.assertIn("selectIdentity(.importedCertificate)", methods)
        self.assertNotIn("selectPreference(.containerized)", methods)
        self.assertNotIn("selectPreference(.directPaid)", methods)
        install = INSTALL_VIEW.read_text(encoding="utf-8")
        self.assertIn("selectIdentity($0)", install)
        self.assertIn("selectMethod($0)", install)
        self.assertIn("Device readiness", install)

    def test_attended_refresh_is_reachable_and_records_outcomes(self):
        view = REFRESH_VIEW.read_text(encoding="utf-8")
        self.assertIn("AccountRefreshPipeline(", view)
        self.assertIn("await outcomes.record(outcome)", view)
        self.assertIn("AccountRefreshBridging.handoff(from: handoff)", view)
        self.assertIn("ProvisioningFlowView(refreshReview: true)", SETTINGS_VIEW.read_text(encoding="utf-8"))
        intent = INTENTS.read_text(encoding="utf-8")
        self.assertIn("accountRefreshRequested = true", intent)
        self.assertNotIn("AccountRefreshPipeline", intent)

    def test_diagnostic_bundle_exports_operations(self):
        exporter = EXPORTER.read_text(encoding="utf-8")
        self.assertIn('appendingPathComponent("operations.json")', exporter)
        self.assertIn("(outcomes ?? OperationOutcomeJournal()).exportJSON()", exporter)
        self.assertIn("let operationOutcomes = OperationOutcomeJournal()", CONTAINER.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
