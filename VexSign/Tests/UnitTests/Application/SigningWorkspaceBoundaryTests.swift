import Foundation
import XCTest
@testable import VexSign

@MainActor
final class SigningWorkspaceBoundaryTests: XCTestCase {
    private enum Failure: Error { case refused }

    private final class Provider: LibrarySigningProviding {
        typealias Icon = String
        var requests: [LibrarySigningRequest] = []
        var callbacks: [@MainActor (LibrarySigningEvent) -> Void] = []
        var cancellations: [String] = []
        var captures: [LibrarySigningRequest] = []
        var finishes: [(LibrarySigningRequest, LibraryAppReference, Bool)] = []
        var failCapture = false
        var failFinish = false

        func startSigning(_ request: LibrarySigningRequest, icon: String?, onEvent: @escaping @MainActor (LibrarySigningEvent) -> Void) {
            requests.append(request); callbacks.append(onEvent)
        }
        func cancelSigning(id: String) { cancellations.append(id) }
        func captureSuccessfulRun(_ request: LibrarySigningRequest) throws {
            captures.append(request)
            if failCapture { throw Failure.refused }
        }
        func finishSuccessfulRun(_ request: LibrarySigningRequest, output: LibraryAppReference, deletesSource: Bool) throws {
            finishes.append((request, output, deletesSource))
            if failFinish { throw Failure.refused }
        }
        func bundleContents(app: LibraryAppReference) throws -> SigningBundleContents { throw Failure.refused }
        func applicationExtensionNames(app: LibraryAppReference) throws -> [String] { [] }
        func embeddedEntitlements(app: LibraryAppReference) throws -> [String: Any]? { nil }
        func preflight(_ request: LibrarySigningRequest) throws -> PreflightResult { PreflightResult(issues: []) }
        func compatibilityTarget(app: LibraryAppReference, options: Options) throws -> ProfileCompatibility.Target {
            ProfileCompatibility.Target(bundleIdentifier: "com.example.fixture")
        }
        func compatibilityVerdict(profile: Certificate, target: ProfileCompatibility.Target) -> ProfileCompatibility.Verdict {
            fatalError("This event-contract fixture must not resolve provisioning")
        }
        func inspectExecutables(_ request: LibrarySigningRequest) async throws -> SigningReviewEvidence { throw Failure.refused }
        func savedProfile(bundleIdentifier: String?) -> SigningProfile? { nil }
        func savedCertificate(profile: SigningProfile?) -> CertificateRecord? { nil }
        func resolveOptions(_ options: Options, for app: LibraryAppReference) throws -> Options { options }
        func autoInjectSpecs(for app: LibraryAppReference) throws -> [TweakInjectionSpec] { [] }
        func repeatSigning(_ app: LibraryAppReference, overridingBlockingIssues: Bool) async throws { throw Failure.refused }
        func certificateMatchSummary(app: LibraryAppReference, certificateID: String) throws -> String? { nil }
    }

    private func label(_ event: LibrarySigningEvent) -> String {
        switch event {
        case .stage(let stage): stage.rawValue
        case .signatureVerified: "verified"
        case .compatibilityRemoved: "compatibility"
        case .finished(.success): "artifact"
        case .finished(.failure): "failure"
        }
    }

    private func certificateWithEntitlements(_ entitlements: [String: Any]?, hasProfile: Bool = true) -> CertificateRecord {
        let profile = Certificate(AppIDName: "Fixture", CreationDate: Date(), Platform: ["iOS"],
            Entitlements: entitlements?.mapValues { AnyCodable($0) }, ExpirationDate: Date().addingTimeInterval(3600),
            Name: "Fixture", TeamIdentifier: ["ABCDE12345"], TeamName: "Fixture", TimeToLive: 1,
            UUID: "fixture-profile", Version: 1)
        return CertificateRecord(id: "fixture-certificate", uuid: nil, nickname: nil, date: nil,
            expiration: nil, isDefault: false, ppQCheck: false, revoked: false,
            profile: hasProfile ? profile : nil, additionalProfilePatterns: [])
    }

    func testEntitlementReferenceRequiresTheSelectedProfileSnapshot() {
        XCTAssertNil(PlistDiff.grantedEntitlements(for: nil))
        XCTAssertNil(PlistDiff.grantedEntitlements(for: certificateWithEntitlements([:], hasProfile: false)))
        XCTAssertNil(PlistDiff.grantedEntitlements(for: certificateWithEntitlements(nil)))
        XCTAssertEqual(PlistDiff.flaggedCount(in: ["unknown": true], against: nil), 0)
    }

