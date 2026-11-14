import Foundation

struct LibrarySigningRequest {
    let id: String
    let app: LibraryAppReference
    let options: Options
    let certificateID: String?
    let overridesBlockingPreflightIssues: Bool
    let notices: [String]
}

enum LibrarySigningEvent {
    case stage(SigningStage)
    case signatureVerified
    case compatibilityRemoved([String])
    case finished(Result<LibraryAppRecord, Error>)
}

/// Icon is an injected presentation asset, not a UI framework dependency in the
/// application workflow. Production uses UIImage without re-encoding user icons.
@MainActor
protocol LibrarySigningProviding<Icon>: AnyObject {
    associatedtype Icon
    func bundleContents(app: LibraryAppReference) throws -> SigningBundleContents
    func applicationExtensionNames(app: LibraryAppReference) throws -> [String]
    func embeddedEntitlements(app: LibraryAppReference) throws -> [String: Any]?
    func startSigning(_ request: LibrarySigningRequest, icon: Icon?, onEvent: @escaping @MainActor (LibrarySigningEvent) -> Void)
    func cancelSigning(id: String)
    func preflight(_ request: LibrarySigningRequest) throws -> PreflightResult
    func compatibilityTarget(app: LibraryAppReference, options: Options) throws -> ProfileCompatibility.Target
    func compatibilityVerdict(profile: Certificate, target: ProfileCompatibility.Target) -> ProfileCompatibility.Verdict
    func inspectExecutables(_ request: LibrarySigningRequest) async throws -> SigningReviewEvidence
    func savedProfile(bundleIdentifier: String?) -> SigningProfile?
    func savedCertificate(profile: SigningProfile?) -> CertificateRecord?
    func resolveOptions(_ options: Options, for app: LibraryAppReference) throws -> Options
    func autoInjectSpecs(for app: LibraryAppReference) throws -> [TweakInjectionSpec]
    func repeatSigning(_ app: LibraryAppReference, overridingBlockingIssues: Bool) async throws
    func captureSuccessfulRun(_ request: LibrarySigningRequest) throws
    func finishSuccessfulRun(_ request: LibrarySigningRequest, output: LibraryAppReference, deletesSource: Bool) throws
    func certificateMatchSummary(app: LibraryAppReference, certificateID: String) throws -> String?
}

struct SigningBundleContents {
    let appURL: URL
    let frameworks: [String]
    let plugins: [String]
    let dylibs: [String]
    let dylibURLs: [String: URL]
    let hiddenDylibCount: Int
    let infoPlist: [String: Any]
}
