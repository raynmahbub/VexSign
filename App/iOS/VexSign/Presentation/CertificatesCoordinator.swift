import Foundation
import UIKit
import NimbleExtensions

/// Coordinates certificate list operations (health counts, revocation checks, batch checks,
/// safe export with temporary lease cleanup, renaming, and undoable removal) outside `CertificatesView`.
@MainActor
final class CertificatesViewCoordinator: ObservableObject {
    @Published private(set) var isBatchChecking = false

    private let certificateCatalog: CertificateCatalogProviding
    private let platform: PlatformSystemAdapting

    init(
        certificateCatalog: CertificateCatalogProviding,
        platform: PlatformSystemAdapting
    ) {
        self.certificateCatalog = certificateCatalog
        self.platform = platform
    }

    func signedAppsCount() -> Int {
        certificateCatalog.signedAppsCount()
    }

    func checkRevokage(for certificates: [CertificatePair]) {
        for cert in certificates {
            Storage.shared.revokagedCertificate(for: cert)
        }
        platform.notifyInfo(.localized("Checking certificates…"), systemImage: "person.text.rectangle")
    }

    func checkRevokage(for cert: CertificatePair) {
        Storage.shared.revokagedCertificate(for: cert)
    }

    func refreshOCSPStatus(for cert: CertificatePair) {
        CertificateStatusManager.shared.refreshStatus(for: cert)
    }

    func renameCertificate(_ cert: CertificatePair, to nickname: String) {
        cert.nickname = nickname.isEmpty ? nil : nickname
        Storage.shared.saveContext()
    }

    func deleteCertificate(_ cert: CertificatePair) {
        CertificateRemoval.delete(cert)
    }

    func exportCertificate(_ cert: CertificatePair) {
        let workLease: AppOperationRegistry.Lease
        do {
            workLease = try AppOperationRegistry.shared.acquireTemporaryWork()
        } catch {
            platform.notifyError(error.localizedDescription, sticky: false)
            return
        }

        guard let zip = CertificateExporter.makeZip(for: cert) else {
            platform.notifyError(.localized("Couldn't export certificate"), sticky: false)
            return
        }

        guard let presenter = UIApplication.topViewController() else {
            cleanupExportDirectory(at: zip)
            platform.notifyError(.localized("Couldn't export certificate"), sticky: false)
            return
        }

        let controller = UIActivityViewController(activityItems: [zip], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            defer { withExtendedLifetime(workLease) {} }
            do {
                try FileManager.default.removeItem(at: zip.deletingLastPathComponent())
            } catch {
                SubsystemDiagnosticsLog.errorMessage(
                    "Could not remove certificate export: \(error.localizedDescription)",
                    subsystem: .certificates
                )
            }
        }
        if let popover = controller.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(
                x: presenter.view.bounds.midX,
                y: presenter.view.bounds.midY,
                width: 0,
                height: 0
            )
            popover.permittedArrowDirections = []
        }
        presenter.present(controller, animated: true)
    }

    func runBatchCheck(onPresentSheet: @escaping () -> Void) {
        Task { @MainActor [weak self] in
            await self?.runBatchCheckAsync(onPresentSheet: onPresentSheet)
        }
    }

    func runBatchCheckAsync(onPresentSheet: @escaping () -> Void) async {
        guard !isBatchChecking else { return }
        isBatchChecking = true
        onPresentSheet()

        await BatchCertChecker.shared.checkAll()
        let checked = BatchCertChecker.shared.results.count
        let valid = BatchCertChecker.shared.summary.valid
        isBatchChecking = false
        platform.notifySuccess(
            String.localized("Checked %lld certificates — %lld valid", arguments: Int64(checked), Int64(valid)),
            systemImage: "checkmark.seal"
        )
    }

    private func cleanupExportDirectory(at zipURL: URL) {
        do {
            try FileManager.default.removeItem(at: zipURL.deletingLastPathComponent())
        } catch {
            SubsystemDiagnosticsLog.errorMessage(
                "Could not remove certificate export: \(error.localizedDescription)",
                subsystem: .certificates
            )
        }
    }
}