    func testEntitlementSnapshotUnwrapsValuesWithoutRefetchingCertificateRows() throws {
        let values: [String: Any] = ["application-identifier": "ABCDE12345.com.example.fixture",
            "get-task-allow": false, "groups": ["group.fixture"], "nested": ["enabled": true]]
        let granted = try XCTUnwrap(PlistDiff.grantedEntitlements(for: certificateWithEntitlements(values)))
        XCTAssertTrue(NSDictionary(dictionary: granted).isEqual(NSDictionary(dictionary: values)))
        XCTAssertEqual(PlistDiff.flaggedCount(in: values, against: granted), 0)
        XCTAssertEqual(PlistDiff.flaggedCount(in: ["get-task-allow": true, "ungranted": true], against: granted), 2)
    }

    func testAnEmptyProfileReferenceIsNotTreatedAsNoCertificate() throws {
        let granted = try XCTUnwrap(PlistDiff.grantedEntitlements(for: certificateWithEntitlements([:])))
        XCTAssertTrue(granted.isEmpty)
        XCTAssertEqual(PlistDiff.flaggedCount(in: ["ungranted": true], against: granted), 1)
    }

    func testDuplicateAdmissionDoesNotRetireTheFirstInvocation() throws {
        let provider = Provider()
        let useCase = SigningWorkspaceUseCase(provider: provider)
        let request = try FeatureBoundaryFixtures.signing()
        var first: [String] = [], duplicate: [String] = []
        useCase.start(request, icon: nil) { first.append(self.label($0)) }
        useCase.start(request, icon: nil) { duplicate.append(self.label($0)) }
        provider.callbacks[0](.stage(.copying))
        provider.callbacks[0](.finished(.failure(Failure.refused)))
        provider.callbacks[0](.signatureVerified)
        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertEqual(first, ["copying", "failure"])
        XCTAssertEqual(duplicate, ["failure"])
    }

    func testFinishingAnArtifactNeverInventsVerificationAndDropsLateEvents() throws {
        let provider = Provider()
        let useCase = SigningWorkspaceUseCase(provider: provider)
        var events: [String] = []
        useCase.start(try FeatureBoundaryFixtures.signing(), icon: nil) { events.append(self.label($0)) }
        provider.callbacks[0](.stage(.registering))
        provider.callbacks[0](.finished(.success(FeatureBoundaryFixtures.app(signed: true))))
        provider.callbacks[0](.signatureVerified)
        provider.callbacks[0](.finished(.failure(Failure.refused)))
        XCTAssertEqual(events, ["registering", "artifact"])
    }

    func testActualVerificationEventKeepsItsOrder() throws {
        let provider = Provider()
        let useCase = SigningWorkspaceUseCase(provider: provider)
        var events: [String] = []
        useCase.start(try FeatureBoundaryFixtures.signing(), icon: nil) { events.append(self.label($0)) }
        provider.callbacks[0](.stage(.verifying))
        provider.callbacks[0](.signatureVerified)
        provider.callbacks[0](.finished(.success(FeatureBoundaryFixtures.app(signed: true))))
        XCTAssertEqual(events, ["verifying", "verified", "artifact"])
    }

    func testCancelledRunKeepsAdmissionUntilTheOriginalOwnerTerminates() throws {
        let provider = Provider()
        let useCase = SigningWorkspaceUseCase(provider: provider)
        let request = try FeatureBoundaryFixtures.signing()
        var events: [String] = []
        useCase.start(request, icon: nil) { events.append(self.label($0)) }
        useCase.cancel(id: request.id)
        useCase.cancel(id: "unknown")
        useCase.start(request, icon: nil) { _ in }
        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertEqual(provider.cancellations, [request.id])
        XCTAssertTrue(events.isEmpty, "Requesting cancellation is not itself a terminal verdict")
        provider.callbacks[0](.finished(.failure(CancellationError())))
        useCase.start(request, icon: nil) { _ in }
        XCTAssertEqual(provider.requests.count, 2)
    }

    func testOldCallbackCannotCompleteAReusedRequestID() throws {
        let provider = Provider()
        let useCase = SigningWorkspaceUseCase(provider: provider)
        let request = try FeatureBoundaryFixtures.signing()
        let output = FeatureBoundaryFixtures.app(signed: true)
        useCase.start(request, icon: nil) { _ in }
        provider.callbacks[0](.finished(.success(output)))
        try useCase.capture(request)
        try useCase.finish(request, output: output, deletesSource: request.options.post_deleteAppAfterSigned)
        var events: [String] = []
        useCase.start(request, icon: nil) { events.append(self.label($0)) }
        provider.callbacks[0](.finished(.failure(Failure.refused)))
        provider.callbacks[1](.stage(.copying))
        XCTAssertEqual(events, ["copying"])
    }

