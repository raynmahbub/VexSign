import Foundation
import Combine

@MainActor
final class CertificateWorkspaceModel: ObservableObject {
    @Published private(set) var state: CertificateWorkspaceState
    private let useCase: CertificateWorkspaceUseCase
    private let workspace: WorkspaceViewModel
    private let platform: PlatformSystemAdapting
    private var observation: Task<Void, Never>?

    init(useCase: CertificateWorkspaceUseCase, workspace: WorkspaceViewModel, platform: PlatformSystemAdapting) {
        self.useCase = useCase
        self.workspace = workspace
        self.platform = platform
        self.state = useCase.state()
        let changes = useCase.changes()
        observation = Task { @MainActor [weak self] in
            for await state in changes {
                guard !Task.isCancelled, let self else { break }
                self.state = state
            }
        }
    }
    deinit { observation?.cancel() }
    var results: [CertCheckResult] { state.batchResults }
    var isRunning: Bool { state.batchRunning }
    var checkedCount: Int { state.batchChecked }
    var totalCount: Int { state.batchTotal }
    var notCheckedCount: Int { results.filter { $0.status == .notChecked }.count }
    var summary: (valid: Int, expiring: Int, expired: Int, revoked: Int) {
        (results.filter { $0.status == .valid }.count, results.filter { $0.status == .expiringSoon }.count,
         results.filter { $0.status == .expired }.count, results.filter { $0.status == .revoked }.count)
    }
    func assessment(for certificate: CertificateRecord, now: Date = Date()) -> CertificateStatusAssessment {
        let snapshot = certificate.uuid.flatMap { state.revocationSnapshots[$0] }
        return CertificateStatusAssessment.assess(.init(certificateExpiry: snapshot?.certificateExpires,
            profileExpiry: certificate.expiration, revokedOnRecord: certificate.revoked,
            evidence: snapshot?.evidence ?? .notChecked), now: now)
    }
    func refresh(_ certificate: CertificateRecord, force: Bool = true) { perform { try useCase.refresh(certificate, force: force) } }
    func checkDeviceStatus(_ certificate: CertificateRecord) { perform { try useCase.checkDeviceStatus(certificate) } }
    func rename(_ certificate: CertificateRecord, to nickname: String) { perform { try useCase.rename(certificate, nickname: nickname) } }
    func delete(_ certificate: CertificateRecord) { perform { try useCase.remove(certificate) } }
    func export(_ certificate: CertificateRecord) { perform { try useCase.export(certificate) } }
    func additionalProfiles(_ certificate: CertificateRecord) -> [AdditionalProfileRecord] {
        do { return try useCase.additionalProfiles(certificate) }
        catch { report(error); return [] }
    }
    func addProfile(_ url: URL, to certificate: CertificateRecord) throws {
        try useCase.addProfile(url, to: certificate)
        workspace.refresh()
    }
    func removeProfile(_ entry: AdditionalProfileRecord, from certificate: CertificateRecord) throws {
        try useCase.removeProfile(entry, from: certificate)
        workspace.refresh()
    }
    func inspectAll(online: Bool) async throws -> CertificateHealthReport { try await useCase.inspectAll(online: online) }
    func checkAll(online: Bool = false) async {
        await useCase.checkAll(online: online)
        state = useCase.state()
        workspace.refresh()
    }
    func importFiles(p12: URL, profile: URL, password: String, name: String, completion: @escaping @MainActor (Error?) -> Void) {
        useCase.importFiles(p12: p12, profile: profile, password: password, name: name) { [workspace] error in
            workspace.refresh()
            completion(error)
        }
    }
    func importBundle(from url: URL, password: String, name: String, completion: @escaping @MainActor (Error?) -> Void) {
        useCase.importBundle(from: url, password: password, name: name) { [workspace] error in
            workspace.refresh()
            completion(error)
        }
    }
    func setMonitoringEnabled(_ enabled: Bool) async {
        do { try await useCase.setMonitoringEnabled(enabled) }
        catch { report(error) }
    }
    private func perform(_ operation: () throws -> Void) {
        do { try operation(); workspace.refresh() }
        catch { report(error) }
    }
    private func report(_ error: Error) { platform.notifyError(error.localizedDescription, sticky: true) }
}
