#!/usr/bin/env python3
"""Regression checks for integration boundaries found during repository verification."""

from __future__ import annotations

import json
from pathlib import Path
import plistlib
import re
import unittest


ROOT = Path(__file__).resolve().parents[3]
DOWNLOAD_IMPORT = ROOT / "VexSign/App/iOS/Infrastructure/Downloads/DownloadManager+PackageImport.swift"
DUPLICATE_REVIEW = ROOT / "VexSign/App/iOS/Infrastructure/Persistence/Repositories/ImportDuplicateReview.swift"
ANISETTE_CLIENT = ROOT / "VexSign/Packages/NativeSigning/Authentication/HTTPSAnisetteProvider.swift"
ANISETTE_MOCK = ROOT / "VexSign/Services/Cloud/Anisette/main.swift"
ANISETTE_README = ROOT / "VexSign/Services/Cloud/Anisette/README.md"
MAIN_ENTITLEMENTS = ROOT / "VexSign/Configuration/Entitlements/iOS/VexSign.entitlements"
WIDGET_ENTITLEMENTS = ROOT / "VexSign/Configuration/Entitlements/VexSignWidgetExtension/VexSignWidgetExtension.entitlements"
WATCH_ENTITLEMENTS = ROOT / "VexSign/Configuration/Entitlements/VexSignWatch/VexSignWatch.entitlements"
WATCH_WIDGET_ENTITLEMENTS = ROOT / "VexSign/Configuration/Entitlements/VexSignWatchWidgets/VexSignWatchWidgets.entitlements"
MANIFEST_SERVICE = ROOT / "VexSign/App/iOS/Infrastructure/Devices/Installation/OTA/ManifestService.swift"
APP_INSTALLER = ROOT / "VexSign/App/iOS/Infrastructure/Devices/Installation/AppInstaller.swift"
LOG_REDACTION = ROOT / "VexSign/App/iOS/Infrastructure/Diagnostics/LogRedaction.swift"
LOG_REDACTION_TESTS = ROOT / "VexSign/Tests/SecurityTests/CredentialRedaction/LogRedactionTests.swift"
BASE64_STAGING = ROOT / "VexSign/Packages/NimbleKit/Sources/NimbleExtensions/FileManager/FileManager+shortcuts.swift"
BASE64_STAGING_TESTS = ROOT / "VexSign/Tests/SecurityTests/URLValidation/DeepLinkBase64StagingTests.swift"


def _keys(block: str) -> set[str]:
    """Dictionary keys are case-insensitive at the provider boundary."""
    return {value.lower() for value in re.findall(r'"([^"]+)"\s*:', block)}


def _quoted(block: str) -> set[str]:
    return {value.lower() for value in re.findall(r'"([^"]+)"', block)}


def _plist(path: Path) -> dict:
    return plistlib.loads(path.read_bytes())


class DownloadRoutingIsolationTests(unittest.TestCase):
    def test_auto_sign_route_is_explicitly_main_actor_isolated(self) -> None:
        source = DOWNLOAD_IMPORT.read_text()
        self.assertRegex(source, r"@MainActor\s+func autoSignOrFinish\(")

    def test_duplicate_review_callback_preserves_main_actor_isolation(self) -> None:
        source = DUPLICATE_REVIEW.read_text()
        self.assertIn("let completion: @MainActor (AppInfoPresentable, Bool) -> Void", source)
        self.assertIn("completion: @MainActor @escaping (AppInfoPresentable, Bool) -> Void", source)


