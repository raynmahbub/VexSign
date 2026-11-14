import Foundation
import Combine
import UserNotifications
import NimbleExtensions

@MainActor
final class CertificateWorkspaceAdapter: CertificateWorkspaceProviding {
    private let repository: CoreDataWorkspaceRepository
    private let sharing: TemporaryFileSharing
    private let status: CertificateStatusManager
    private let checker: BatchCertChecker
    private var storage: Storage { repository.storage }

    init(repository: CoreDataWorkspaceRepository, sharing: TemporaryFileSharing,
         status: CertificateStatusManager? = nil, checker: BatchCertChecker? = nil) {
        self.repository = repository
        self.sharing = sharing
        // Default arguments are evaluated at the caller. Resolve actor-owned
        // production defaults here, on this initializer's main actor instead.
        self.status = status ?? .shared
        self.checker = checker ?? .shared
    }

    func state() -> CertificateWorkspaceState {
        CertificateWorkspaceState(revocationSnapshots: status.revocationSnapshots, refreshingIDs: status.refreshingRevocationIDs,
            batchResults: checker.results, batchRunning: checker.isRunning, batchChecked: checker.checkedCount,
            batchTotal: checker.totalCount, batchLastRun: checker.lastRun)
    }
    func changes() -> AsyncStream<CertificateWorkspaceState> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.yield(state())
            let tokens = [status.objectWillChange.sink { [weak self] _ in
                Task { @MainActor in if let self { continuation.yield(self.state()) } }
            }, checker.objectWillChange.sink { [weak self] _ in
                Task { @MainActor in if let self { continuation.yield(self.state()) } }
            }]
            let observation = StreamObservationCancellation(tokens)
            continuation.onTermination = { _ in observation.cancel() }
        }
    }
    func refreshRevocation(id: String, force: Bool) throws { status.refreshRevocation(for: try storage.managedCertificate(id: id), force: force, storage: storage) }
    func checkDeviceStatus(id: String) throws { storage.revokagedCertificate(for: try storage.managedCertificate(id: id)) }
    func rename(id: String, nickname: String?) throws { try repository.renameCertificate(id: id, nickname: nickname) }
    func remove(id: String) throws {
        guard CertificateRemoval.delete(try storage.managedCertificate(id: id), storage: storage) else { throw WorkspaceAccessError.persistenceFailed }
    }

    func shareExport(id: String) throws {
        let certificate = try storage.managedCertificate(id: id)
        let lease = try AppOperationRegistry.shared.acquireTemporaryWork()
        guard let zip = CertificateExporter.makeZip(for: certificate, storage: storage) else { throw CocoaError(.fileWriteUnknown) }
        do {
            try sharing.shareFile(zip) { [self, lease] in
                defer { withExtendedLifetime(lease) {} }
                cleanupExport(zip)
            }
        } catch {
            cleanupExport(zip)
            throw error
        }
    }
    private func cleanupExport(_ zip: URL) {
        do { try FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
        catch { FileLogger.error("Could not remove certificate export: \(error.localizedDescription)", category: "certificates") }
    }
    func additionalProfiles(id: String) throws -> [AdditionalProfileRecord] { AdditionalProfiles.entries(for: try storage.managedCertificate(id: id)) }
    func importAdditionalProfile(from url: URL, certificateID: String) throws {
        let row = try storage.managedCertificate(id: certificateID)
        let lease = try AppOperationRegistry.shared.acquire(SigningIdentityStore.leaseKey(reference: certificateID))
        defer { withExtendedLifetime(lease) {} }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { try AdditionalProfiles.add(from: url, to: row) }
        catch let problem as AdditionalProfiles.ImportProblem {
            throw NSError(domain: "CertificateProfileImport", code: 1, userInfo: [NSLocalizedDescriptionKey: problem.message])
        }
    }
    func removeAdditionalProfile(entryID: String, certificateID: String) throws {
        let lease = try AppOperationRegistry.shared.acquire(SigningIdentityStore.leaseKey(reference: certificateID))
        defer { withExtendedLifetime(lease) {} }
        // Never trust an arbitrary path returned by a caller. Re-resolve the current
        // certificate and accept only an entry enumerated under its owned directory.
        guard let entry = try additionalProfiles(id: certificateID).first(where: { $0.id == entryID }) else {
            throw WorkspaceAccessError.missingRecord
        }
        try AdditionalProfiles.remove(entry)
    }
    func inspectAll(online: Bool) async throws -> CertificateHealthReport {
        try await CertificateInspector.inspectAll(storage: storage, online: online)
    }
    func checkAll(online: Bool) async { await checker.checkAll(online: online) }
    func importCertificate(p12: URL, profile: URL, password: String, name: String, completion: @escaping @MainActor (Error?) -> Void) {
        CertificateManagementService.importCertificateFiles(p12URL: p12, provisionURL: profile, p12Password: password, certificateName: name) { error in
            Task { @MainActor in completion(error) }
        }
    }
    func setMonitoringEnabled(_ enabled: Bool) async throws {
        if enabled {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            EcosystemMaintenance.schedule()
        }
    }
}
