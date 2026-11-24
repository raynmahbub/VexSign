#!/usr/bin/env python3
"""Portable guards for the Swift 6 build errors found on the baseline commit.

The macOS CI build and simulator test jobs both failed on `c67fab28`: one
first-party compiler warning was promoted to an error by the build gate, and one
file did not compile because `Result`'s `Failure` was `String`. These source
checks keep the repaired patterns in place on machines without Xcode; the real
type-check/build proof remains the macOS CI job.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
APPLICATION = ROOT / "VexSign/Features"
VEXSIGN = ROOT
ANISETTE_USE_CASE = ROOT / "VexSign/Features/Accounts/UseCases/AnisetteProviderUseCase.swift"
DEEP_LINK_ROUTER = ROOT / "VexSign/Features/Dashboard/UseCases/DeepLinkRouterUseCase.swift"


def _strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
    return re.sub(r"//.*", "", text)


def _source(path: Path) -> str:
    return _strip_comments(path.read_text(encoding="utf-8"))


class Swift6BuildRegressionTests(unittest.TestCase):
    def test_application_default_arguments_do_not_reference_isolated_singletons(self) -> None:
        # Default arguments are evaluated in a nonisolated context. A `@MainActor`
        # `.shared` there is a Swift 6 error, even though the initializer is isolated.
        isolated_default = re.compile(r"(?m)^\s*\w+\s*:\s*[^=\n]+=\s*\.shared\b")
        files = sorted(APPLICATION.rglob("**/UseCases/**/*.swift"))
        self.assertTrue(files, "Application source discovery must not become empty")
        for path in files:
            with self.subTest(file=path.relative_to(ROOT).as_posix()):
                match = isolated_default.search(_source(path))
                self.assertIsNone(
                    match,
                    f"{path.relative_to(ROOT)} evaluates an actor-isolated singleton "
                    "in a default argument; resolve it inside the isolated initializer",
                )

    def test_results_never_use_string_as_failure_type(self) -> None:
        string_failure = re.compile(r"Result\s*<[^>]*,\s*String\s*>")
        for path in sorted(VEXSIGN.rglob("*.swift")):
            with self.subTest(file=path.relative_to(ROOT).as_posix()):
                self.assertIsNone(
                    string_failure.search(_source(path)),
                    f"{path.relative_to(ROOT)} uses String as Result.Failure; "
                    "Swift 6 requires a type conforming to Error",
                )

    def test_anisette_use_case_resolves_factory_inside_the_isolated_initializer(self) -> None:
        source = _source(VEXSIGN / "VexSign/Services/Accounts/NativeAnisetteConfigurationAdapter.swift")
        self.assertIn("factory: AnisetteProviderFactory? = nil", source)
        self.assertIn(
            "self.factory = factory ?? AnisetteProviderFactory.shared", source
        )
        self.assertNotIn("factory: AnisetteProviderFactory = .shared", source)

    def test_coordinated_file_copy_failure_is_a_typed_error_with_its_message(self) -> None:
        source = _source(VEXSIGN / "VexSign/System/FileCoordination/CoordinatedIncomingFilesAdapter.swift")
        contract = _source(VEXSIGN / "VexSign/Shared/Protocols/IncomingFilesProviding.swift")
        self.assertIn("struct CoordinatedFileCopyFailure: LocalizedError", contract)
        self.assertIn("reason.localizedDescription", _source(DEEP_LINK_ROUTER))
        self.assertIn(
            "Result<Void, CoordinatedFileCopyFailure>", source
        )
        self.assertNotIn("Result<Void, String>", source)
        # Every refusal still carries the user-visible explanation, now as a
        # LocalizedError instead of a bare String.
        self.assertGreaterEqual(source.count("CoordinatedFileCopyFailure(message:"), 3)

    def test_signing_handler_keeps_managed_certificate_lookup_and_mutation_on_main_actor(self) -> None:
        source = _source(VEXSIGN / "VexSign/Services/Signing/Execution/SigningHandler.swift")
        self.assertIn("await _certificateDisplayName()", source)
        self.assertIn("try await _selectResolvedCertificate(reference: reference)", source)
        self.assertRegex(source, r"@MainActor\s+private func _certificateDisplayName\(\) -> String\?")
        self.assertRegex(source, r"@MainActor\s+private func _selectResolvedCertificate\(reference: String\) throws")
        self.assertNotIn("MainActor.run { try Storage.shared.managedCertificate", source)
        self.assertNotIn("cert.nickname", source)
        self.assertNotIn("@unchecked Sendable", source)

    def test_certificate_cards_supply_stable_identity_and_one_shared_swipe_binding(self) -> None:
        source = _source(VEXSIGN / "VexSign/Features/Certificates/Views/CertificatesView.swift")
        self.assertIn("@State private var _revealedCertificateID: String?", source)
        self.assertIn(r"id: \.element.id", source)
        self.assertIn("rowID: cert.id, revealedRowID: $_revealedCertificateID", source)
        self.assertNotIn("LibraryGridSwipeDelete(enabled: true) {", source)

    def test_hosted_swipe_tests_do_not_write_the_read_only_system_accessibility_environment(self) -> None:
        test = _source(ROOT / "Tests/UnitTests/Persistence/LibrarySwipeLayoutTests.swift")
        modifier = _source(VEXSIGN / "VexSign/Features/Library/Views/LibraryGridSwipeDelete.swift")
        self.assertNotIn(r".environment(\.accessibilityReduceMotion", test)
        self.assertIn("reduceMotionRequested: reduceMotion", test)
        self.assertIn("systemReduceMotion: reduceMotion", modifier)
        self.assertIn("animationsEnabled && !systemReduceMotion && !requestedReduceMotion", modifier)
        self.assertIn("LibraryGridSwipePolicy.allowsAnimation(", modifier)

    def test_throwing_lease_assertions_propagate_out_of_the_lifetime_scope(self) -> None:
        test = _source(ROOT / "Tests/UnitTests/Signing/SigningIdentityLeaseTests.swift")
        self.assertIn("try withExtendedLifetime(leased.leases) {", test)
        self.assertIn("try withExtendedLifetime(conflict) {", test)
        self.assertIn("XCTAssertThrowsError(try AppOperationRegistry.shared.acquire(key))", test)
        self.assertIn("XCTAssertThrowsError(try SigningIdentityStore.leasedSnapshot(storage: storage))", test)

    def test_release_settings_repository_action_uses_existing_support_port(self) -> None:
        source = _source(VEXSIGN / "VexSign/Features/Settings/Views/SettingsView.swift")
        self.assertNotIn("_githubUrl", source)
        self.assertIn("supportUseCase.openRepository()", source)
        self.assertIn("#if !NIGHTLY && !DEBUG", source)

    def test_repository_gates_run_this_regression(self) -> None:
        command = "python3 Tools/Validation/repository-validation/test_swift6_build_regressions.py"
        self.assertIn(command, (ROOT / "Makefile").read_text(encoding="utf-8"))
        self.assertIn(
            command, (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        )


if __name__ == "__main__":
    unittest.main()
