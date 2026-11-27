import Foundation
import Security
import XCTest
@testable import VexSign

final class CertificateVaultTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root) // try? ok: temporary fixture cleanup
        super.tearDown()
    }

    // MARK: - Fakes

    private final class FakeKeychain: VaultKeychainStoring {
        var stored: Set<String> = []
        var failWrite = false
        var failDelete = false
        var forceState: VaultKeyState = .accessible

        func addIdentity(_ identity: SecIdentity?, id: String) throws {
            if failWrite { throw VaultError.keychainWriteFailed }
            stored.insert(id)
        }
        func identity(id: String) -> SecIdentity? { nil }
        func deleteIdentity(id: String) throws {
            if failDelete { throw VaultError.keychainUnavailable }
            stored.remove(id)
        }
        func keyState(id: String) -> VaultKeyState { forceState }
    }

    private final class StubOpener: VaultIdentityOpening {
        let metadata: VaultIdentityMetadata
        var fail: VaultError?
        var passwords: [String] = []

        init(fingerprint: String = String(repeating: "a", count: 64), team: String? = "TESTTEAM00") {
            metadata = VaultIdentityMetadata(
                fingerprint: fingerprint, commonName: "Fixture Signer", issuerCommonName: "Fixture CA",
                teamIdentifier: team, serialNumber: "0A1B", notBefore: Date(timeIntervalSince1970: 1_700_000_000),
                notAfter: Date(timeIntervalSince1970: 1_900_000_000), keyAlgorithm: "RSA", keySizeBits: 2048
            )
        }

        func open(data: Data, password: String) throws -> VaultOpenedIdentity {
            passwords.append(password)
            if let fail { throw fail }
            return VaultOpenedIdentity(identity: nil, metadata: metadata)
        }
    }

    private final class FakeScopeController: VaultSecurityScopeControlling {
        var grantsAccess = true
        private(set) var starts = 0
        private(set) var stops = 0

        func startAccessing(_ url: URL) -> Bool {
            starts += 1
            return grantsAccess
        }
        func stopAccessing(_ url: URL) { stops += 1 }
    }

    // MARK: - Persistence and redaction

    func testPersistenceRoundTripStoresNoSecretFields() throws {
        let persistence = VaultPersistence(directory: root)
        var state = VaultStoredState.empty
        state.certificates.append(certificate(id: "cert-\(String(repeating: "a", count: 64))"))
        state.profiles.append(profile(id: "profile-fixture"))
        try persistence.save(state)

        let file = root.appendingPathComponent("vault-inventory.json")
        let data = try XCTUnwrap(Data(contentsOf: file))
        let text = String(decoding: data, as: UTF8.self).lowercased()
        XCTAssertFalse(text.contains("password"))
        XCTAssertFalse(text.contains("privatekey"))
        XCTAssertFalse(text.contains("pkcs12"))
        XCTAssertFalse(text.contains("super-secret-value"))
        XCTAssertEqual(try persistence.load(), state)
    }

    func testCorruptInventoryIsNotSilentlyReplaced() async throws {
        let persistence = VaultPersistence(directory: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("vault-inventory.json")
        try Data("not json".utf8).write(to: file)
        let vault = CertificateVault(persistence: persistence)
        let snapshot = await vault.snapshot()
        XCTAssertNotNil(snapshot.loadError)
        XCTAssertTrue(snapshot.state.certificates.isEmpty)

        do {
            _ = try await vault.importCertificate(data: Data([1]), password: "x", displayName: nil)
            XCTFail("A corrupt inventory must block writes until recovered")
        } catch VaultError.saveFailed {
            // expected
        }
        XCTAssertEqual(try Data(contentsOf: file), Data("not json".utf8))
        try await vault.recoverInventory()
        let recovered = await vault.snapshot()
        XCTAssertNil(recovered.loadError)
    }

    // MARK: - Profile metadata

    func testProfileMappingSeparatesParsingFromValidity() throws {
        let fixture = try SigningRegressionFixture.profile(certificates: [SigningRegressionFixture.certificateDER])
        let profile = VaultProfileImporter.map(
            fixture, now: SigningRegressionFixture.now.addingTimeInterval(3 * 86_400)
        )
        XCTAssertEqual(profile.parseStatus, .parsed)
        XCTAssertEqual(profile.validity, .expired)
        XCTAssertEqual(profile.appIdentifier, SigningRegressionFixture.team + ".com.example.app")
        XCTAssertEqual(profile.teamIdentifier, SigningRegressionFixture.team)
        XCTAssertEqual(profile.certificateFingerprints, [])
        XCTAssertTrue(profile.capabilities.isEmpty)
        XCTAssertTrue(profile.limitations.isEmpty)
    }

    func testProfileMappingReportsMissingMetadataWithoutFabrication() throws {
        var fixture = try SigningRegressionFixture.profile()
        fixture.UUID = ""
        fixture.TeamIdentifier = []
        fixture.Platform = []
        fixture.DeveloperCertificates = nil
        fixture.Entitlements = nil
        let profile = VaultProfileImporter.map(fixture, now: SigningRegressionFixture.now)
        XCTAssertEqual(profile.parseStatus, .incomplete)
        XCTAssertNil(profile.appIdentifier)
        XCTAssertNil(profile.teamIdentifier)
        XCTAssertEqual(profile.validity, .valid)
        XCTAssertFalse(profile.limitations.isEmpty)
    }

    func testProfileParserRejectsUnsignedPlist() {
        let plist = try? SigningRegressionFixture.plist(["Name": "Not a signed profile"])
        XCTAssertNotNil(plist)
        XCTAssertThrowsError(try VaultProfileImporter.parse(plist ?? Data()))
    }

    // MARK: - Compatibility outcomes

    func testCompatibilityOutcomesAreExplicit() {
        let cert = certificate(id: "cert-\(String(repeating: "a", count: 64))")
        let baseProfile = profile(id: "profile-valid", fingerprint: cert.fingerprint)
        let target = VaultCompatibilityTarget(
            bundleIdentifier: "com.example.app",
            teamIdentifier: "TESTTEAM00",
            entitlements: ["com.apple.developer.healthkit": "true"],
            platforms: ["iOS"]
        )

        let compatible = VaultCompatibility.evaluate(certificate: cert, profile: baseProfile, target: target)
        XCTAssertEqual(compatible.outcome, .compatible)

        let wrongTeam = VaultCompatibility.evaluate(
            certificate: cert, profile: baseProfile,
            target: VaultCompatibilityTarget(
                bundleIdentifier: "com.example.app", teamIdentifier: "OTHERTEAM00",
                entitlements: target.entitlements, platforms: ["iOS"]
            )
        )
        XCTAssertEqual(wrongTeam.outcome, .incompatible)

        let wrongBundle = VaultCompatibility.evaluate(
            certificate: cert, profile: baseProfile,
            target: VaultCompatibilityTarget(
                bundleIdentifier: "com.other.app", teamIdentifier: "TESTTEAM00",
                entitlements: target.entitlements, platforms: ["iOS"]
            )
        )
        XCTAssertEqual(wrongBundle.outcome, .incompatible)

        var expiredProfile = baseProfile
        expiredProfile = with(expiredProfile) { $0.validity = .expired }
        XCTAssertEqual(VaultCompatibility.evaluate(certificate: cert, profile: expiredProfile, target: target).outcome, .expired)

        // An expired leaf certificate is reported even when the profile is current.
        let oldNotAfter = Date(timeIntervalSince1970: 1_700_000_000)
        let expiredCert = VaultCertificate(
            id: cert.id, fingerprint: cert.fingerprint, displayName: cert.displayName,
            commonName: cert.commonName, issuerCommonName: cert.issuerCommonName,
            teamIdentifier: cert.teamIdentifier, serialNumber: cert.serialNumber,
            notBefore: cert.notBefore, notAfter: oldNotAfter, keyAlgorithm: cert.keyAlgorithm,
            keySizeBits: cert.keySizeBits, importedAt: cert.importedAt, keyState: cert.keyState
        )
        XCTAssertEqual(VaultCompatibility.evaluate(certificate: expiredCert, profile: baseProfile, target: target).outcome, .expired)

        var invalidProfile = baseProfile
        invalidProfile = with(invalidProfile) { $0.parseStatus = .invalid }
        XCTAssertEqual(VaultCompatibility.evaluate(certificate: cert, profile: invalidProfile, target: target).outcome, .invalid)

        var unsupportedProfile = baseProfile
        unsupportedProfile = with(unsupportedProfile) { $0.type = "distribution"; $0.distribution = "distribution" }
        XCTAssertEqual(VaultCompatibility.evaluate(certificate: cert, profile: unsupportedProfile, target: target).outcome, .unsupported)

        XCTAssertEqual(
            VaultCompatibility.evaluate(certificate: nil, profile: baseProfile, target: target).outcome,
            .incomplete
        )
        XCTAssertEqual(
            VaultCompatibility.evaluate(
                certificate: cert, profile: baseProfile,
                target: VaultCompatibilityTarget(bundleIdentifier: "com.example.app", platforms: ["iOS"])
            ).outcome,
            .requiresAdditionalValidation
        )
    }

    func testWildcardCoversAppButNotAnotherTeam() {
        let cert = certificate(id: "cert-\(String(repeating: "b", count: 64))")
        var wildcard = profile(id: "profile-wildcard", fingerprint: cert.fingerprint)
        wildcard = with(wildcard) { $0.appIdentifier = "TESTTEAM00.com.example.*" }
        let target = VaultCompatibilityTarget(
            bundleIdentifier: "com.example.any", teamIdentifier: "TESTTEAM00", entitlements: [:], platforms: ["iOS"]
        )
        XCTAssertEqual(VaultCompatibility.evaluate(certificate: cert, profile: wildcard, target: target).outcome, .compatible)
        let other = VaultCompatibilityTarget(
            bundleIdentifier: "com.other.app", teamIdentifier: "TESTTEAM00", entitlements: [:], platforms: ["iOS"]
        )
        XCTAssertEqual(VaultCompatibility.evaluate(certificate: cert, profile: wildcard, target: other).outcome, .incompatible)
    }

    // MARK: - Document access

    func testDocumentReaderClosesScopeOnFailureAndRefusesUnscopedFiles() throws {
        let controller = FakeScopeController()
        let reader = VaultDocumentReader(controller: controller)
        let missing = root.appendingPathComponent("missing.p12")
        XCTAssertThrowsError(try reader.read(missing))
        XCTAssertEqual(controller.starts, 1)
        XCTAssertEqual(controller.stops, 1)

        controller.grantsAccess = false
        XCTAssertThrowsError(try reader.read(missing)) { error in
            XCTAssertEqual(error as? VaultError, .restrictedFile)
        }
        XCTAssertEqual(controller.starts, 2)
        XCTAssertEqual(controller.stops, 1)
    }

    func testDocumentReaderReadsBoundedFileAndClosesScope() throws {
        let controller = FakeScopeController()
        let reader = VaultDocumentReader(controller: controller, maximumBytes: 32)
        let file = root.appendingPathComponent("sample.p12")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([0x30, 0x03, 0x02, 0x01, 0x01]).write(to: file)
        XCTAssertEqual(try reader.read(file).count, 5)
        XCTAssertEqual(controller.stops, 1)
    }

    // MARK: - Vault operations

    func testConcurrentImportsCommitOneEntryAndRejectDuplicates() async throws {
        let keychain = FakeKeychain()
        let opener = StubOpener()
        let vault = CertificateVault(
            persistence: VaultPersistence(directory: root), keychain: keychain, opener: opener,
            documentReader: VaultDocumentReader(controller: FakeScopeController())
        )
        let results = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    do {
                        _ = try await vault.importCertificate(
                            data: Data([0x30]), password: "super-secret-value", displayName: nil
                        )
                        return true
                    } catch VaultError.duplicateCertificate {
                        return false
                    } catch {
                        return false
                    }
                }
            }
            var successes = 0
            for await result in group where result { successes += 1 }
            return successes
        }
        XCTAssertEqual(results, 1)
        let snapshot = await vault.snapshot()
        XCTAssertEqual(snapshot.state.certificates.count, 1)
        XCTAssertEqual(snapshot.state.certificates[0].id, VaultIdentifier.certificateID(fingerprint: opener.metadata.fingerprint))
        XCTAssertEqual(keychain.stored.count, 1)
        XCTAssertFalse(opener.passwords.contains(""))
    }

    func testWrongPasswordAndKeychainFailureDoNotCommitMetadata() async throws {
        let keychain = FakeKeychain()
        let opener = StubOpener()
        opener.fail = .wrongPassword
        let vault = CertificateVault(
            persistence: VaultPersistence(directory: root), keychain: keychain, opener: opener,
            documentReader: VaultDocumentReader(controller: FakeScopeController())
        )
        do {
            _ = try await vault.importCertificate(data: Data([1]), password: "wrong", displayName: nil)
            XCTFail("Wrong password must fail the import")
        } catch VaultError.wrongPassword { }
        XCTAssertTrue((await vault.snapshot()).state.certificates.isEmpty)

        opener.fail = nil
        keychain.failWrite = true
        do {
            _ = try await vault.importCertificate(data: Data([1]), password: "right", displayName: nil)
            XCTFail("Keychain write failure must fail the import")
        } catch VaultError.keychainWriteFailed { }
        XCTAssertTrue((await vault.snapshot()).state.certificates.isEmpty)
    }

    func testReplacementKeepsStableIdentifierAndMissingKeyIsVisible() async throws {
        let keychain = FakeKeychain()
        let opener = StubOpener()
        let vault = CertificateVault(
            persistence: VaultPersistence(directory: root), keychain: keychain, opener: opener,
            documentReader: VaultDocumentReader(controller: FakeScopeController())
        )
        let original = try await vault.importCertificate(data: Data([1]), password: "p", displayName: "Original")
        keychain.forceState = .missing
        try await vault.refreshKeyStates()
        XCTAssertEqual((await vault.snapshot()).state.certificates[0].keyState, .missing)

        opener.fail = nil
        let replaced = try await vault.replaceCertificate(
            id: original.id, data: Data([2]), password: "p2", displayName: "Renamed"
        )
        XCTAssertEqual(replaced.id, original.id)
        let state = await vault.snapshot()
        XCTAssertEqual(state.state.certificates.count, 1)
        XCTAssertEqual(state.state.certificates[0].displayName, "Renamed")

        let different = StubOpener(fingerprint: String(repeating: "c", count: 64))
        do {
            _ = try await vault.replaceCertificate(
                id: original.id, data: Data([3]), password: "p3", displayName: nil
            )
            XCTFail("Replacement must not silently change the identity")
        } catch VaultError.replacementRequiresSameIdentity { }
        XCTAssertNotNil(different)
    }

    func testDeleteRemovesKeychainIdentityAndAssociations() async throws {
        let keychain = FakeKeychain()
        let vault = CertificateVault(
            persistence: VaultPersistence(directory: root), keychain: keychain, opener: StubOpener(),
            documentReader: VaultDocumentReader(controller: FakeScopeController())
        )
        let cert = try await vault.importCertificate(data: Data([1]), password: "p", displayName: nil)
        let profile = profile(id: "profile-abc", fingerprint: cert.fingerprint)
        var state = (await vault.snapshot()).state
        state.profiles.append(profile)
        state.associations.append(VaultAssociation(
            certificateID: cert.id, profileID: profile.id, outcome: .compatible, reasons: [],
            target: VaultCompatibilityTarget(bundleIdentifier: "com.example.app")
        ))
        try write(state)

        let reloaded = CertificateVault(
            persistence: VaultPersistence(directory: root), keychain: keychain, opener: StubOpener(),
            documentReader: VaultDocumentReader(controller: FakeScopeController())
        )
        try await reloaded.deleteCertificate(id: cert.id)
        let after = await reloaded.snapshot()
        XCTAssertTrue(after.state.certificates.isEmpty)
        XCTAssertTrue(after.state.associations.isEmpty)
        XCTAssertEqual(after.state.profiles.count, 1)
        XCTAssertFalse(keychain.stored.contains(cert.id))
    }

    // MARK: - Readiness from inspection

    func testReadinessUsesRealInspectionFieldsAndExplainsUnknownEntitlements() {
        let cert = certificate(id: "cert-\(String(repeating: "d", count: 64))")
        let profile = profile(id: "profile-ready", fingerprint: cert.fingerprint)
        let inspection = inspection(bundle: "com.example.app", team: "TESTTEAM00", uuid: "PROFILE-UUID")
        let readiness = VaultReadinessAssessor.assess(
            inspection: inspection, certificates: [cert], profiles: [with(profile) { $0.uuid = "PROFILE-UUID" }]
        )
        XCTAssertEqual(readiness.state, .requiresValidation)
        XCTAssertTrue(readiness.explanation.contains { $0.contains("entitlements") })
        XCTAssertEqual(readiness.certificateID, cert.id)
    }

    func testReadinessIsUnavailableWithoutVaultItems() {
        let readiness = VaultReadinessAssessor.assess(
            inspection: inspection(bundle: "com.example.app", team: nil, uuid: nil),
            certificates: [], profiles: []
        )
        XCTAssertEqual(readiness.state, .unavailable)
    }

    // MARK: - Helpers

    private func write(_ state: VaultStoredState) throws {
        try VaultPersistence(directory: root).save(state)
    }

    private func with(_ value: VaultProfile, change: (inout VaultProfile) -> Void) -> VaultProfile {
        var copy = value
        change(&copy)
        return copy
    }

    private func certificate(id: String) -> VaultCertificate {
        VaultCertificate(
            id: id, fingerprint: String(id.dropFirst("cert-".count)), displayName: "Fixture Signer",
            commonName: "Fixture Signer", issuerCommonName: "Fixture CA", teamIdentifier: "TESTTEAM00",
            serialNumber: "0A1B", notBefore: Date(timeIntervalSince1970: 1_700_000_000),
            notAfter: Date(timeIntervalSince1970: 1_900_000_000), keyAlgorithm: "RSA", keySizeBits: 2048,
            importedAt: Date(timeIntervalSince1970: 1_800_000_000), keyState: .accessible
        )
    }

    private func profile(id: String, fingerprint: String) -> VaultProfile {
        VaultProfile(
            id: id, uuid: "PROFILE-UUID", name: "Fixture Profile", appIdentifier: "TESTTEAM00.com.example.app",
            teamIdentifier: "TESTTEAM00", teamName: "Fixture Team", applicationIdentifierPrefixes: ["TESTTEAM00"],
            platforms: ["iOS"], creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            expirationDate: Date(timeIntervalSince1970: 1_900_000_000), type: "development", distribution: "development",
            provisionsAllDevices: true, provisionedDevices: [],
            entitlements: [VaultEntitlement(key: "com.apple.developer.healthkit", value: "true")],
            capabilities: ["HealthKit"], certificateFingerprints: [fingerprint], parseStatus: .parsed,
            validity: .valid, limitations: [], importedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    private func inspection(bundle: String, team: String?, uuid: String?) -> AppBundleInspection {
        AppBundleInspection(
            schema: 1, inspectedAt: Date(timeIntervalSince1970: 1_800_000_000), bundleName: "Fixture",
            status: .valid, archive: nil,
            identity: .init(bundleIdentifier: bundle, name: "Fixture", displayName: nil, executableName: "Fixture", packageType: "APPL"),
            version: .init(shortVersion: "1.0", build: "1"),
            platform: .init(minimumOSVersion: "16.0", platformName: "iOS", platformVersion: nil, deviceFamilies: [1, 2]),
            presentation: .init(displayName: nil, iconFiles: [], iconFile: nil, supportedOrientations: []),
            integration: .init(urlSchemes: [], documentTypes: [], capabilities: []),
            nestedBundles: [],
            executable: .init(name: "Fixture", exists: true, isMachO: true, isUniversal: true,
                              architectures: ["arm64"], minimumOSVersion: "16.0", platform: "iOS",
                              isEncrypted: false, hasCodeSignature: true, diagnostics: []),
            signature: .init(status: .structuralOnly, hasSignatureDirectory: true, hasCodeResources: true,
                             executableDeclaresSignature: true, profilePresent: true, profileReadable: true,
                             profileExpired: false, profileUUID: uuid, profileTeamIdentifier: team,
                             profileApplicationIdentifier: team.map { $0 + ".com.example.app" }, profileExpiresAt: nil,
                             diagnostics: []),
            diagnostics: []
        )
    }
}