class DownloadReleaseMetadataContractTests(unittest.TestCase):
    """Portable wiring guards; the Swift tests execute the real decoding/file behavior in Xcode."""

    def test_selected_download_size_is_bound_to_its_url_without_integer_traps(self) -> None:
        source = (ROOT / "VexSign/Packages/AltSourceKit/Sources/Models/ASRepository.swift").read_text()
        block = source.split("public var currentDownloadSize: Int64? {", 1)[1].split("public var currentDate:", 1)[0]
        self.assertIn("let release = currentAppVersion, let releaseURL = release.downloadURL", block)
        self.assertIn("Int64(clamping: releaseSize)", block)
        self.assertIn("return releaseURL == downloadURL ? size : nil", block)

    def test_integrity_factory_consumes_the_same_release_as_the_download_url(self) -> None:
        source = (ROOT / "VexSign/App/iOS/Infrastructure/Downloads/DownloadIntegrity.swift").read_text()
        block = source.split("var downloadIntegrityExpectation:", 1)[1]
        self.assertIn("byteCount: currentDownloadSize", block)
        self.assertNotIn("size ?? versionBytes", block)
        tests = (ROOT / "VexSign/Tests/UnitTests/Application/DownloadIntegrityTests.swift").read_text()
        for name in (
            "testSelectedVersionSizeWinsOverConflictingTopLevelMetadata",
            "testAnotherURLsLegacySizeIsNeverAppliedToAReleaseWithNoSize",
            "testMatchingLegacyURLCanSupplyAMissingReleaseSize",
            "testURLFallbackAlsoUsesTheLegacyURLsSizeRatherThanAnUnboundVersionSize",
            "testLegacyAppWithoutVersionsStillEnforcesItsOwnSize",
            "testCompatibilityFallbackUsesTheOlderArchivesSize",
            "testOversizedUnsignedReleaseSizeIsRejectedWithoutIntegerConversionTrap",
        ):
            self.assertIn(name, tests)

    def test_discovery_keeps_integrity_at_both_mapping_and_download_boundaries(self) -> None:
        source = (ROOT / "VexSign/App/iOS/Infrastructure/Repositories/RepositoryDiscoveryAdapter.swift").read_text()
        self.assertIn("downloadByteCount: app.downloadIntegrityExpectation.byteCount", source)
        block = source.split("func download(_ app: DiscoveryApp)", 1)[1]
        self.assertIn("integrity: .init(byteCount: app.downloadByteCount)", block)
        self.assertLess(block.index("try security.validatePackageDownloadURL(url)"), block.index("downloads.startPackageDownload"))
        self.assertNotIn("integrity: nil", block)

    def test_persisted_discovery_size_is_optional_with_executable_swift_regressions(self) -> None:
        model = (ROOT / "VexSign/App/iOS/Domain/Services/DiscoveryIndex.swift").read_text()
        self.assertIn("var downloadByteCount: Int64? = nil", model)
        tests = (ROOT / "VexSign/Tests/UnitTests/Repositories/RepositoryDiscoveryAdapterTests.swift").read_text()
        for name in (
            "testDiscoveryForwardsTheSourcesSelectedDownloadSize",
            "testAnOldListingWithoutSizeRemainsUnverifiedAndDownloadable",
            "testInvalidURLIsStillRejectedBeforeDownloaderAdmission",
            "testSizeSurvivesCatalogPersistenceAndOlderCatalogsStillDecode",
            "testRefreshCarriesTheSameSizeIntoTheActualDownloadAdapter",
        ):
            self.assertIn(name, tests)
        self.assertIn("JSONDecoder().decode(DiscoveryApp.self", tests)
        self.assertIn("Storage(inMemory: true)", tests)


class AnisetteMockContractTests(unittest.TestCase):
    def client_keys(self) -> set[str]:
        source = ANISETTE_CLIENT.read_text()
        block = re.search(r"let required: Set<String> = \[(.*?)\]", source, re.DOTALL)
        self.assertIsNotNone(block, "client required-header schema not found")
        return _quoted(block.group(1))

    def test_mock_fields_exactly_match_the_client_schema(self) -> None:
        source = ANISETTE_MOCK.read_text()
        function = re.search(
            r"private func generateAnisetteHeaders\(\) -> \[String: String\] \{(.*?)\n    \}",
            source,
            re.DOTALL,
        )
        self.assertIsNotNone(function, "mock header generator not found")
        self.assertEqual(_keys(function.group(1)), self.client_keys())

    def test_mock_returns_the_flat_object_expected_by_the_client(self) -> None:
        source = ANISETTE_MOCK.read_text()
        self.assertIn("encoder.encode(generateAnisetteHeaders())", source)
        self.assertNotIn("AnisetteResponse", source)

    def test_readme_example_uses_the_same_flat_schema(self) -> None:
        source = ANISETTE_README.read_text()
        example = re.search(r"Example response.*?```json\s*(\{.*?\})\s*```", source, re.DOTALL)
        self.assertIsNotNone(example, "README JSON example not found")
        payload = json.loads(example.group(1))
        self.assertIsInstance(payload, dict)
        self.assertNotIn("headers", payload)
        self.assertEqual({key.lower() for key in payload}, self.client_keys())


