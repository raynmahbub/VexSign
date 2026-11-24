import CoreData
import Security
import XCTest
@testable import VexSign

final class CertificateImportCryptographicIntegrationTests: XCTestCase {
    private enum SimulatedDBFailure: Error {
        case commitRejected
    }

    private func makeTempRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    @MainActor
    func testValidPKCS12AndMatchingCMSSignedProfilePassCryptographicChecksAndPersistCleanly() async throws {
        let ca = try EphemeralIdentityFixture.generateIdentity(commonName: "VexSign Test CA")
        let leaf = try EphemeralIdentityFixture.generateIdentity(
            commonName: "VexSign Ephemeral Signer",
            teamIdentifier: SigningRegressionFixture.team,
            issuer: ca
        )
        let password = "vexsign-ephemeral-pass"
        let p12Data = try EphemeralIdentityFixture.buildPKCS12(identities: [leaf], password: password)

        let now = SigningRegressionFixture.now
        let profile = try SigningRegressionFixture.profile(
            pattern: "\(SigningRegressionFixture.team).com.vexsign.crypto",
            certificates: [leaf.certificateDER]
        )
        let cmsProfileData = try EphemeralIdentityFixture.buildSignedProvisioningProfileCMS(
            profile: profile,
            signer: ca
        )

        // 1. Cryptographically verify the CMS signature and validate profile metadata.
        let verifiedProfile = try EphemeralIdentityFixture.parseAndVerifyTestCMS(
            cmsProfileData,
            trustedSigner: ca,
            now: now
        )

        // 2. Cryptographically open the real PKCS#12 via SecPKCS12Import and prove private-key possession.
        let proof = try SigningIdentityStore.inspect(p12Data, password: password)
        XCTAssertEqual(proof.keyAvailability, .accessible)
        XCTAssertEqual(proof.identity.fingerprint, SigningIdentity.fingerprint(of: leaf.certificateDER))
        XCTAssertEqual(proof.identity.commonName, "VexSign Ephemeral Signer")

        // 3. Pair validation succeeds cleanly.
        let pairError = CertificateManagementService.pairValidationError(
            keyData: p12Data,
            password: password,
            profile: verifiedProfile,
            now: now
        )
        XCTAssertNil(pairError)

        // 4. Stage files and commit to an isolated Core Data store + Keychain, then clean up.
        let handler = CertificateFileHandler(
            password: password,
            nickname: "CryptoIntegrationCert",
            isDefault: false
        )
        try await handler.stage(keyData: p12Data, provisionData: cmsProfileData)
        let stagedUUID = handler.certificateUUID
        let stagedDir = FileManager.default.certificates(stagedUUID)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: stagedDir)
            try? SecureSecretStore.delete("certificate.password.\(stagedUUID)")
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedDir.appendingPathComponent("cert.p12").path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: stagedDir.appendingPathComponent("cert.mobileprovision").path)
        )

        let storage = Storage(inMemory: true)
        let commitExp = expectation(description: "addCertificate")
        var commitError: Error?
        storage.addCertificate(
            uuid: stagedUUID,
            password: password,
            nickname: "CryptoIntegrationCert",
            expiration: verifiedProfile.ExpirationDate
        ) { error in
            commitError = error
            commitExp.fulfill()
        }
        await fulfillment(of: [commitExp], timeout: 5)
        XCTAssertNil(commitError)

        let savedCert = try XCTUnwrap(storage.getAllCertificates().first { $0.uuid == stagedUUID })
        XCTAssertEqual(savedCert.nickname, "CryptoIntegrationCert")
        let storedSecret = try SecureSecretStore.read("certificate.password.\(stagedUUID)")
        XCTAssertEqual(storedSecret.flatMap { String(data: $0, encoding: .utf8) }, password)
    }

    func testWrongPKCS12PasswordFailsWithExplicitWrongPasswordDiagnostic() throws {
        let leaf = try EphemeralIdentityFixture.generateIdentity(commonName: "WrongPass Leaf")
        let p12Data = try EphemeralIdentityFixture.buildPKCS12(identities: [leaf], password: "correct-password")
        let profile = try SigningRegressionFixture.profile(certificates: [leaf.certificateDER])

        XCTAssertThrowsError(try SigningIdentityStore.inspect(p12Data, password: "incorrect-password")) { error in
            XCTAssertEqual(error as? SigningIdentityStore.InspectionFailure, .wrongPassword)
        }

        let pairError = try XCTUnwrap(
            CertificateManagementService.pairValidationError(
                keyData: p12Data,
                password: "incorrect-password",
                profile: profile,
                now: SigningRegressionFixture.now
            )
        )
        XCTAssertEqual(CertificateImportDiagnosis.diagnostic(for: pairError).reason, .wrongPrivateKeyPassword)
    }

    func testInvalidOrCorruptedPKCS12FailsCleanly() throws {
        let corruptInputs = [
            Data(),
            Data("not-a-pkcs12-archive".utf8),
            Data([0x30, 0x04, 0x02, 0x01, 0x03, 0xff])
        ]
        let leaf = try EphemeralIdentityFixture.generateIdentity()
        let profile = try SigningRegressionFixture.profile(certificates: [leaf.certificateDER])

        for corrupt in corruptInputs {
            let error = try XCTUnwrap(
                CertificateManagementService.pairValidationError(
                    keyData: corrupt,
                    password: "pass",
                    profile: profile,
                    now: SigningRegressionFixture.now
                )
            )
            if corrupt.isEmpty {
                XCTAssertEqual(error as? CertificateImportDiagnosis, .emptyCertificateFile)
            } else {
                XCTAssertEqual(error as? SigningIdentityStore.InspectionFailure, .malformedPKCS12)
            }
        }
    }

    func testPKCS12WithoutPrivateKeyIsRejectedAsPrivateKeyMissing() throws {
        let leaf = try EphemeralIdentityFixture.generateIdentity(commonName: "CertOnly Leaf")
        let certOnlyP12 = try EphemeralIdentityFixture.buildPKCS12(
            identities: [leaf],
            password: "cert-only-pass",
            includePrivateKeys: false
        )
        let profile = try SigningRegressionFixture.profile(certificates: [leaf.certificateDER])

        XCTAssertThrowsError(try SigningIdentityStore.inspect(certOnlyP12, password: "cert-only-pass")) { error in
            XCTAssertEqual(error as? SigningIdentityStore.InspectionFailure, .privateKeyMissing)
        }

        let pairError = try XCTUnwrap(
            CertificateManagementService.pairValidationError(
                keyData: certOnlyP12,
                password: "cert-only-pass",
                profile: profile,
                now: SigningRegressionFixture.now
            )
        )
        XCTAssertEqual(CertificateImportDiagnosis.diagnostic(for: pairError).reason, .privateKeyUnavailable)
    }

    func testPKCS12WithMultipleIdentitiesIsRefusedUnambiguously() throws {
        let first = try EphemeralIdentityFixture.generateIdentity(commonName: "Identity One")
        let second = try EphemeralIdentityFixture.generateIdentity(commonName: "Identity Two")
        let multiP12 = try EphemeralIdentityFixture.buildPKCS12(
            identities: [first, second],
            password: "multi-pass"
        )
        let profile = try SigningRegressionFixture.profile(
            certificates: [first.certificateDER, second.certificateDER]
        )

        XCTAssertThrowsError(try SigningIdentityStore.inspect(multiP12, password: "multi-pass")) { error in
            XCTAssertEqual(error as? SigningIdentityStore.InspectionFailure, .multipleIdentities)
        }

        let pairError = try XCTUnwrap(
            CertificateManagementService.pairValidationError(
                keyData: multiP12,
                password: "multi-pass",
                profile: profile,
                now: SigningRegressionFixture.now
            )
        )
        XCTAssertEqual(pairError as? SigningIdentityStore.InspectionFailure, .multipleIdentities)
    }

    func testProvisioningProfileSignedByUntrustedIssuerIsRejectedByProductionGate() async throws {
        let untrustedCA = try EphemeralIdentityFixture.generateIdentity(commonName: "Untrusted CA")
        let leaf = try EphemeralIdentityFixture.generateIdentity(commonName: "Untrusted Leaf", issuer: untrustedCA)
        let password = "untrusted-pass"
        let p12Data = try EphemeralIdentityFixture.buildPKCS12(identities: [leaf], password: password)
        let profile = try SigningRegressionFixture.profile(certificates: [leaf.certificateDER])
        let untrustedCMS = try EphemeralIdentityFixture.buildSignedProvisioningProfileCMS(
            profile: profile,
            signer: untrustedCA
        )

        // Production ProvisioningProfileParser MUST reject non-Apple CMS signatures.
        XCTAssertThrowsError(try ProvisioningProfileParser.parse(untrustedCMS)) { error in
            XCTAssertEqual(error as? ProvisioningProfileParser.Failure, .untrustedCMS)
        }

        let root = try makeTempRoot("UntrustedProfileImport")
        let p12URL = root.appendingPathComponent("identity.p12")
        let provURL = root.appendingPathComponent("profile.mobileprovision")
        try p12Data.write(to: p12URL)
        try untrustedCMS.write(to: provURL)

        XCTAssertFalse(
            CertificateManagementService.validateSigningPair(for: p12URL, with: password, using: provURL)
        )
        let diagnosis = CertificateManagementService.signingPairDiagnosis(
            for: p12URL,
            with: password,
            using: provURL
        )
        XCTAssertEqual(diagnosis as? ProvisioningProfileParser.Failure, .untrustedCMS)

        // Full production importer must fail cleanly without persisting any row.
        let beforeCount = await MainActor.run { Storage.shared.getAllCertificates().count }
        let importExp = expectation(description: "untrustedImportRejected")
        var importResult: Result<String, Error>?
        CertificateManagementService.importCertificateFilesIdentified(
            p12URL: p12URL,
            provisionURL: provURL,
            p12Password: password,
            certificateName: "ShouldReject"
        ) { result in
            importResult = result
            importExp.fulfill()
        }
        await fulfillment(of: [importExp], timeout: 10)

        guard case .failure(let error) = try XCTUnwrap(importResult) else {
            return XCTFail("Expected untrusted CMS profile import to fail.")
        }
        XCTAssertEqual(error as? ProvisioningProfileParser.Failure, .untrustedCMS)
        let afterCount = await MainActor.run { Storage.shared.getAllCertificates().count }
        XCTAssertEqual(afterCount, beforeCount)
    }

    func testExpiredProvisioningProfileIsRejectedWithExpiredDiagnostic() throws {
        let ca = try EphemeralIdentityFixture.generateIdentity(commonName: "Expired Test CA")
        let leaf = try EphemeralIdentityFixture.generateIdentity(commonName: "Expired Leaf", issuer: ca)
        let password = "expired-profile-pass"
        let p12Data = try EphemeralIdentityFixture.buildPKCS12(identities: [leaf], password: password)

        let now = SigningRegressionFixture.now
        var expiredProfile = try SigningRegressionFixture.profile(certificates: [leaf.certificateDER])
        expiredProfile.ExpirationDate = now.addingTimeInterval(-3600)
        expiredProfile.CreationDate = now.addingTimeInterval(-86_400 * 7)
        let cmsData = try EphemeralIdentityFixture.buildSignedProvisioningProfileCMS(
            profile: expiredProfile,
            signer: ca
        )

        // Strict verification rejects the expired profile.
        XCTAssertThrowsError(
            try EphemeralIdentityFixture.parseAndVerifyTestCMS(cmsData, trustedSigner: ca, now: now)
        )

        // Display-mode parse authenticates the CMS so diagnosis reports profile expiry specifically.
        let displayProfile = try EphemeralIdentityFixture.parseAndVerifyTestCMS(
            cmsData,
            trustedSigner: ca,
            now: now,
            allowingExpiredForDisplay: true
        )
        let pairError = try XCTUnwrap(
            CertificateManagementService.pairValidationError(
                keyData: p12Data,
                password: password,
                profile: displayProfile,
                now: now
            )
        )
        guard case CertificateImportDiagnosis.profileExpired = pairError else {
            return XCTFail("Expected profileExpired diagnosis, got \(pairError)")
        }
        XCTAssertEqual(CertificateImportDiagnosis.diagnostic(for: pairError).reason, .provisioningProfileExpired)
    }

    func testMismatchedCertificateAndProfileIsRejectedWithMismatchDiagnostic() throws {
        let ca = try EphemeralIdentityFixture.generateIdentity(commonName: "Mismatch CA")
        let leafA = try EphemeralIdentityFixture.generateIdentity(commonName: "Leaf A", issuer: ca)
        let leafB = try EphemeralIdentityFixture.generateIdentity(commonName: "Leaf B", issuer: ca)
        let password = "mismatch-pass"
        let p12Data = try EphemeralIdentityFixture.buildPKCS12(identities: [leafA], password: password)
        let profileForB = try SigningRegressionFixture.profile(certificates: [leafB.certificateDER])
        let cmsData = try EphemeralIdentityFixture.buildSignedProvisioningProfileCMS(
            profile: profileForB,
            signer: ca
        )
        let verifiedProfile = try EphemeralIdentityFixture.parseAndVerifyTestCMS(
            cmsData,
            trustedSigner: ca,
            now: SigningRegressionFixture.now
        )

        let pairError = try XCTUnwrap(
            CertificateManagementService.pairValidationError(
                keyData: p12Data,
                password: password,
                profile: verifiedProfile,
                now: SigningRegressionFixture.now
            )
        )
        guard case CertificateImportDiagnosis.identityNotInProfile = pairError else {
            return XCTFail("Expected identityNotInProfile diagnosis, got \(pairError)")
        }
        XCTAssertEqual(CertificateImportDiagnosis.diagnostic(for: pairError).reason, .certificateProfileMismatch)
    }

    func testUnavailablePasswordOrKeychainReturnsInaccessibleWithoutLeakingState() throws {
        let leaf = try EphemeralIdentityFixture.generateIdentity(commonName: "Keychain Unavailable Leaf")
        let p12Data = try EphemeralIdentityFixture.buildPKCS12(identities: [leaf], password: "valid-pass")

        XCTAssertThrowsError(try SigningIdentityStore.inspect(p12Data, password: nil)) { error in
            XCTAssertEqual(error as? SigningIdentityStore.InspectionFailure, .inaccessible)
            XCTAssertEqual(CertificateImportDiagnosis.diagnostic(for: error).reason, .privateKeyUnavailable)
        }
    }

    @MainActor
    func testDatabaseCommitFailureRollsBackKeychainAndStagedFilesCleanly() async throws {
        let leaf = try EphemeralIdentityFixture.generateIdentity(commonName: "DB Rollback Leaf")
        let password = "db-rollback-pass"
        let p12Data = try EphemeralIdentityFixture.buildPKCS12(identities: [leaf], password: password)
        let profile = try SigningRegressionFixture.profile(certificates: [leaf.certificateDER])
        let cmsData = try EphemeralIdentityFixture.buildSignedProvisioningProfileCMS(profile: profile, signer: leaf)

        let handler = CertificateFileHandler(password: password, nickname: "WillRollback", isDefault: false)
        try await handler.stage(keyData: p12Data, provisionData: cmsData)
        let stagedUUID = handler.certificateUUID
        let stagedDir = FileManager.default.certificates(stagedUUID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedDir.path))

        let storage = Storage(inMemory: true)
        let exp = expectation(description: "dbCommitFails")
        var receivedError: Error?
        storage.addCertificate(
            uuid: stagedUUID,
            password: password,
            nickname: "WillRollback",
            expiration: profile.ExpirationDate,
            saveCertificate: { _ in throw SimulatedDBFailure.commitRejected }
        ) { error in
            receivedError = error
            exp.fulfill()
        }
        await fulfillment(of: [exp], timeout: 5)

        XCTAssertNotNil(receivedError)
        // Clean up staged files exactly as CertificateManagementService does on failure.
        handler.clean()

        XCTAssertNil(storage.getAllCertificates().first { $0.uuid == stagedUUID })
        XCTAssertNil(
            try SecureSecretStore.read("certificate.password.\(stagedUUID)"),
            "Failed DB commit must delete the Keychain password written during the transaction."
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: stagedDir.path),
            "Failed import must remove staged certificate files."
        )
    }
}
