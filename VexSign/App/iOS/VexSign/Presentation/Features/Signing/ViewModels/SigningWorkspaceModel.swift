import Foundation
import UIKit
import NimbleExtensions

@MainActor
final class SigningWorkspaceModel {
    private let useCase: SigningWorkspaceUseCase<UIImage>
    private let platform: PlatformSystemAdapting
    init(useCase: SigningWorkspaceUseCase<UIImage>, platform: PlatformSystemAdapting) {
        self.useCase = useCase
        self.platform = platform
    }

    private func request(app: AppInfoPresentable, options: Options, certificate: CertificateRecord?,
                         id: String = UUID().uuidString, overrides: Bool = false) throws -> LibrarySigningRequest {
        LibrarySigningRequest(id: id, app: try LibraryAppReference(app: app), options: options,
                              certificateID: certificate?.id, overridesBlockingPreflightIssues: overrides, notices: [])
    }

    func preflight(app: AppInfoPresentable, options: Options, certificate: CertificateRecord?) -> PreflightResult {
        do { return try useCase.preflight(request(app: app, options: options, certificate: certificate)) }
        catch {
            return PreflightResult(issues: [PreflightIssue(.localized("App files not found."),
                error.localizedDescription, severity: .blocking, code: .executableUnavailable, status: .invalid)])
        }
    }
    func compatibilityTarget(app: AppInfoPresentable, options: Options) -> ProfileCompatibility.Target {
        do { return try useCase.target(app: app, options: options) }
        catch { return ProfileCompatibility.Target(bundleIdentifier: options.appIdentifier ?? app.identifier) }
    }
    func verdict(profile: Certificate, target: ProfileCompatibility.Target) -> ProfileCompatibility.Verdict {
        useCase.verdict(profile: profile, target: target)
    }
    func inspect(app: AppInfoPresentable, options: Options, certificate: CertificateRecord?) async throws -> SigningReviewEvidence {
        try await useCase.inspect(request(app: app, options: options, certificate: certificate))
    }
    func cancel(_ id: String) { useCase.cancel(id: id) }

    func signPackage(_ app: AppInfoPresentable, using options: Options, icon: UIImage?, certificate: CertificateRecord?,
                     overridesBlockingPreflightIssues: Bool = false, requestID: String = UUID().uuidString,
                     onStage: (@MainActor (SigningStage) -> Void)? = nil,
                     onVerified: (@MainActor () -> Void)? = nil,
                     onCompatibilityRemoved: (@MainActor ([String]) -> Void)? = nil,
                     completion: @escaping @MainActor (Result<LibraryAppRecord, Error>) -> Void) {
        do {
            let draft = try request(app: app, options: options, certificate: certificate, id: requestID, overrides: overridesBlockingPreflightIssues)
            useCase.start(draft, icon: icon) { event in
                switch event {
                case .stage(let stage): onStage?(stage)
                case .signatureVerified: onVerified?()
                case .compatibilityRemoved(let components): onCompatibilityRemoved?(components)
                case .finished(let result): completion(result)
                }
            }
        } catch { completion(.failure(error)) }
    }

    func savedProfile(forBundleID bundleID: String?) -> SigningProfile? { useCase.savedProfile(bundleIdentifier: bundleID) }
    func savedCertificate(for profile: SigningProfile?) -> CertificateRecord? { useCase.savedCertificate(profile: profile) }
    func resolve(_ options: Options, for app: AppInfoPresentable) -> Options {
        do { return try useCase.resolve(options, for: app) }
        catch { platform.notifyError(error.localizedDescription, sticky: true); return options }
    }
    func autoInjectSpecs(for app: AppInfoPresentable) -> [TweakInjectionSpec] {
        do { return try useCase.autoInjectSpecs(for: app) }
        catch { platform.notifyError(error.localizedDescription, sticky: true); return [] }
    }
    func bundleContents(app: AppInfoPresentable) -> SigningBundleContents? {
        do { return try useCase.bundleContents(app: app) }
        catch { platform.notifyError(error.localizedDescription, sticky: true); return nil }
    }
    func applicationExtensionNames(app: AppInfoPresentable) -> [String] {
        do { return try useCase.applicationExtensionNames(app: app) }
        catch { platform.notifyError(error.localizedDescription, sticky: true); return [] }
    }
    func embeddedEntitlements(app: AppInfoPresentable) -> [String: Any]? {
        do { return try useCase.embeddedEntitlements(app: app) }
        catch { platform.notifyError(error.localizedDescription, sticky: true); return nil }
    }
    func reset(_ options: Options, for app: AppInfoPresentable) -> Options {
        do { return try useCase.reset(options, for: app) }
        catch { platform.notifyError(error.localizedDescription, sticky: true); return options }
    }
    func signAgain(_ app: AppInfoPresentable, overridingBlockingIssues: Bool = false) async -> Result<Void, Error> {
        do { try await useCase.repeatSigning(app, overridingBlockingIssues: overridingBlockingIssues); return .success(Void()) }
        catch { return .failure(error) }
    }
    func capture(options: Options, certificate: CertificateRecord?, for app: AppInfoPresentable, requestID: String) {
        do { try useCase.capture(request(app: app, options: options, certificate: certificate, id: requestID)) }
        catch { platform.notifyError(error.localizedDescription, sticky: true) }
    }
    func finish(source: AppInfoPresentable, output: AppInfoPresentable, options: Options, certificate: CertificateRecord?, deletesSource: Bool, requestID: String) {
        do { try useCase.finish(request(app: source, options: options, certificate: certificate, id: requestID), output: output, deletesSource: deletesSource) }
        catch { platform.notifyError(error.localizedDescription, sticky: true) }
    }
    func certificateMatchSummary(app: AppInfoPresentable, certificate: CertificateRecord) -> String? {
        do { return try useCase.certificateMatchSummary(app: app, certificate: certificate) }
        catch { return nil }
    }
}
