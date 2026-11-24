import Foundation
import XCTest
@testable import NativeSigningLinkSmoke

/// Consent state/pin fixtures only. No online request, Keychain, real certificate
/// status evaluation, private key or signing. Native execution remains deferred.
final class NativeCertificateStatusConsentTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 10_000)
    private static func owner(_ account: String = "123") throws -> NativeSigningIdentityOwner {
        try .init(accountIdentifier: account, dsid: account, teamIdentifier: "ABCDE12345")
    }
    func testSingleUseGrantAndRedaction() async throws {
        let gate = NativeCertificateStatusConsentGate(); let owner = try Self.owner()
        let context = UUID(); let identity = UUID(); let flow = UUID(); let certificate = Data([1])
        let token = try await gate.recordExplicitConsent(owner: owner, contextID: context, identityID: identity,
            certificate: certificate, flow: flow, now: Self.now)
        XCTAssertEqual(token.description, "NativeCertificateStatusConsent(redacted)")
        let operation = try await gate.begin(token, owner: owner, contextID: context, identityID: identity,
            certificate: certificate, flow: flow, now: Self.now)
        try await gate.requireCurrent(operation, now: Self.now)
        await gate.finish(operation)
        do {
            _ = try await gate.begin(token, owner: owner, contextID: context, identityID: identity, certificate: certificate, flow: flow, now: Self.now)
            XCTFail("Consumed grant")
        } catch { XCTAssertEqual(error as? NativeCertificateStatusConsentError, .consentRequired) }
    }
    func testExactOwnerContextIdentityCertificateAndGenerationBinding() async throws {
        let owner = try Self.owner(); let context = UUID(); let identity = UUID(); let flow = UUID()
        for changed in 0..<5 {
            let gate = NativeCertificateStatusConsentGate()
            let token = try await gate.recordExplicitConsent(owner: owner, contextID: context, identityID: identity,
                certificate: Data([1]), flow: flow, now: Self.now)
            do {
                _ = try await gate.begin(token, owner: changed == 0 ? Self.owner("456") : owner,
                    contextID: changed == 1 ? UUID() : context, identityID: changed == 2 ? UUID() : identity,
                    certificate: Data([changed == 3 ? 2 : 1]), flow: changed == 4 ? UUID() : flow, now: Self.now)
                XCTFail("Exact scope required")
            } catch { XCTAssertEqual(error as? NativeCertificateStatusConsentError, .consentRequired) }
            do {
                _ = try await gate.begin(token, owner: owner, contextID: context, identityID: identity,
                    certificate: Data([1]), flow: flow, now: Self.now)
                XCTFail("Failed binding still consumes the attempted grant")
            } catch { XCTAssertEqual(error as? NativeCertificateStatusConsentError, .consentRequired) }
        }
    }
    func testInvalidLifetimeAndExpiryReject() async throws {
        let gate = NativeCertificateStatusConsentGate(); let owner = try Self.owner()
        let context = UUID(); let identity = UUID(); let flow = UUID()
        for lifetime in [0, -1, 121, Double.nan, Double.infinity] {
            do {
                _ = try await gate.recordExplicitConsent(owner: owner, contextID: context, identityID: identity,
                    certificate: Data([1]), flow: flow, now: Self.now, lifetime: lifetime)
                XCTFail("Bounded finite lifetime")
            } catch { XCTAssertEqual(error as? NativeCertificateStatusConsentError, .invalidLifetime) }
        }
        do {
            _ = try await gate.recordExplicitConsent(owner: owner, contextID: context, identityID: identity,
                certificate: Data([1]), flow: flow, now: Date(timeIntervalSince1970: Double.greatestFiniteMagnitude))
            XCTFail("Unrepresentable expiry")
        } catch { XCTAssertEqual(error as? NativeCertificateStatusConsentError, .invalidLifetime) }
        let rollback = try await gate.recordExplicitConsent(owner: owner, contextID: context, identityID: identity,
            certificate: Data([1]), flow: flow, now: Self.now)
        do {
            _ = try await gate.begin(rollback, owner: owner, contextID: context, identityID: identity,
                certificate: Data([1]), flow: flow, now: Self.now.addingTimeInterval(-1))
            XCTFail("Wall clock rollback")
        } catch { XCTAssertEqual(error as? NativeCertificateStatusConsentError, .consentRequired) }
        let token = try await gate.recordExplicitConsent(owner: owner, contextID: context, identityID: identity,
            certificate: Data([1]), flow: flow, now: Self.now, lifetime: 1)
        do {
            _ = try await gate.begin(token, owner: owner, contextID: context, identityID: identity,
                certificate: Data([1]), flow: flow, now: Self.now.addingTimeInterval(1))
            XCTFail("Expired grant")
        } catch { XCTAssertEqual(error as? NativeCertificateStatusConsentError, .consentRequired) }
    }
    func testRevokedInFlightAuthorityKeepsSlotUntilWorkerFinishes() async throws {
        let gate = NativeCertificateStatusConsentGate(); let owner = try Self.owner()
        let context = UUID(); let identity = UUID(); let flow = UUID()
        let token = try await gate.recordExplicitConsent(owner: owner, contextID: context, identityID: identity,
            certificate: Data([1]), flow: flow, now: Self.now)
        let operation = try await gate.begin(token, owner: owner, contextID: context, identityID: identity,
            certificate: Data([1]), flow: flow, now: Self.now)
        await gate.revoke()
        do { try await gate.requireCurrent(operation, now: Self.now); XCTFail("Revoked") }
        catch { XCTAssertEqual(error as? NativeCertificateStatusConsentError, .consentRequired) }
        do {
            _ = try await gate.recordExplicitConsent(owner: owner, contextID: context, identityID: identity,
                certificate: Data([1]), flow: flow, now: Self.now)
            XCTFail("OS worker not retired")
        } catch { XCTAssertEqual(error as? NativeCertificateStatusConsentError, .busy) }
        await gate.finish(operation)
        _ = try await gate.recordExplicitConsent(owner: owner, contextID: context, identityID: identity,
            certificate: Data([1]), flow: flow, now: Self.now)
    }
    func testNewestPendingConsentSupersedesOlderOne() async throws {
        let gate = NativeCertificateStatusConsentGate(); let owner = try Self.owner()
        let context = UUID(); let identity = UUID(); let flow = UUID()
        let old = try await gate.recordExplicitConsent(owner: owner, contextID: context, identityID: identity,
            certificate: Data([1]), flow: flow, now: Self.now)
        let new = try await gate.recordExplicitConsent(owner: owner, contextID: context, identityID: identity,
            certificate: Data([1]), flow: flow, now: Self.now)
        do {
            _ = try await gate.begin(old, owner: owner, contextID: context, identityID: identity,
                certificate: Data([1]), flow: flow, now: Self.now)
            XCTFail("Superseded")
        } catch { XCTAssertEqual(error as? NativeCertificateStatusConsentError, .consentRequired) }
        let operation = try await gate.begin(new, owner: owner, contextID: context, identityID: identity,
            certificate: Data([1]), flow: flow, now: Self.now)
        await gate.finish(operation)
    }
    func testStaleFinishCannotRetireAnotherOperation() async throws {
        let gate = NativeCertificateStatusConsentGate(); let owner = try Self.owner()
        let context = UUID(); let identity = UUID(); let flow = UUID()
        let first = try await gate.recordExplicitConsent(owner: owner, contextID: context, identityID: identity, certificate: Data([1]), flow: flow, now: Self.now)
        let old = try await gate.begin(first, owner: owner, contextID: context, identityID: identity, certificate: Data([1]), flow: flow, now: Self.now)
        await gate.finish(old)
        let second = try await gate.recordExplicitConsent(owner: owner, contextID: context, identityID: identity, certificate: Data([1]), flow: flow, now: Self.now)
        let current = try await gate.begin(second, owner: owner, contextID: context, identityID: identity, certificate: Data([1]), flow: flow, now: Self.now)
        await gate.finish(old)
        try await gate.requireCurrent(current, now: Self.now)
        await gate.finish(current)
    }
    func testReviewedPublicIssuerIsPinnedAndHasWWDRMarker() throws {
        let certificates = try NativeDevelopmentIssuerStore.certificates()
        XCTAssertEqual(certificates.count, 1)
        XCTAssertEqual(NativeSigningIdentityOwner.hash(certificates[0]), NativeDevelopmentIssuerStore.sha256)
        XCTAssertNoThrow(try NativeDevelopmentCertificatePurpose.requireWWDR(certificates[0]))
    }
    func testMalformedLeafCannotConsumeOnlineConsentBeforeAppleTrust() async throws {
        let gate = NativeCertificateStatusConsentGate(); let owner = try Self.owner()
        let context = UUID(); let identity = UUID(); let flow = UUID()
        let token = try await gate.recordExplicitConsent(owner: owner, contextID: context, identityID: identity,
            certificate: Data([1]), flow: flow, now: Self.now)
        do {
            _ = try await NativeDevelopmentCertificateVerifier().evaluate(owner: owner, contextID: context,
                certificateDER: Data([1]), issuerCertificates: NativeDevelopmentIssuerStore.certificates(), now: Self.now,
                identityID: identity, networkAuthorization: .init(gate: gate, consent: token, flow: flow), clock: { Self.now }, checkCurrent: {})
            XCTFail("Offline purpose/Apple trust first")
        } catch { XCTAssertEqual(error as? NativeDevelopmentCertificateError, .purposeRejected) }
        let operation = try await gate.begin(token, owner: owner, contextID: context, identityID: identity,
            certificate: Data([1]), flow: flow, now: Self.now)
        await gate.finish(operation)
    }
}
