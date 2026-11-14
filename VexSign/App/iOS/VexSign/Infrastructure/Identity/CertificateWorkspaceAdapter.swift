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
         status: CertificateStatusManager = .shared, checker: BatchCertChecker = .shared) {
        self.repository = repository
        self.sharing = sharing
        self.status = status
        self.checker = checker
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
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { try AdditionalProfiles.add(from: url, to: row) }
        catch let problem as AdditionalProfiles.ImportProblem {
            throw NSError(domain: "CertificateProfileImport", code: 1, userInfo: [NSLocalizedDescriptionKey: problem.message])
        }
    }
    func removeAdditionalProfile(entryID: String, certificateID: String) throws {
        // Never trust an arbitrary path returned by a caller. Re-resolve the current
        // certificate and accept only an entry enumerated under its owned directory.
        guard let entry = try additionalProfiles(id: certificateID).first(where: { $0.id == entryID }) else {
            throw WorkspaceAccessError.missingRecord
        }
        try AdditionalProfiles.remove(entry)
    }
    func inspectAll(online: Bool) async throws -> CertificateHealthReport {
        let rows = storage.getAllCertificates()
        var health: [CertificateHealth] = []
        var errors: [String] = []
        for certificate in rows {
            try Task.checkCancellation()
            guard !certificate.isDeleted, let id = certificate.uuid,
                  let p12 = storage.getFile(.certificate, from: certificate),
                  let profile = storage.getFile(.provision, from: certificate) else { continue }
            let name = certificate.nickname ?? .localized("Certificate")
            do {
                let inspected = try await CertificateInspector.inspect(id: id, name: name, p12: p12,
                    password: try certificate.requireSigningPassword(), profile: profile, online: online)
                health.append(inspected)
            } catch is CancellationError { throw CancellationError() }
            catch { errors.append(name + ": " + error.localizedDescription) }
        }
        return CertificateHealthReport(certificates: health, errors: errors)
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
