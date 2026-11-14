import Foundation

@MainActor
final class InstallLibraryAppUseCase {
    private let provider: LibraryInstallationProviding
    init(provider: LibraryInstallationProviding) { self.provider = provider }

    func readiness(for app: AppInfoPresentable) throws -> InstallMethodReport { try provider.readiness(app: LibraryAppReference(app: app)) }
    @discardableResult
    func enqueue(_ app: AppInfoPresentable, exporting: Bool = false) throws -> LibraryInstallationSubmission {
        try provider.enqueueLibraryApp(LibraryAppReference(app: app), exporting: exporting)
    }
    @discardableResult
    func installWithoutSigning(_ app: AppInfoPresentable, allowingIssues: Bool = false) throws -> LibraryInstallationSubmission {
        // The adapter always verifies; allowing issues never skips the absence of a signature.
        try provider.installVerifiedLibraryApp(LibraryAppReference(app: app), allowingIssues: allowingIssues)
    }
}
