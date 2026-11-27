import Foundation
import XCTest
@testable import VexSign

/// A certificate link stages a `.p12` (a private key) before asking for consent.
/// Declining must be a reported decision, not a leaked staging file.
@MainActor
final class CertificateLinkConsentCleanupTests: XCTestCase {
    @MainActor
    private final class StubPlatform: PlatformSystemAdapting {
        var cancel: (() -> Void)?
        var confirm: (() -> Void)?
        var consentRequests = 0

        func openExternalURL(_ url: URL) {}
        func pasteboardString() -> String? { nil }
        func dismissKeyboard() {}
        func restartOrSuspendApp() {}
        func shareItems(_ items: [Any]) {}
        func notifySuccess(_ message: String, systemImage: String) {}
        func notifyInfo(_ message: String, systemImage: String) {}
        func notifyError(_ message: String, sticky: Bool) {}
        func presentDestructiveConfirmation(title: String, message: String, onConfirm: @escaping () -> Void) {}
        func presentYesNoAlert(title: String, message: String, confirmTitle: String, onConfirm: @escaping () -> Void) {}
        func presentErrorWithCopy(title: String, message: String) {}
        func triggerHapticFeedback(success: Bool) {}

        func presentImportConsentAlert(
            title: String,
            message: String,
            confirmTitle: String,
            onConfirm: @escaping () -> Void,
            onCancel: @escaping () -> Void
        ) {
            consentRequests += 1
            confirm = onConfirm
            cancel = onCancel
        }
    }

    @MainActor
    private final class StubIncomingFiles: IncomingFilesProviding {
        var removed: [String] = []

        func temporaryDirectory(label: String) -> URL { FileManager.default.temporaryDirectory }
        func copyCoordinatedFile(
            from source: URL,
            to destination: URL,
            tempDirectory: URL
        ) -> Result<Void, CoordinatedFileCopyFailure> {
            .failure(CoordinatedFileCopyFailure(message: "certificate links do not copy local files"))
        }
        func removeTemporaryDirectory(_ url: URL) { removed.append(url.path) }
    }

    @MainActor
    private final class StubDiagnostics: RoutingDiagnosticsProviding {
        func warning(_ message: String, security: Bool) {}
        func info(_ message: String) {}
        func report(_ error: Error) {}
        func userMessage(for error: Error) -> String { "error" }
    }

    private func makeRouter(
        platform: StubPlatform,
        incoming: StubIncomingFiles,
        onImport: @escaping () -> Void
    ) -> DeepLinkRouterUseCase {
        DeepLinkRouterUseCase(
            securityPolicy: SecurityPolicyGateway(),
            platform: platform,
            incomingFiles: incoming,
            diagnostics: StubDiagnostics(),
            decodeBase64File: { _, ext in URL(fileURLWithPath: "/tmp/staged" + ext) },
            validateCertificatePassword: { _, _, _ in true },
            importCertificateFiles: { _, _, _, completion in
                onImport()
                completion(nil)
            },
            exportCertificateTemplate: { _ in },
            addTweakRepository: { _ in 0 },
            openRepositoryApp: { _, _, _ in },
            navigateWorkspace: { _ in },
            addSource: { _ in },
            startPackageDownload: { _ in },
            acquireWorkLease: { NSObject() },
            importStagedPackage: { _, completion in completion(nil) },
            extractTweakArchive: { _ in (FileManager.default.temporaryDirectory, []) },
            addTweakFile: { _, _ in true }
        )
    }

    func testDecliningCertificateImportRemovesStagedKeyAndProfile() {
        let platform = StubPlatform()
        let incoming = StubIncomingFiles()
        var imports = 0
        let router = makeRouter(platform: platform, incoming: incoming, onImport: { imports += 1 })

        router.handle(URL(string: "vexsign://import-certificate?p12=cDEy&mobileprovision=bW9i&password=cGFzcw%3D%3D")!)

        XCTAssertEqual(platform.consentRequests, 1)
        XCTAssertTrue(incoming.removed.isEmpty, "files stay staged until the user decides")
        platform.cancel?()
        XCTAssertEqual(imports, 0)
        XCTAssertEqual(
            Set(incoming.removed),
            Set(["/tmp/staged.p12", "/tmp/staged.mobileprovision"])
        )
    }

    func testConfirmingCertificateImportStillCleansUpAfterCompletion() {
        let platform = StubPlatform()
        let incoming = StubIncomingFiles()
        var imports = 0
        let router = makeRouter(platform: platform, incoming: incoming, onImport: { imports += 1 })

        router.handle(URL(string: "vexsign://import-certificate?p12=cDEy&mobileprovision=bW9i&password=cGFzcw%3D%3D")!)
        platform.confirm?()

        XCTAssertEqual(imports, 1)
        XCTAssertEqual(
            Set(incoming.removed),
            Set(["/tmp/staged.p12", "/tmp/staged.mobileprovision"])
        )
    }
}
