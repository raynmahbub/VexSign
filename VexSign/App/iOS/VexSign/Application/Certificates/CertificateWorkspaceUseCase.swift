import Foundation

@MainActor
final class CertificateWorkspaceUseCase {
    private let provider: CertificateWorkspaceProviding
    init(provider: CertificateWorkspaceProviding) { self.provider = provider }

    func state() -> CertificateWorkspaceState { provider.state() }
    func changes() -> AsyncStream<CertificateWorkspaceState> { provider.changes() }
    func refresh(_ certificate: CertificateRecord, force: Bool = true) throws { try provider.refreshRevocation(id: certificate.id, force: force) }
    func checkDeviceStatus(_ certificate: CertificateRecord) throws { try provider.checkDeviceStatus(id: certificate.id) }
    func rename(_ certificate: CertificateRecord, nickname: String) throws {
        try provider.rename(id: certificate.id, nickname: nickname.isEmpty ? nil : nickname)
    }
    func remove(_ certificate: CertificateRecord) throws { try provider.remove(id: certificate.id) }
    func export(_ certificate: CertificateRecord) throws { try provider.shareExport(id: certificate.id) }
    func additionalProfiles(_ certificate: CertificateRecord) throws -> [AdditionalProfileRecord] { try provider.additionalProfiles(id: certificate.id) }
    func addProfile(_ url: URL, to certificate: CertificateRecord) throws { try provider.importAdditionalProfile(from: url, certificateID: certificate.id) }
    func removeProfile(_ entry: AdditionalProfileRecord, from certificate: CertificateRecord) throws {
        try provider.removeAdditionalProfile(entryID: entry.id, certificateID: certificate.id)
    }
    func inspectAll(online: Bool) async throws -> CertificateHealthReport { try await provider.inspectAll(online: online) }
    func checkAll(online: Bool = false) async { await provider.checkAll(online: online) }
    func importFiles(p12: URL, profile: URL, password: String, name: String, completion: @escaping @MainActor (Error?) -> Void) {
        provider.importCertificate(p12: p12, profile: profile, password: password, name: name, completion: completion)
    }
    func setMonitoringEnabled(_ enabled: Bool) async throws { try await provider.setMonitoringEnabled(enabled) }
}
