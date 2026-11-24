import Foundation

/// Reuses the authoritative import/installation pipelines. The adapter retains
/// legacy library objects only while the use case owns their opaque handles.
@MainActor
final class DirectPackageInstallationAdapter: DirectInstallationProviding {
    private var packages: [ImportedPackageHandle: AppInfoPresentable] = [:]

    func currentPipelineIsContainerized() throws -> Bool {
        try SigningModeManager.shared.pipeline() == .containerized
    }

    func isContainerized(_ package: ImportedPackageHandle) throws -> Bool {
        try SigningModeManager.shared.pipeline(for: resolve(package)) == .containerized
    }

    func enqueueDownload(_ url: URL, name: String) {
        _ = DownloadManager.shared.startDownload(from: url, appName: name)
    }

    func acquireTemporaryWork() throws -> AnyObject {
        try AppOperationRegistry.shared.acquireTemporaryWork()
    }

    func importPackage(_ url: URL) async throws -> ImportedPackageHandle {
        let cancellation = BackgroundWorkCancellation()
        let app: AppInfoPresentable = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let worker = PackageImportService.importPackage(url) { result in
                    continuation.resume(with: result)
                }
                cancellation.adopt(worker)
            }
        } onCancel: { cancellation.cancel() }
        // Even after late cancellation, return ownership of a committed import
        // to the use case so it can release the handle without deleting the app.
        let handle = ImportedPackageHandle()
        packages[handle] = app
        return handle
    }

    func submitInstallation(_ package: ImportedPackageHandle, allowingIssues: Bool) throws {
        do {
            try DirectInstaller.shared.install(resolve(package), allowingIssues: allowingIssues)
        } catch DirectInstaller.DirectInstallError.verificationFailed(let issues) {
            throw DirectInstallationRequestError.verificationFailed(issues)
        }
    }

    func releaseImportedPackage(_ package: ImportedPackageHandle) {
        packages.removeValue(forKey: package)
    }

    private func resolve(_ package: ImportedPackageHandle) throws -> AppInfoPresentable {
        guard let app = packages[package] else {
            throw DirectInstallationRequestError.missingImportedPackage
        }
        return app
    }
}
