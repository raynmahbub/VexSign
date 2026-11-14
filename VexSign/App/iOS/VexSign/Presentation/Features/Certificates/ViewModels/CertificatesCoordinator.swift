import Foundation
import Combine
import NimbleExtensions

/// Presentation feedback and sheet sequencing only. Secret-bearing operations,
/// persistence, OCSP and export leases are behind the Application boundary.
@MainActor
final class CertificatesViewCoordinator: ObservableObject {
    @Published private(set) var isBatchChecking = false
    private let certificates: CertificateWorkspaceModel
    private let certificateCatalog: CertificateCatalogProviding
    private let platform: PlatformSystemAdapting

    init(certificates: CertificateWorkspaceModel, certificateCatalog: CertificateCatalogProviding, platform: PlatformSystemAdapting) {
        self.certificates = certificates
        self.certificateCatalog = certificateCatalog
        self.platform = platform
    }
    func signedAppsCount() -> Int { certificateCatalog.signedAppsCount() }
    func checkRevokage(for values: [CertificateRecord]) {
        values.forEach { certificates.checkDeviceStatus($0) }
        platform.notifyInfo(.localized("Checking certificates…"), systemImage: "person.text.rectangle")
    }
    func checkRevokage(for certificate: CertificateRecord) { certificates.checkDeviceStatus(certificate) }
    func refreshOCSPStatus(for certificate: CertificateRecord) { certificates.refresh(certificate) }
    func renameCertificate(_ certificate: CertificateRecord, to nickname: String) { certificates.rename(certificate, to: nickname) }
    func deleteCertificate(_ certificate: CertificateRecord) { certificates.delete(certificate) }
    func exportCertificate(_ certificate: CertificateRecord) { certificates.export(certificate) }
    func runBatchCheck(onPresentSheet: @escaping @MainActor () -> Void) {
        Task { @MainActor [weak self] in await self?.runBatchCheckAsync(onPresentSheet: onPresentSheet) }
    }
    func runBatchCheckAsync(onPresentSheet: @escaping @MainActor () -> Void) async {
        guard !isBatchChecking else { return }
        isBatchChecking = true
        defer { isBatchChecking = false }
        onPresentSheet()
        await certificates.checkAll()
        platform.notifySuccess(String.localized("Checked %lld certificates — %lld valid",
            arguments: Int64(certificates.results.count), Int64(certificates.summary.valid)), systemImage: "checkmark.seal")
    }
}
