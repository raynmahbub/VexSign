import Foundation

/// App-facing preparation and execution over the existing signing owner. This is
/// not a second pipeline; verification, registration and task tracing stay there.
@MainActor
final class SigningWorkspaceUseCase<Icon> {
    private let provider: any LibrarySigningProviding<Icon>
    private var active: [String: UUID] = [:]
    private struct SuccessfulRun {
        let request: LibrarySigningRequest
        let output: LibraryAppReference
        var captured = false
        var settled = false
    }
    // Consumption metadata only. The existing signer still owns execution,
    // verification, registration, task history and file-cleanup policy.
    private var successfulRuns: [String: SuccessfulRun] = [:]
    init(provider: any LibrarySigningProviding<Icon>) { self.provider = provider }

    func start(_ request: LibrarySigningRequest, icon: Icon?, onEvent: @escaping @MainActor (LibrarySigningEvent) -> Void) {
        guard active[request.id] == nil, successfulRuns[request.id] == nil, successfulRuns.count < 64 else {
            onEvent(.finished(.failure(ArchitectureDomainError.duplicateOrBusyOperation)))
            return
        }
        let invocation = UUID()
        active[request.id] = invocation
        provider.startSigning(request, icon: icon) { [weak self] event in
            guard let self, self.active[request.id] == invocation else { return }
            if case .verificationReport(let report) = event {
                onEvent(.verificationReport(report))
                return
            }
            if case .finished(let result) = event {
                self.active.removeValue(forKey: request.id)
                if case .success(let output) = result {
                    do {
                        self.successfulRuns[request.id] = SuccessfulRun(request: request, output: try LibraryAppReference(app: output))
                    } catch { onEvent(.finished(.failure(error))); return }
                }
            }
            // `signatureVerified` is forwarded only when the engine reports it.
            // Finishing signing never fabricates verification or installation evidence.
            onEvent(event)
        }
    }
    func cancel(id: String) {
        guard active[id] != nil else { return }
        provider.cancelSigning(id: id)
    }
    func preflight(_ request: LibrarySigningRequest) throws -> PreflightResult { try provider.preflight(request) }
    func target(app: AppInfoPresentable, options: Options) throws -> ProfileCompatibility.Target {
        try provider.compatibilityTarget(app: LibraryAppReference(app: app), options: options)
    }
    func verdict(profile: Certificate, target: ProfileCompatibility.Target) -> ProfileCompatibility.Verdict {
        provider.compatibilityVerdict(profile: profile, target: target)
    }
    func inspect(_ request: LibrarySigningRequest) async throws -> SigningReviewEvidence {
        try await provider.inspectExecutables(request)
    }
    func savedProfile(bundleIdentifier: String?) -> SigningProfile? { provider.savedProfile(bundleIdentifier: bundleIdentifier) }
    func savedCertificate(profile: SigningProfile?) -> CertificateRecord? { provider.savedCertificate(profile: profile) }
    func resolve(_ options: Options, for app: AppInfoPresentable) throws -> Options {
        try provider.resolveOptions(options, for: LibraryAppReference(app: app))
    }
    func autoInjectSpecs(for app: AppInfoPresentable) throws -> [TweakInjectionSpec] {
        try provider.autoInjectSpecs(for: LibraryAppReference(app: app))
    }
    func bundleContents(app: AppInfoPresentable) throws -> SigningBundleContents {
        try provider.bundleContents(app: LibraryAppReference(app: app))
    }
    func applicationExtensionNames(app: AppInfoPresentable) throws -> [String] {
        try provider.applicationExtensionNames(app: LibraryAppReference(app: app))
    }
    func embeddedEntitlements(app: AppInfoPresentable) throws -> [String: Any]? {
        try provider.embeddedEntitlements(app: LibraryAppReference(app: app))
    }
    func reset(_ options: Options, for app: AppInfoPresentable) throws -> Options {
        var value = options
        value.resetPerApp(autoInject: try provider.autoInjectSpecs(for: LibraryAppReference(app: app)))
        return value
    }
    func repeatSigning(_ app: AppInfoPresentable, overridingBlockingIssues: Bool) async throws {
        try await provider.repeatSigning(LibraryAppReference(app: app), overridingBlockingIssues: overridingBlockingIssues)
    }
    func capture(_ request: LibrarySigningRequest) throws {
        guard var run = successfulRuns[request.id], !run.captured, run.request.app == request.app,
              run.request.certificateID == request.certificateID else { throw WorkspaceAccessError.invalidReference }
        run.captured = true
        store(run)
        // Use the reviewed value, not fresh UI settings. A provider error cannot
        // authorize a second ambiguous profile write or staging-file cleanup.
        try provider.captureSuccessfulRun(run.request)
    }
    func finish(_ request: LibrarySigningRequest, output: AppInfoPresentable, deletesSource: Bool) throws {
        guard var run = successfulRuns[request.id], !run.settled, run.request.app == request.app,
              run.request.certificateID == request.certificateID,
              try LibraryAppReference(app: output) == run.output,
              deletesSource == run.request.options.post_deleteAppAfterSigned else { throw WorkspaceAccessError.invalidReference }
        run.settled = true
        store(run)
        try provider.finishSuccessfulRun(run.request, output: run.output, deletesSource: deletesSource)
    }
    private func store(_ run: SuccessfulRun) {
        if run.captured && run.settled { successfulRuns.removeValue(forKey: run.request.id) }
        else { successfulRuns[run.request.id] = run }
    }
    func certificateMatchSummary(app: AppInfoPresentable, certificate: CertificateRecord) throws -> String? {
        try provider.certificateMatchSummary(app: LibraryAppReference(app: app), certificateID: certificate.id)
    }
}