class EntitlementContractTests(unittest.TestCase):
    def test_app_group_pairs_match(self) -> None:
        group_key = "com.apple.security.application-groups"
        self.assertEqual(_plist(MAIN_ENTITLEMENTS)[group_key], ["group.com.vexsign.app"])
        self.assertEqual(_plist(WIDGET_ENTITLEMENTS)[group_key], ["group.com.vexsign.app"])
        self.assertEqual(_plist(WATCH_ENTITLEMENTS)[group_key], ["group.com.vexsign.watch"])
        self.assertEqual(_plist(WATCH_WIDGET_ENTITLEMENTS)[group_key], ["group.com.vexsign.watch"])

    def test_associated_domains_include_a_service_prefix(self) -> None:
        for path in (MAIN_ENTITLEMENTS, WIDGET_ENTITLEMENTS, WATCH_ENTITLEMENTS, WATCH_WIDGET_ENTITLEMENTS):
            values = _plist(path).get("com.apple.developer.associated-domains", [])
            for value in values:
                self.assertRegex(value, r"^[a-z][a-z0-9-]*:.+$", f"{path}: invalid associated domain {value!r}")

    def test_unused_packet_tunnel_capability_is_not_requested(self) -> None:
        has_consumer = any(
            "import NetworkExtension" in path.read_text(errors="ignore")
            for path in ROOT.glob("**/*.swift")
            if ".git" not in path.parts
        )
        if not has_consumer:
            self.assertNotIn("com.apple.developer.networking.networkextension", _plist(MAIN_ENTITLEMENTS))


class ManifestResolutionContractTests(unittest.TestCase):
    def test_no_unverified_manifest_fallback(self) -> None:
        source = MANIFEST_SERVICE.read_text()
        self.assertNotIn("return candidates.first", source)
        self.assertIn("return await select(candidates: candidates, serves: _serves)", source)
        self.assertIn("static func select(", source)
        self.assertIn("if Task.isCancelled { return nil }", source)
        self.assertRegex(
            source,
            re.compile(r"for candidate in candidates \{.*?return nil\s*\}", re.DOTALL),
        )

    def test_installer_refuses_when_manifest_resolution_fails(self) -> None:
        source = APP_INSTALLER.read_text()
        block = source.split("if _serverMethod == 1 {", 1)[1].split("await server.start()", 1)[0]
        self.assertIn("let manifestUrl = await ManifestService.resolve(", block)
        self.assertIn("guard let manifestUrl else {", block)
        self.assertIn("_handleServerFailure(", block)
        self.assertLess(block.index("guard let manifestUrl else {"), block.index("server.manifestUrl = manifestUrl"))


class LogRedactionContractTests(unittest.TestCase):
    def test_account_pairing_and_device_key_rules_are_present(self) -> None:
        source = LOG_REDACTION.read_text()
        for key in (
            "certificateP12", "certificatePassword", "adiPb", "appleID",
            "anisetteAdiBlob", "private_key", "alt_irk", "HostPrivateKey",
            "SerialNumber", "UniqueChipID", "X-Apple-I-MD", "DeviceName",
            "UniqueDeviceID", "UDID", "remotepairing_udid",
        ):
            self.assertIn(f'"{key}"', source, f"missing redaction key {key}")
        self.assertIn("sensitiveKeyAlternation", source)
        self.assertIn("NSRegularExpression.escapedPattern(for: $0)", source)
        self.assertIn(r"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}\b", source)
        self.assertIn(r"(?i)(?<![\w-])", source)

    def test_swift_tests_exercise_the_new_rules(self) -> None:
        tests = LOG_REDACTION_TESTS.read_text()
        for name in (
            "testAccountAndPairingJSONKeysAreRedacted",
            "testAppleAccountAndAnisetteHeadersAreRedacted",
            "testDeviceIdentifiersAndNamesAreRedacted",
            "testEmailAddressesAreMaskedButDomainSurvives",
            "testBareHashesAreNotMistakenForUDIDs",
        ):
            self.assertIn(name, tests)


class DeepLinkBase64ContractTests(unittest.TestCase):
    def test_normalization_and_size_bound_are_present(self) -> None:
        source = BASE64_STAGING.read_text()
        self.assertIn(".filter { !$0.isWhitespace }", source)
        self.assertIn('.replacingOccurrences(of: "-", with: "+")', source)
        self.assertIn('.replacingOccurrences(of: "_", with: "/")', source)
        self.assertIn("data.count <= maxBytes", source)
        self.assertIn("maxBytes: Int = 16 << 20", source)
        self.assertIn("String(repeating: \"=\", count: 4 - remainder)", source)

    def test_swift_tests_exercise_every_form(self) -> None:
        tests = BASE64_STAGING_TESTS.read_text()
        for name in (
            "testStandardBase64IsStaged",
            "testMissingPaddingIsAccepted",
            "testWhitespaceIsIgnored",
            "testBase64URLAlphabetIsAccepted",
            "testOversizedPayloadIsRejected",
            "testInvalidBase64IsRejected",
        ):
            self.assertIn(name, tests)


if __name__ == "__main__":
    unittest.main()
