import Foundation
import UIKit
import NimbleExtensions

@MainActor
final class LibrarySigningAdapter: LibrarySigningProviding {
    typealias Icon = UIImage
    private let repository: CoreDataWorkspaceRepository
    private var storage: Storage { repository.storage }
    private var cancelledRequests: Set<String> = []
    private var successfulCertificates: [String: String] = [:]

    init(repository: CoreDataWorkspaceRepository) { self.repository = repository }

    private func certificate(_ id: String?) throws -> CertificatePair? {
        guard let id else { return nil }
        return try storage.managedCertificate(id: id)
    }

    private func optionalBundleDirectory(_ url: URL) throws -> [String] {
        do { return try FileManager.default.contentsOfDirectory(atPath: url.path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
    }
    func bundleContents(app reference: LibraryAppReference) throws -> SigningBundleContents {
        let app = try storage.managedApp(matching: reference)
        guard let path = storage.getAppDirectory(for: app) else { throw WorkspaceAccessError.missingRecord }
        let bundle = Bundle(url: path)
        let executable = bundle.flatMap { TweakImportSupport.containedRegularFile(path.appendingPathComponent($0.exec), in: path) }
        let all = executable.map { MachOReader.dylibs(forExecutableAt: $0) } ?? []
        let dylibs = all.filter { $0.hasPrefix("@rpath") || $0.hasPrefix("@executable_path") }
        var resolved: [String: URL] = [:]
        for dylib in dylibs { resolved[dylib] = TweakImportSupport.resolvedDylibURL(dylib, in: path) }
        return SigningBundleContents(appURL: path,
            frameworks: try optionalBundleDirectory(path.appendingPathComponent("Frameworks")),
            plugins: try optionalBundleDirectory(path.appendingPathComponent("PlugIns")),
            dylibs: dylibs, dylibURLs: resolved, hiddenDylibCount: all.count - dylibs.count,
            infoPlist: IPAFileLoader.plist(at: path.appendingPathComponent("Info.plist")) as? [String: Any] ?? [:])
    }
    func applicationExtensionNames(app reference: LibraryAppReference) throws -> [String] {
        AppExtensionEnumerator.appexNames(for: try storage.managedApp(matching: reference))
    }
    func embeddedEntitlements(app reference: LibraryAppReference) throws -> [String: Any]? {
        let app = try storage.managedApp(matching: reference)
        guard let directory = storage.getAppDirectory(for: app), let executable = Bundle(url: directory)?.executableURL else { return nil }
        return MachOEntitlements.read(forExecutableAt: executable)
    }

    func startSigning(_ request: LibrarySigningRequest, icon: UIImage?, onEvent: @escaping @MainActor (LibrarySigningEvent) -> Void) {
        do {
            let app = try storage.managedApp(matching: request.app)
            let certificate = try certificate(request.certificateID)
            PackageSigningCoordinator.signPackage(
                app, using: request.options, icon: icon, certificate: certificate,
                overridesBlockingPreflightIssues: request.overridesBlockingPreflightIssues,
                notices: request.notices, requestID: request.id, reviewedAuthorization: request.authorization,
                isCancellationRequested: { [weak self] in self?.cancelledRequests.contains(request.id) == true },
                onStage: { onEvent(.stage($0)) },
                onVerified: { onEvent(.signatureVerified) },
                onCompatibilityRemoved: { onEvent(.compatibilityRemoved($0)) }
            ) { [weak self, repository] result in
                self?.cancelledRequests.remove(request.id)
                switch result {
                case .success(let signed):
                    let projected = Result { try repository.appRecord(signed) }
                    if case .success = projected, let uuid = signed.certificate?.uuid { self?.successfulCertificates[request.id] = uuid }
                    onEvent(.finished(projected))
                case .failure(let error): onEvent(.finished(.failure(error)))
                }
            }
        } catch { onEvent(.finished(.failure(error))) }
    }

    func cancelSigning(id: String) {
        // This latch also covers Stop pressed before the coordinator's main-actor
        // task starts. The service alone cannot cancel a request it has not seen yet.
        cancelledRequests.insert(id)
        SigningService.shared.cancel(id)
    }

    func preflight(_ request: LibrarySigningRequest) throws -> PreflightResult {
        PreflightChecks.run(app: try storage.managedApp(matching: request.app), options: request.options,
                            certificate: try certificate(request.certificateID), profileResolutionIsDeferred: true)
    }

    func compatibilityTarget(app reference: LibraryAppReference, options: Options) throws -> ProfileCompatibility.Target {
        let app = try storage.managedApp(matching: reference)
        let bundle = storage.getAppDirectory(for: app)
        let nested = bundle.map { NestedBundleAudit.requiredIdentifiers(in: $0, removeAppExtensions: options.removeAppExtensions) } ?? []
        let removable = bundle.map { NestedBundleAudit.removableExtensionIdentifiers(in: $0, removeAppExtensions: options.removeAppExtensions) } ?? []
        return ProfileCompatibility.Target(app: app, options: options, nestedBundleIdentifiers: nested, removableExtensionIdentifiers: removable)
    }

    func compatibilityVerdict(profile: Certificate, target: ProfileCompatibility.Target) -> ProfileCompatibility.Verdict {
        ProfileCompatibility.verdict(profile: profile, target: target)
    }

    func inspectExecutables(_ request: LibrarySigningRequest) async throws -> SigningReviewEvidence {
        guard request.options.signingOption != .onlyModify else {
            return SigningReviewEvidence(report: .init(inspected: 0, findings: []), requiredBytes: 0)
        }
        let app = try storage.managedApp(matching: request.app)
        guard let directory = storage.getAppDirectory(for: app) else { throw WorkspaceAccessError.missingRecord }
        let inventory = try SigningIdentityStore.snapshot(storage: storage)
        let device = PairingBridge.inspectPairingRecord().udid
        let worker = Task.detached(priority: .userInitiated) {
            let resolution = request.options.signingOption == .default
                ? try SigningResolutionSession.review(bundle: directory, options: request.options, inventory: inventory,
                    preferredIdentity: request.certificateID, deviceUDID: device) : nil
            let report = try BundleExecutableAudit.inspect(directory,
                excludingBundlePaths: Set(resolution?.plannedRemovals ?? []))
            let bytes = try StoragePreflight.logicalSize(directory)
            let required = StoragePreflight.required(bytes: bytes, copies: 2)
            let available = FileManager.default.availableImportantCapacity(at: directory)
            try StoragePreflight.check(bytes: bytes, copies: 2, at: directory, available: available)
            try Task.checkCancellation()
            return SigningReviewEvidence(report: report, requiredBytes: required, resolution: resolution)
        }
        var evidence = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        if let identity = evidence.resolution?.mainIdentityReference, app.isSigned {
            let resolved = try storage.managedCertificate(id: identity)
            if let detail = CertificateIdentity.match(forBundleAt: directory, certificate: resolved).detail {
                evidence.resolution?.inventoryNotices.append(detail)
            }
        }
        return evidence
    }

    func savedProfile(bundleIdentifier: String?) -> SigningProfile? { SigningProfileStore.shared.profile(forBundleID: bundleIdentifier) }
    func savedCertificate(profile: SigningProfile?) -> CertificateRecord? {
        SigningProfileStore.shared.certificate(for: profile).map(repository.certificateRecord)
    }
    func resolveOptions(_ options: Options, for app: LibraryAppReference) throws -> Options {
        options.resolved(for: try storage.managedApp(matching: app))
    }
    func autoInjectSpecs(for app: LibraryAppReference) throws -> [TweakInjectionSpec] {
        Options.autoInjectSpecs(for: try storage.managedApp(matching: app))
    }
    func repeatSigning(_ app: LibraryAppReference, overridingBlockingIssues: Bool) async throws {
        let row = try storage.managedApp(matching: app)
        _ = try await AutoSignManager.shared.sign(row, overridingBlockingIssues: overridingBlockingIssues).get()
    }
    func captureSuccessfulRun(_ request: LibrarySigningRequest) throws {
        defer { TweakImportSupport.discard(request.options.injectionFiles) }
        let app = try storage.managedApp(matching: request.app)
        let actualIdentity = successfulCertificates.removeValue(forKey: request.id)
        SigningProfileStore.shared.capture(options: request.options, certificateUUID: actualIdentity, for: app)
    }
    func finishSuccessfulRun(_ request: LibrarySigningRequest, output: LibraryAppReference, deletesSource: Bool) throws {
        let source = try storage.managedApp(matching: request.app)
        let signed = try storage.managedApp(matching: output)
        CleanupManager.shared.finishSign(source: source, output: signed, origin: .sheet, runDeletesSource: deletesSource)
    }
    func certificateMatchSummary(app: LibraryAppReference, certificateID: String) throws -> String? {
        let row = try storage.managedApp(matching: app)
        let certificate = try storage.managedCertificate(id: certificateID)
        guard let signature = LibraryStatusStore.shared.status(for: row).signature else { return nil }
        return CertificateIdentity.match(state: signature, certificate: certificate).summary
    }
}
