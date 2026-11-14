import Foundation

enum LibraryInstallationSubmission: Equatable, Sendable {
    case queuedForExport
    case submittedForGuestImport
    case submittedForInstallation
}

@MainActor
protocol LibraryInstallationProviding: AnyObject {
    func readiness(app: LibraryAppReference) throws -> InstallMethodReport
    func enqueueLibraryApp(_ app: LibraryAppReference, exporting: Bool) throws -> LibraryInstallationSubmission
    func installVerifiedLibraryApp(_ app: LibraryAppReference, allowingIssues: Bool) throws -> LibraryInstallationSubmission
}
