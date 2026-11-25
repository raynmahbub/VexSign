#!/usr/bin/env python3
"""Portable regressions for native Swift 6 compile fixes.

A source assertion is not a compiler run: the macOS build job remains the only
proof that these files type-check. These checks stop a later edit from quietly
reintroducing the exact patterns that broke the first native CI run.
"""

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


def source(relative):
    return (ROOT / relative).read_text(encoding="utf-8")


class Swift6NativeRegressions(unittest.TestCase):
    def test_background_assertion_renews_on_the_main_run_loop(self):
        text = source("VexSign/System/BackgroundTasks/BackgroundTaskManager.swift")
        self.assertIn("private var cycleTimer: Timer?", text)
        self.assertIn("RunLoop.main.add(timer, forMode: .common)", text)
        self.assertIn("cycleTimer?.invalidate()", text)
        # The previous @Sendable Task captured a weak var `self`, which Swift 6
        # rejects, and could call UIApplication off the main thread.
        self.assertNotIn("Task { [weak self]", text)
        self.assertNotIn("MainActor.run", text)

    def test_account_refresh_injected_closures_keep_their_arity(self):
        text = source("VexSign/Features/Accounts/Views/ProvisioningFlowView+AccountRefresh.swift")
        self.assertIn("importIdentity: {", text)
        self.assertNotIn("importIdentity: { expected in", text)

    def test_ui_identifier_query_uses_the_xcuitest_api(self):
        text = source("UITests/VexSignUITestCase.swift")
        self.assertIn("app.descendants(matching: .any).matching(identifier: identifier)", text)
        self.assertNotIn("app.descendants[matching:", text)

    def test_source_feed_only_size_gates_before_github_adaptation(self):
        text = source("VexSign/Services/Repository/SourceFeedLoader.swift")
        self.assertIn("guard payload.count <= RepositoryNetworkPolicy.maxFeedBytes", text)
        # Shape is checked by Self.decode after adaptation; an undecodable feed
        # becomes .invalid(payload:) so the cache can still keep the bytes.
        self.assertNotIn("if let rejection = Self.validate(payload)", text)
        self.assertNotIn("if let rejection = Self.validateShape(feedPayload)", text)

    def test_malformed_source_test_expects_a_cached_invalid_payload(self):
        text = source("Tests/UnitTests/Repositories/SourceFeedLoaderTests.swift")
        self.assertIn("func testAddSourcePathKeepsASchemaThatIsNotARepositoryAsInvalidPayload", text)
        self.assertIn("case let .invalid(kept) = result.outcome", text)
        self.assertNotIn("testAddSourcePathRefusesASchemaThatIsNotARepository", text)

    def test_accessibility_contract_covers_every_declared_identifier(self):
        text = source("Tests/UnitTests/Application/AccessibilityIdentifiersTests.swift")
        for identifier in ("A11y.Signing.paidCertificate", "A11y.Signing.trollStore",
                           "A11y.Signing.identityDeliverySeparation", "A11y.Tasks.downloadOptions",
                           "A11y.Tasks.importFromFiles", "A11y.Settings.signingMethods",
                           "A11y.Settings.installationEngine", "A11y.Library.importPackages"):
            self.assertIn(identifier, text, f"the A11y contract test no longer covers {identifier}")

    def test_combined_news_fixtures_are_decodable_repositories(self):
        text = source("Tests/UnitTests/Sources/CombinedSourceNewsTests.swift")
        self.assertIn('"apps":[{"name":"Fixture"', text)
        self.assertNotIn('"apps":[]', text)

    def test_expiry_warning_fixture_matches_the_notice_window(self):
        text = source("Tests/UnitTests/Identity/ImportedCertificateRefreshPolicyTests.swift")
        self.assertIn(".notice", text)
        self.assertIn("certificateDays: 10", text)

    def test_account_refresh_test_uses_the_no_argument_import_step(self):
        text = source("Tests/UnitTests/Accounts/ManualAccountRefreshTests.swift")
        self.assertIn("importIdentity: { [self] in", text)
        self.assertNotIn("steps.importIdentity = { _ in", text)
        self.assertNotIn("changed.certificateUUID =", text)

    def test_routing_test_initializers_follow_memberwise_order(self):
        text = source("Tests/UnitTests/Signing/SigningModeRoutingTests.swift")
        self.assertNotIn("identitySource: .appleAccount, certificate:", text)
        self.assertNotIn("identitySource: identity, certificate:", text)

    def test_diagnostic_export_is_async_through_every_boundary(self):
        exporter = source("VexSign/Services/Diagnostics/DiagnosticBundleExporter.swift")
        protocol = source("VexSign/Shared/Protocols/SubsystemBoundaries.swift")
        adapter = source("VexSign/Storage/Repositories/SubsystemAdapters.swift")
        logs = source("VexSign/Features/Dashboard/Diagnostics/LogsView.swift")
        settings = source("VexSign/Features/Settings/ViewModels/SettingsAndSecurityViewModels.swift")
        mock = source("Tests/UnitTests/Application/CleanArchitectureLayerTests.swift")

        self.assertIn("static func createDiagnosticBundle(outcomes: OperationOutcomeJournal? = nil) async -> URL?", exporter)
        self.assertIn("await (outcomes ?? OperationOutcomeJournal()).exportJSON()", exporter)
        self.assertIn("func exportDiagnosticArchiveURL() async -> URL?", protocol)
        self.assertIn("await DiagnosticBundleExporter.createDiagnosticBundle", adapter)
        self.assertIn("await DiagnosticBundleExporter.createDiagnosticBundle", logs)
        self.assertIn("await provider.exportDiagnosticArchiveURL()", settings)
        self.assertIn("func exportDiagnosticArchiveURL() async -> URL? { exportURL }", mock)


if __name__ == "__main__":
    unittest.main()
