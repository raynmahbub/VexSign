//
//  ZsignIdentityProblemTests.swift
//  VexSignTests
//
//  What a signing run says when the engine refuses a certificate pair before it starts.
//  `ZSignAsset::Init` returns -1 **without invoking the completion handler**, so the run
//  arrives as `succeeded == false` with no error text: the user saw "Signing failed" and a
//  signing log the engine never wrote to. `ZsignEngine.identityProblem` names the cause from
//  the same preconditions the engine checks, and `refusalReason(for:)` turns it into the
//  sentence a failed run reports.
//
//  These are caller-constructed profiles, not authenticated inventory — the same rule
//  `SigningRegressionFixture` states. Nothing here admits a profile for signing.
//

import XCTest
@testable import VexSign

final class ZsignIdentityProblemTests: XCTestCase {

    /// Two certificate-shaped byte strings. Identity is the bytes, so neither has to parse.
    private let leaf = Data([0x30, 0x06, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06])
    private let other = Data([0x30, 0x04, 0x0a, 0x0b, 0x0c, 0x0d])

    private var leafFingerprint: String { SigningIdentity.fingerprint(of: leaf) }
    private var profileBytes: Data { Data("an opaque profile the engine would have read".utf8) }

    private func profile(
        named certificates: [Data]?,
        team: String = SigningRegressionFixture.team
    ) throws -> Certificate {
        try SigningRegressionFixture.profile(team: team, certificates: certificates)
    }

    private func problem(
        profileBytes: Data?,
        certificateBytes: Data?,
        leaf leafFingerprint: String?,
        profile: Certificate?
    ) -> ZsignEngine.IdentityProblem? {
        ZsignEngine.identityProblem(
            provisioningProfile: profileBytes,
            certificate: certificateBytes,
            leafFingerprint: leafFingerprint,
            profile: profile
        )
    }

    // MARK: - A pair the engine can use

    func testAProfileThatNamesTheCertificateIsNotAProblem() throws {
        XCTAssertNil(try problem(
            profileBytes: profileBytes,
            certificateBytes: leaf,
            leaf: leafFingerprint,
            profile: try profile(named: [other, leaf])
        ))
    }

    // MARK: - The six refusals

    func testMissingProfileFileIsNamed() {
        XCTAssertEqual(problem(profileBytes: nil, certificateBytes: leaf, leaf: leafFingerprint, profile: nil),
                       .missingProvisioningProfile)
    }

    func testAnEmptyProfileFileCountsAsMissing() {
        XCTAssertEqual(problem(profileBytes: Data(), certificateBytes: leaf, leaf: leafFingerprint, profile: nil),
                       .missingProvisioningProfile)
    }

    func testMissingCertificateFileIsNamed() {
        XCTAssertEqual(problem(profileBytes: profileBytes, certificateBytes: nil, leaf: nil, profile: nil),
                       .missingCertificate)
    }

    func testAProfileThatCannotBeDecodedIsNamed() {
        XCTAssertEqual(problem(profileBytes: profileBytes, certificateBytes: leaf, leaf: leafFingerprint, profile: nil),
                       .profileUnreadable)
    }

    func testAProfileWithoutATeamIsNamed() throws {
        XCTAssertEqual(
            problem(profileBytes: profileBytes, certificateBytes: leaf, leaf: leafFingerprint,
                    profile: try profile(named: [leaf], team: "")),
            .missingTeamIdentifier
        )
    }

    func testACertificateThatDoesNotOpenIsNamed() throws {
        XCTAssertEqual(
            problem(profileBytes: profileBytes, certificateBytes: leaf, leaf: nil,
                    profile: try profile(named: [leaf])),
            .unreadableCertificate
        )
    }

    func testAProfileIssuedForAnotherCertificateIsNamed() throws {
        XCTAssertEqual(
            problem(profileBytes: profileBytes, certificateBytes: leaf, leaf: leafFingerprint,
                    profile: try profile(named: [other])),
            .certificateNotInProfile
        )
    }

    func testAProfileThatNamesNoCertificatesIsNamed() throws {
        XCTAssertEqual(
            problem(profileBytes: profileBytes, certificateBytes: leaf, leaf: leafFingerprint,
                    profile: try profile(named: nil)),
            .certificateNotInProfile
        )
    }

    // MARK: - The sentences

    func testEveryProblemSaysSomethingDifferentAndActionable() {
        let problems: [ZsignEngine.IdentityProblem] = [
            .missingProvisioningProfile, .missingCertificate, .profileUnreadable,
            .unreadableCertificate, .missingTeamIdentifier, .certificateNotInProfile
        ]
        let messages = problems.map(\.message)
        XCTAssertEqual(Set(messages).count, problems.count, "Two refusals share a sentence: \(messages)")
        for message in messages {
            XCTAssertGreaterThan(message.count, 40, "Too terse to act on: \(message)")
            XCTAssertFalse(message.contains("NSError"), message)
            XCTAssertFalse(message.contains("error "), message)
        }
    }

    // MARK: - What a failed run reports

    func testAdHocRunsHaveNoIdentityToBlame() {
        let request = SigningEngineRequest(appPath: "/tmp/Example.app", isAdHoc: true)
        XCTAssertNil(ZsignEngine.refusalReason(for: request))
    }

    func testARunWithoutInputsReportsTheMissingProfile() {
        let request = SigningEngineRequest(appPath: "/tmp/Example.app")
        XCTAssertEqual(
            ZsignEngine.refusalReason(for: request),
            ZsignEngine.IdentityProblem.missingProvisioningProfile.message
        )
    }
}
