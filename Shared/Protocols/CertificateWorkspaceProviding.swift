import Foundation

struct CertificateWorkspaceState {
    var revocationSnapshots: [String: CertificateRevocationSnapshot] = [:]
    var refreshingIDs: Set<String> = []
    var batchResults: [CertCheckResult] = []
    var batchRunning = false
    var batchChecked = 0
    var batchTotal = 0
    var batchLastRun: Date?
}

struct CertificateHealthReport {
    let certificates: [CertificateHealth]
    let errors: [String]
}

@MainActor
protocol CertificateWorkspaceProviding: AnyObject {
    func state() -> CertificateWorkspaceState
    func changes() -> AsyncStream<CertificateWorkspaceState>
    func refreshRevocation(id: String, force: Bool) throws
    func checkDeviceStatus(id: String) throws
    func rename(id: String, nickname: String?) throws
    func remove(id: String) throws
    /// The export lease and key-bearing files stay inside the adapter through sharing completion.
    func shareExport(id: String) throws
    func additionalProfiles(id: String) throws -> [AdditionalProfileRecord]
    func importAdditionalProfile(from url: URL, certificateID: String) throws
    func removeAdditionalProfile(entryID: String, certificateID: String) throws
    func inspectAll(online: Bool) async throws -> CertificateHealthReport
    func checkAll(online: Bool) async
    func importCertificate(p12: URL, profile: URL, password: String, name: String, completion: @escaping @MainActor (Error?) -> Void)
    /// One selection that may be a `.p12`, a profile, or a container holding both.
    /// The adapter resolves the pair and reuses the same import path.
    func importCertificateBundle(from url: URL, password: String, name: String, completion: @escaping @MainActor (Error?) -> Void)
    func setMonitoringEnabled(_ enabled: Bool) async throws
}

/// Sharing has completion semantics because the exporter must not erase its lease
/// while a share extension is still reading a private-key archive.
@MainActor
protocol TemporaryFileSharing: AnyObject {
    func shareFile(_ url: URL, completion: @escaping @MainActor () -> Void) throws
}
