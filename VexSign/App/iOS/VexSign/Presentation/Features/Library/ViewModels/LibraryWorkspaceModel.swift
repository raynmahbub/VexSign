import Foundation

@MainActor
final class LibraryWorkspaceModel {
    private let useCase: LibraryUseCase
    private let workspace: WorkspaceViewModel
    private let platform: PlatformSystemAdapting

    init(useCase: LibraryUseCase, workspace: WorkspaceViewModel, platform: PlatformSystemAdapting) {
        self.useCase = useCase
        self.workspace = workspace
        self.platform = platform
    }

    func importPackage(_ source: URL) async throws -> LibraryAppRecord {
        defer { workspace.refresh() }
        return try await useCase.importPackage(source)
    }
    func clone(app: AppInfoPresentable, customName: String? = nil, customBundleId: String? = nil,
               asUnsigned: Bool = false, iconOrdinal: Int? = nil) async throws -> LibraryAppRecord {
        defer { workspace.refresh() }
        return try await useCase.clone(app, request: LibraryCloneRequest(customName: customName,
            customBundleIdentifier: customBundleId, asUnsigned: asUnsigned, iconOrdinal: iconOrdinal))
    }
    func bundleURL(for app: AppInfoPresentable) -> URL? { useCase.bundleURL(for: app) }
    func artifactURL(for app: AppInfoPresentable) -> URL? { useCase.artifactURL(for: app) }
    func certificate(for app: AppInfoPresentable) -> CertificateRecord? { useCase.certificate(for: app) }
    func allApps() -> [LibraryAppRecord] { workspace.snapshot.apps }

    @discardableResult
    func delete(_ app: AppInfoPresentable) -> Bool { delete([app]) }
    @discardableResult
    func delete(_ apps: [AppInfoPresentable]) -> Bool { perform { try useCase.delete(apps) } }
    func rename(_ app: AppInfoPresentable, to name: String) { _ = perform { try useCase.rename(app, to: name) } }
    func describe(_ app: AppInfoPresentable, description: String?) {
        _ = perform { try useCase.setDescription(description, for: app) }
    }
    func reorder(_ apps: [AppInfoPresentable]) { _ = perform { try useCase.reorder(apps) } }

    private func perform(_ action: () throws -> Void) -> Bool {
        do { try action(); workspace.refresh(); return true }
        catch { report(error); return false }
    }
    private func report(_ error: Error) { platform.notifyError(error.localizedDescription, sticky: true) }
}
