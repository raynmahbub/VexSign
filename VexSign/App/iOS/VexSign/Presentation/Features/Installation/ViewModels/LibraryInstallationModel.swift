import Foundation

@MainActor
final class LibraryInstallationModel {
    private let useCase: InstallLibraryAppUseCase
    private let platform: PlatformSystemAdapting
    init(useCase: InstallLibraryAppUseCase, platform: PlatformSystemAdapting) {
        self.useCase = useCase
        self.platform = platform
    }
    func readiness(for app: AppInfoPresentable) throws -> InstallMethodReport { try useCase.readiness(for: app) }
    func enqueue(_ app: AppInfoPresentable, exporting: Bool = false) {
        do { try useCase.enqueue(app, exporting: exporting) }
        catch { platform.notifyError(error.localizedDescription, sticky: true) }
    }
    @discardableResult
    func installWithoutSigning(_ app: AppInfoPresentable, allowingIssues: Bool = false) throws -> LibraryInstallationSubmission {
        try useCase.installWithoutSigning(app, allowingIssues: allowingIssues)
    }
}
