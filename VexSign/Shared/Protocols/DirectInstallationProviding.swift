import Foundation

/// Opaque, process-local reference to an imported library item. Application code
/// never needs the Core Data object, a filesystem path, or a signing identity.
struct ImportedPackageHandle: Hashable, Sendable {
    let id: UUID
    init(id: UUID = UUID()) { self.id = id }
}

enum DirectInstallationRequestError: Error, Equatable {
    case verificationFailed([String])
    case missingImportedPackage
}

/// Implementation-facing boundary for import and installation submission.
/// Submission is not installation evidence; InstallConfirmation owns that verdict.
@MainActor
protocol DirectInstallationProviding: AnyObject {
    func currentPipelineIsContainerized() throws -> Bool
    func isContainerized(_ package: ImportedPackageHandle) throws -> Bool
    func enqueueDownload(_ url: URL, name: String)
    func acquireTemporaryWork() throws -> AnyObject
    func importPackage(_ url: URL) async throws -> ImportedPackageHandle
    func submitInstallation(_ package: ImportedPackageHandle, allowingIssues: Bool) throws
    func releaseImportedPackage(_ package: ImportedPackageHandle)
}