    func testCaptureAndCleanupRequireSuccessAndAreEachConsumedOnce() throws {
        let provider = Provider()
        let useCase = SigningWorkspaceUseCase(provider: provider)
        let request = try FeatureBoundaryFixtures.signing()
        let output = FeatureBoundaryFixtures.app(signed: true)
        XCTAssertThrowsError(try useCase.capture(request))
        XCTAssertThrowsError(try useCase.finish(request, output: output, deletesSource: request.options.post_deleteAppAfterSigned))
        useCase.start(request, icon: nil) { _ in }
        provider.callbacks[0](.finished(.success(output)))
        try useCase.capture(request)
        XCTAssertThrowsError(try useCase.capture(request))
        try useCase.finish(request, output: output, deletesSource: request.options.post_deleteAppAfterSigned)
        XCTAssertThrowsError(try useCase.finish(request, output: output, deletesSource: request.options.post_deleteAppAfterSigned))
        XCTAssertEqual(provider.captures.count, 1)
        XCTAssertEqual(provider.finishes.count, 1)
    }

    func testCleanupCannotSwapTheOutputOrEscalateDeletion() throws {
        let provider = Provider()
        let useCase = SigningWorkspaceUseCase(provider: provider)
        let request = try FeatureBoundaryFixtures.signing()
        let output = FeatureBoundaryFixtures.app(signed: true)
        useCase.start(request, icon: nil) { _ in }
        provider.callbacks[0](.finished(.success(output)))
        XCTAssertThrowsError(try useCase.finish(request, output: FeatureBoundaryFixtures.app(signed: true), deletesSource: request.options.post_deleteAppAfterSigned))
        XCTAssertThrowsError(try useCase.finish(request, output: output, deletesSource: !request.options.post_deleteAppAfterSigned))
        XCTAssertTrue(provider.finishes.isEmpty)
        try useCase.finish(request, output: output, deletesSource: request.options.post_deleteAppAfterSigned)
        XCTAssertEqual(provider.finishes.first?.1, try LibraryAppReference(app: output))
    }

    func testCompletionActionsUseTheReviewedValuesNotLaterUIChanges() throws {
        let provider = Provider()
        let useCase = SigningWorkspaceUseCase(provider: provider)
        var reviewed = Options.defaultOptions
        reviewed.appName = "Reviewed"
        let request = try FeatureBoundaryFixtures.signing(options: reviewed)
        let output = FeatureBoundaryFixtures.app(signed: true)
        useCase.start(request, icon: nil) { _ in }
        provider.callbacks[0](.finished(.success(output)))
        var changed = reviewed
        changed.appName = "Later UI value"
        let staleUIRequest = LibrarySigningRequest(id: request.id, app: request.app, options: changed,
            certificateID: request.certificateID, overridesBlockingPreflightIssues: false, notices: [])
        try useCase.capture(staleUIRequest)
        try useCase.finish(staleUIRequest, output: output, deletesSource: reviewed.post_deleteAppAfterSigned)
        XCTAssertEqual(provider.captures.first?.options, reviewed)
        XCTAssertEqual(provider.finishes.first?.0.options, reviewed)
    }

    func testAmbiguousProviderFailuresDoNotPermitRepeatingSideEffects() throws {
        let provider = Provider()
        provider.failCapture = true; provider.failFinish = true
        let useCase = SigningWorkspaceUseCase(provider: provider)
        let request = try FeatureBoundaryFixtures.signing()
        let output = FeatureBoundaryFixtures.app(signed: true)
        useCase.start(request, icon: nil) { _ in }
        provider.callbacks[0](.finished(.success(output)))
        XCTAssertThrowsError(try useCase.capture(request))
        XCTAssertThrowsError(try useCase.capture(request))
        XCTAssertThrowsError(try useCase.finish(request, output: output, deletesSource: request.options.post_deleteAppAfterSigned))
        XCTAssertThrowsError(try useCase.finish(request, output: output, deletesSource: request.options.post_deleteAppAfterSigned))
        XCTAssertEqual(provider.captures.count, 1)
        XCTAssertEqual(provider.finishes.count, 1)
    }
}
