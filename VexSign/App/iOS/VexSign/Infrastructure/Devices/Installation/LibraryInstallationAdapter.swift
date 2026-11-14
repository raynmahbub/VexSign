import Foundation

@MainActor
final class LibraryInstallationAdapter: LibraryInstallationProviding {
    private let storage: Storage
    init(storage: Storage) { self.storage = storage }

    func readiness(app reference: LibraryAppReference) throws -> InstallMethodReport {
        let app = try storage.managedApp(matching: reference)
        let pipeline = try SigningModeManager.shared.pipeline(for: app)
        let inputs = InstallPreflightInputs(hasServerCertificate: LocalTLSIdentity.current() != nil,
            pairing: PairingBridge.inspectPairingRecord(), trollStoreDetected: TrollStoreHandoff.installedByTrollStore(),
            hasTrustedServerCertificate: LocalTLSIdentity.isSystemTrusted(), hasEmbeddedRuntime: EmbeddedContainerRuntime.isAvailable)
        return InstallMethodReport(method: pipeline.installMethod, readiness: InstallPreflight.readiness(for: pipeline.installMethod, inputs))
    }
    func enqueueLibraryApp(_ reference: LibraryAppReference, exporting: Bool) throws -> LibraryInstallationSubmission {
        let app = try storage.managedApp(matching: reference)
        let guest: Bool
        if exporting { guest = false }
        else { guest = try SigningModeManager.shared.pipeline(for: app) == .containerized }
        InstallQueue.shared.enqueue(app, exporting: exporting)
        // Export requests and queue submission are not device-confirmed installation.
        return exporting ? .queuedForExport : (guest ? .submittedForGuestImport : .submittedForInstallation)
    }

    func installVerifiedLibraryApp(_ reference: LibraryAppReference, allowingIssues: Bool) throws -> LibraryInstallationSubmission {
        let app = try storage.managedApp(matching: reference)
        let isGuest = try SigningModeManager.shared.pipeline(for: app) == .containerized
        do { _ = try DirectInstaller.shared.install(app, allowingIssues: allowingIssues) }
        catch DirectInstaller.DirectInstallError.verificationFailed(let issues) {
            throw DirectInstallationRequestError.verificationFailed(issues)
        }
        return isGuest ? .submittedForGuestImport : .submittedForInstallation
    }
}
