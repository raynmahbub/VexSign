import XCTest
@testable import VexSign

@MainActor
final class CleanArchitectureLayerTests: XCTestCase {

    // MARK: - Test Doubles

    private struct FakeApp: AppInfoPresentable {
        var name: String? = "DemoApp"
        var version: String? = "1.0.0"
        var identifier: String? = "com.example.demo"
        var originalIdentifier: String? = "com.example.demo"
        var date: Date? = Date()
        var icon: String? = nil
        var uuid: String? = "demo-uuid"
        var isSigned: Bool = false
        var appDescription: String? = nil
    }

    private final class MockIncomingFiles: IncomingFilesProviding {
        var removedTemporaryPaths: [URL] = []
        func temporaryDirectory(label: String) -> URL { URL(fileURLWithPath: "/not-used/" + label) }
        func copyCoordinatedFile(from source: URL, to destination: URL, tempDirectory: URL) -> Result<Void, CoordinatedFileCopyFailure> { .success(Void()) }
        func removeTemporaryDirectory(_ url: URL) { removedTemporaryPaths.append(url) }
    }
    private final class MockRoutingDiagnostics: RoutingDiagnosticsProviding {
        func warning(_ message: String, security: Bool) {}
        func info(_ message: String) {}
        func report(_ error: Error) {}
        func userMessage(for error: Error) -> String { error.localizedDescription }
    }

    private final class MockLease {}

    private final class MockDirectInstallationProvider: DirectInstallationProviding {
        var importPackageFile: (URL) async throws -> ImportedPackageHandle = { _ in ImportedPackageHandle() }
        var performDirectInstall: (ImportedPackageHandle, Bool) throws -> Void = { _, _ in }
        var released: [ImportedPackageHandle] = []
        func currentPipelineIsContainerized() throws -> Bool { false }
        func isContainerized(_ package: ImportedPackageHandle) throws -> Bool { false }
        func enqueueDownload(_ url: URL, name: String) {}
        func acquireTemporaryWork() throws -> AnyObject { MockLease() }
        func importPackage(_ url: URL) async throws -> ImportedPackageHandle { try await importPackageFile(url) }
        func submitInstallation(_ package: ImportedPackageHandle, allowingIssues: Bool) throws {
            try performDirectInstall(package, allowingIssues)
        }
        func releaseImportedPackage(_ package: ImportedPackageHandle) { released.append(package) }
    }

    private struct MockSecurityPolicy: SecurityPolicyValidating {
        func validatePackageDownloadURL(_ url: URL) throws {
            try SecurityPolicyGateway().validatePackageDownloadURL(url)
        }

        func validateFirmwareDownloadURL(_ url: URL) throws {
            try SecurityPolicyGateway().validateFirmwareDownloadURL(url)
        }

        func validateRepositoryURL(_ url: URL) throws {
            try SecurityPolicyGateway().validateRepositoryURL(url)
        }

        func isAllowedCertificateCallbackTemplate(_ template: String) -> Bool {
            SecurityPolicyGateway().isAllowedCertificateCallbackTemplate(template)
        }

        func isAllowedPackageExtension(_ ext: String) -> Bool {
            SecurityPolicyGateway().isAllowedPackageExtension(ext)
        }

        func isAllowedTweakExtension(_ ext: String) -> Bool {
            SecurityPolicyGateway().isAllowedTweakExtension(ext)
        }
    }

    private final class MockTransferProvider: SecureTransferProviding {
        var packageURLToReturn: URL?
        var packageError: Error?
        var devicesToReturn: [FirmwareDeviceRecord] = []
        var buildsToReturn: [FirmwareBuildRecord] = []
        var hardwareIdentifier: String? = "iPhone16,1"
        var lastDownloadedURL: URL?

        func downloadValidatedPackage(from url: URL, workLabel: String, maximumBytes: Int64) async throws -> URL {
            lastDownloadedURL = url
            if let packageError { throw packageError }
            if let packageURLToReturn { return packageURLToReturn }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mock-\(UUID().uuidString).ipa")
            try Data("ipa-bytes".utf8).write(to: tmp)
            return tmp
        }

        func downloadValidatedFirmware(from url: URL, to destination: URL) async throws -> URL {
            lastDownloadedURL = url
            try Data("ipsw-bytes".utf8).write(to: destination)
            return destination
        }

        func fetchFirmwareDevices() async throws -> [FirmwareDeviceRecord] { devicesToReturn }
        func fetchFirmwareBuilds(deviceIdentifier: String) async throws -> [FirmwareBuildRecord] { buildsToReturn }
        func currentHardwareModelIdentifier() -> String? { hardwareIdentifier }
    }

    @MainActor
    private final class MockPlatformAdapter: PlatformSystemAdapting {
        var successMessages: [String] = []
        var infoMessages: [String] = []
        var errorMessages: [String] = []
        var sharedItems: [[Any]] = []
        var openedURLs: [URL] = []
        var pasteboardValue: String?
        var autoConfirmAlerts = true
        var lastConfirmTitle: String?
        var lastConfirmButtonTitle: String?
        var yesNoAlerts = 0
        var restartCount = 0

        func openExternalURL(_ url: URL) { openedURLs.append(url) }
        func pasteboardString() -> String? { pasteboardValue }
        func dismissKeyboard() {}
        func restartOrSuspendApp() { restartCount += 1 }
        func shareItems(_ items: [Any]) { sharedItems.append(items) }
        func notifySuccess(_ message: String, systemImage: String) { successMessages.append(message) }
        func notifyInfo(_ message: String, systemImage: String) { infoMessages.append(message) }
        func notifyError(_ message: String, sticky: Bool) { errorMessages.append(message) }
        func triggerHapticFeedback(success: Bool) {}

        func presentDestructiveConfirmation(title: String, message: String, onConfirm: @escaping () -> Void) {
            lastConfirmTitle = title
            if autoConfirmAlerts { onConfirm() }
        }

        func presentYesNoAlert(title: String, message: String, confirmTitle: String, onConfirm: @escaping () -> Void) {
            // The alert title and its confirm button are different strings; keep
            // both so a consent test cannot pass by checking the wrong one.
            lastConfirmTitle = title
            lastConfirmButtonTitle = confirmTitle
            yesNoAlerts += 1
            if autoConfirmAlerts { onConfirm() }
        }

        func presentErrorWithCopy(title: String, message: String) {
            errorMessages.append("\(title): \(message)")
        }
    }

    @MainActor
    private final class MockResetStore: WorkspaceResetting {
        var performedScopes: [WorkspaceResetScope] = []
        var summarySnapshot = WorkspaceCountsSummary(
            networkCacheSizeFormatted: "2 KB",
            sourcesCountText: "2 sources",
            signedAppsCountText: "3 apps",
            importedAppsCountText: "4 apps",
            tweaksCount: 5,
            certificatesCountText: "1 cert"
        )

        func currentSummary() -> WorkspaceCountsSummary { summarySnapshot }
        func perform(_ scope: WorkspaceResetScope) { performedScopes.append(scope) }
    }

    @MainActor
    private final class MockPrivacyManager: AppPrivacyManaging {
        var strictHidingEnabled = false
        var isRevealingHiddenApps = false
        var biometryDisplayName: String? = "Face ID"
        var apps: [AppPrivacyItem] = [
            AppPrivacyItem(id: "1", uuid: "u1", name: "Alpha", identifier: "com.example.alpha", version: "1.0", isSigned: true, isLocked: false, isHidden: true, bundleURL: nil),
            AppPrivacyItem(id: "2", uuid: "u2", name: "Beta", identifier: "com.example.beta", version: "2.0", isSigned: false, isLocked: true, isHidden: false, bundleURL: nil),
        ]
        var lockedIDs: Set<String> = ["u2"]
        var hiddenIDs: Set<String> = ["u1"]
        var authResult = true

        func allLibraryApps() -> [AppPrivacyItem] { apps }
        func isAppLocked(_ uuid: String) -> Bool { lockedIDs.contains(uuid) }
        func isAppHidden(_ uuid: String) -> Bool { hiddenIDs.contains(uuid) }

        func toggleAppLock(_ uuid: String) {
            if lockedIDs.contains(uuid) { lockedIDs.remove(uuid) } else { lockedIDs.insert(uuid) }
        }

        func toggleHideApp(_ uuid: String) {
            if hiddenIDs.contains(uuid) { hiddenIDs.remove(uuid) } else { hiddenIDs.insert(uuid) }
        }

        func authenticateToRevealHidden(completion: @escaping (Bool) -> Void) {
            isRevealingHiddenApps = authResult
            completion(authResult)
        }
    }

    @MainActor
    private final class MockDiagnosticsProvider: DiagnosticsProviding {
        var snapshot = DiagnosticOverviewSnapshot(
            migrationWarnings: ["Warning"],
            certificateCount: 2,
            expiringCertificateCount: 1,
            repositoryCount: 3,
            failingRepositoryCount: 1,
            staleSourceCount: 1,
            certificates: [],
            failingSourceNames: ["Broken Source"],
            recentTasks: []
        )
        var exportURL: URL?

        func currentSnapshot() -> DiagnosticOverviewSnapshot { snapshot }
        func exportDiagnosticArchiveURL() async -> URL? { exportURL }
    }

    @MainActor
    private final class MockDownloadedFilesManager: DownloadedFilesManaging {
        var stagedItems: [DownloadedFileItem] = []
        var importedCount = 0
        var importedToLibraryURLs: [URL] = []
        var stagingURL = FileManager.default.temporaryDirectory

        func listStagedPackages() -> [DownloadedFileItem] { stagedItems }
        func importFiles(_ urls: [URL], intoStaging: Bool) -> Int {
            importedCount = urls.count
            return urls.count
        }
        func importToLibrary(from stagedURL: URL) -> Bool {
            importedToLibraryURLs.append(stagedURL)
            return true
        }
        func stagingDirectoryURL() -> URL { stagingURL }
        func sharedDocumentsURL(for url: URL) -> URL? {
            URL(string: "shareddocuments://\(url.lastPathComponent)")
        }
    }

    // MARK: - Deep Link Parsing & Routing

    func testDeepLinkParserRecognizesSupportedSchemesAndRoutes() {
        let installQuery = DeepLinkCommand.parse(URL(string: "vexsign://install?url=https%3A%2F%2Fexample.com%2Fapp.ipa")!)
        XCTAssertEqual(installQuery, .downloadAndInstall(URL(string: "https://example.com/app.ipa")!, notifyDirectStarted: false))

        let directInstall = DeepLinkCommand.parse(URL(string: "vexsign://direct-install?url=https%3A%2F%2Fexample.com%2Fapp.ipa")!)
        XCTAssertEqual(directInstall, .downloadAndInstall(URL(string: "https://example.com/app.ipa")!, notifyDirectStarted: true))

        let source = DeepLinkCommand.parse(URL(string: "vexsign://source/https%3A%2F%2Frepo.example.com%2Fapps.json")!)
        XCTAssertEqual(source, .addSource("https://repo.example.com/apps.json"))

        // `feather://` is another app's scheme. Accepting it let that app drive
        // installs, certificate import and source adds through VexSign, so it is
        // neither registered nor parsed any more.
        XCTAssertEqual(DeepLinkCommand.parse(URL(string: "feather://source/https%3A%2F%2Frepo.example.com%2Fapps.json")!), .unsupported)
        XCTAssertEqual(DeepLinkCommand.parse(URL(string: "feather://install?url=https%3A%2F%2Fexample.com%2Fapp.ipa")!), .unsupported)
        XCTAssertEqual(DeepLinkCommand.parse(URL(string: "feather://import-certificate")!), .unsupported)

        let navigate = DeepLinkCommand.parse(URL(string: "vexsign://signedApps")!)
        XCTAssertEqual(navigate, .openWorkspace(.signedApps))

        let sharedTweak = DeepLinkCommand.parse(URL(string: "file:///tmp/tweak.dylib")!)
        XCTAssertEqual(sharedTweak, .importTweakFile(URL(string: "file:///tmp/tweak.dylib")!))

        // A backup handed over from Files/AirDrop must reach the restore offer, not
        // the tweak manager and not `.unsupported`.
        let sharedBackup = DeepLinkCommand.parse(URL(string: "file:///tmp/VexSign-Backup.vexbackup")!)
        XCTAssertEqual(sharedBackup, .openBackupFile(URL(string: "file:///tmp/VexSign-Backup.vexbackup")!))

        // Extension matching is case-insensitive on the same path used by the document type.
        let upperBackup = DeepLinkCommand.parse(URL(string: "file:///tmp/BACKUP.VEXBACKUP")!)
        XCTAssertEqual(upperBackup, .openBackupFile(URL(string: "file:///tmp/BACKUP.VEXBACKUP")!))

        // A file literally named `.vexbackup` has no extension in URL terms — the dot
        // starts the name — so it is not a backup and never a workspace command. iOS
        // cannot hand over a nameless file anyway; what matters is that this is
        // decided, not that it crashes or resolves to some other route.
        let unnamedBackup = DeepLinkCommand.parse(URL(string: "file:///.vexbackup")!)
        XCTAssertEqual(unnamedBackup, .unsupported)

        let launchQuery = DeepLinkCommand.parse(URL(string: "vexsign://launch?bundleId=com.example.app")!)
        XCTAssertEqual(launchQuery, .launchApp(bundleIdentifier: "com.example.app"))

        let launchPath = DeepLinkCommand.parse(URL(string: "vexsign://launch/com.example.app")!)
        XCTAssertEqual(launchPath, .launchApp(bundleIdentifier: "com.example.app"))

        let launchEmpty = DeepLinkCommand.parse(URL(string: "vexsign://launch?bundleId=%20")!)
        XCTAssertEqual(launchEmpty, .unsupported)

        let invalid = DeepLinkCommand.parse(URL(string: "unknown://navigate/home")!)
        XCTAssertEqual(invalid, .unsupported)
    }

    /// The certificate link is the only command that carries a credential, and it
    /// was the one branch with no test at all.
    func testDeepLinkParserDecodesCertificateLinkAndRejectsIncompleteOnes() {
        let complete = DeepLinkCommand.parse(
            URL(string: "vexsign://import-certificate?p12=cDEy&mobileprovision=bW9i&password=Y29ycmVjdA%3D%3D")!
        )
        XCTAssertEqual(
            complete,
            .importCertificate(p12Base64: "cDEy", provisionBase64: "bW9i", password: "correct")
        )

        // A link without a decodable password cannot be acted on: it must not fall
        // through to "unsupported" (which would look like a routing miss) and it
        // must never be treated as a valid import with an empty password.
        let missingPassword = DeepLinkCommand.parse(
            URL(string: "vexsign://import-certificate?p12=cDEy&mobileprovision=bW9i")!
        )
        XCTAssertEqual(missingPassword, .invalidCertificateImport)

        let notBase64 = DeepLinkCommand.parse(
            URL(string: "vexsign://import-certificate?p12=cDEy&mobileprovision=bW9i&password=not-base64!")!
        )
        XCTAssertEqual(notBase64, .invalidCertificateImport)

        // Case-insensitive matching is the same rule the other hosts use.
        let upper = DeepLinkCommand.parse(
            URL(string: "VEXSIGN://IMPORT-CERTIFICATE?p12=cDEy&mobileprovision=bW9i&password=Y29ycmVjdA%3D%3D")!
        )
        XCTAssertEqual(upper, .importCertificate(p12Base64: "cDEy", provisionBase64: "bW9i", password: "correct"))

        let export = DeepLinkCommand.parse(
            URL(string: "vexsign://export-certificate?callback_template=myapp%3A%2F%2Fcb%3Fp12%3D%7Bp12%7D")!
        )
        XCTAssertEqual(export, .exportCertificate(callbackTemplate: "myapp://cb?p12={p12}"))
    }

    func testCertificateLinkStagesValidatesAndInstallsOnlyAfterConsent() {
        let platform = MockPlatformAdapter()
        let incoming = MockIncomingFiles()
        var decodedExtensions: [String] = []
        var validatedPasswords: [String] = []
        var imported: (p12: String, provision: String, password: String)?

        let router = DeepLinkRouterUseCase(
            securityPolicy: SecurityPolicyGateway(),
            platform: platform,
            incomingFiles: incoming,
            diagnostics: MockRoutingDiagnostics(),
            decodeBase64File: { _, ext in
                decodedExtensions.append(ext)
                return URL(fileURLWithPath: "/tmp/staged" + ext)
            },
            validateCertificatePassword: { _, password, _ in
                validatedPasswords.append(password)
                return true
            },
            importCertificateFiles: { p12, provision, password, completion in
                imported = (p12.path, provision.path, password)
                completion(nil)
            },
            exportCertificateTemplate: { _ in },
            addTweakRepository: { _ in 0 },
            openRepositoryApp: { _, _, _ in },
            navigateWorkspace: { _ in },
            addSource: { _ in },
            startPackageDownload: { _ in },
            acquireWorkLease: { MockLease() },
            importStagedPackage: { _, completion in completion(nil) },
            extractTweakArchive: { _ in (FileManager.default.temporaryDirectory, []) },
            addTweakFile: { _, _ in true }
        )

        router.handle(
            URL(string: "vexsign://import-certificate?p12=cDEy&mobileprovision=bW9i&password=Y29ycmVjdA%3D%3D")!
        )

        XCTAssertEqual(decodedExtensions, [".p12", ".mobileprovision"])
        XCTAssertEqual(validatedPasswords, ["correct"], "the link's password is validated before the prompt")

        // Consent first: exactly one prompt, and the identity is installed only
        // after the user taps the confirm button.
        XCTAssertEqual(platform.yesNoAlerts, 1)
        XCTAssertEqual(platform.lastConfirmButtonTitle, "Import")
        XCTAssertEqual(imported?.password, "correct")
        XCTAssertEqual(imported?.p12, "/tmp/staged.p12")

        // The staged plaintext private key is removed once the outcome is known.
        XCTAssertEqual(
            Set(incoming.removedTemporaryPaths.map(\.lastPathComponent)),
            ["staged.p12", "staged.mobileprovision"]
        )
        XCTAssertTrue(platform.errorMessages.isEmpty)
    }

    func testDeclinedCertificateLinkInstallsNothing() {
        let platform = MockPlatformAdapter()
        platform.autoConfirmAlerts = false
        var importCalls = 0

        let router = DeepLinkRouterUseCase(
            securityPolicy: SecurityPolicyGateway(),
            platform: platform,
            incomingFiles: MockIncomingFiles(),
            diagnostics: MockRoutingDiagnostics(),
            decodeBase64File: { _, ext in URL(fileURLWithPath: "/tmp/staged" + ext) },
            validateCertificatePassword: { _, _, _ in true },
            importCertificateFiles: { _, _, _, completion in
                importCalls += 1
                completion(nil)
            },
            exportCertificateTemplate: { _ in },
            addTweakRepository: { _ in 0 },
            openRepositoryApp: { _, _, _ in },
            navigateWorkspace: { _ in },
            addSource: { _ in },
            startPackageDownload: { _ in },
            acquireWorkLease: { MockLease() },
            importStagedPackage: { _, completion in completion(nil) },
            extractTweakArchive: { _ in (FileManager.default.temporaryDirectory, []) },
            addTweakFile: { _, _ in true }
        )

        router.handle(
            URL(string: "vexsign://import-certificate?p12=cDEy&mobileprovision=bW9i&password=Y29ycmVjdA%3D%3D")!
        )

        XCTAssertEqual(platform.yesNoAlerts, 1)
        XCTAssertEqual(importCalls, 0, "declining the prompt must not install a signing identity")
        XCTAssertTrue(platform.errorMessages.isEmpty)
    }

    func testMalformedCertificateLinkPromptsForNothing() {
        let platform = MockPlatformAdapter()
        var decodeCalls = 0

        let router = DeepLinkRouterUseCase(
            securityPolicy: SecurityPolicyGateway(),
            platform: platform,
            incomingFiles: MockIncomingFiles(),
            diagnostics: MockRoutingDiagnostics(),
            decodeBase64File: { _, ext in
                decodeCalls += 1
                return URL(fileURLWithPath: "/tmp/staged" + ext)
            },
            validateCertificatePassword: { _, _, _ in true },
            importCertificateFiles: { _, _, _, completion in completion(nil) },
            exportCertificateTemplate: { _ in },
            addTweakRepository: { _ in 0 },
            openRepositoryApp: { _, _, _ in },
            navigateWorkspace: { _ in },
            addSource: { _ in },
            startPackageDownload: { _ in },
            acquireWorkLease: { MockLease() },
            importStagedPackage: { _, completion in completion(nil) },
            extractTweakArchive: { _ in (FileManager.default.temporaryDirectory, []) },
            addTweakFile: { _, _ in true }
        )

        router.handle(URL(string: "vexsign://import-certificate?p12=cDEy&mobileprovision=bW9i")!)

        XCTAssertEqual(decodeCalls, 0, "nothing is staged for a link that cannot be acted on")
        XCTAssertEqual(platform.yesNoAlerts, 0, "a malformed link must not raise a consent dialog")
        XCTAssertTrue(platform.errorMessages.isEmpty)
        XCTAssertTrue(platform.infoMessages.isEmpty)
    }

    func testCertificateExportCallbackIsBlockedUnlessTheTemplateIsOurs() {
        let platform = MockPlatformAdapter()
        var exported: [String] = []

        let router = DeepLinkRouterUseCase(
            securityPolicy: SecurityPolicyGateway(),
            platform: platform,
            incomingFiles: MockIncomingFiles(),
            diagnostics: MockRoutingDiagnostics(),
            decodeBase64File: { _, _ in nil },
            validateCertificatePassword: { _, _, _ in false },
            importCertificateFiles: { _, _, _, completion in completion(nil) },
            exportCertificateTemplate: { exported.append($0) },
            addTweakRepository: { _ in 0 },
            openRepositoryApp: { _, _, _ in },
            navigateWorkspace: { _ in },
            addSource: { _ in },
            startPackageDownload: { _ in },
            acquireWorkLease: { MockLease() },
            importStagedPackage: { _, completion in completion(nil) },
            extractTweakArchive: { _ in (FileManager.default.temporaryDirectory, []) },
            addTweakFile: { _, _ in true }
        )

        router.handle(
            URL(string: "vexsign://export-certificate?callback_template=https%3A%2F%2Fevil.example%2Fcollect")!
        )
        XCTAssertTrue(exported.isEmpty, "an https callback would hand the .p12 to the sender")

        router.handle(
            URL(string: "vexsign://export-certificate?callback_template=myapp%3A%2F%2Fcb%3Fp12%3D%7Bp12%7D")!
        )
        XCTAssertEqual(exported, ["myapp://cb?p12={p12}"])
    }

    func testDeepLinkRouterRejectsInsecureInstallURLAndRoutesValidDestination() {
        let platform = MockPlatformAdapter()
        var navigated: WorkspaceDestination?
        var startedURL: URL?
        var launchedBundleID: String?

        let router = DeepLinkRouterUseCase(
            securityPolicy: SecurityPolicyGateway(),
            platform: platform,
            incomingFiles: MockIncomingFiles(),
            diagnostics: MockRoutingDiagnostics(),
            decodeBase64File: { _, _ in nil },
            validateCertificatePassword: { _, _, _ in false },
            importCertificateFiles: { _, _, _, completion in completion(nil) },
            exportCertificateTemplate: { _ in },
            addTweakRepository: { _ in 0 },
            openRepositoryApp: { _, _, _ in },
            navigateWorkspace: { navigated = $0 },
            launchInstalledApp: { launchedBundleID = $0 },
            addSource: { _ in },
            startPackageDownload: { startedURL = $0 },
            acquireWorkLease: { MockLease() },
            importStagedPackage: { _, completion in completion(nil) },
            extractTweakArchive: { _ in (FileManager.default.temporaryDirectory, []) },
            addTweakFile: { _, _ in true }
        )

        router.handle(URL(string: "vexsign://install?url=http%3A%2F%2F127.0.0.1%2Fevil.ipa")!)
        XCTAssertNil(startedURL)
        XCTAssertFalse(platform.errorMessages.isEmpty)

        router.handle(URL(string: "vexsign://install?url=https%3A%2F%2Fcdn.example.com%2Fapp.ipa")!)
        XCTAssertEqual(startedURL, URL(string: "https://cdn.example.com/app.ipa"))

        router.handle(URL(string: "vexsign://downloads")!)
        XCTAssertEqual(navigated, .downloads)

        router.handle(URL(string: "vexsign://launch?bundleId=com.example.app")!)
        XCTAssertEqual(launchedBundleID, "com.example.app")
    }

    // MARK: - Security Policy Gateway

    func testSecurityPolicyGatewayBlocksPrivateNetworkAndInsecureFirmwareURLs() {
        let policy = SecurityPolicyGateway()
        XCTAssertThrowsError(try policy.validatePackageDownloadURL(URL(string: "http://127.0.0.1/app.ipa")!))
        XCTAssertThrowsError(try policy.validatePackageDownloadURL(URL(string: "ftp://example.com/app.ipa")!))
        XCTAssertNoThrow(try policy.validatePackageDownloadURL(URL(string: "https://example.com/app.ipa")!))

        XCTAssertThrowsError(try policy.validateFirmwareDownloadURL(URL(string: "http://updates.cdn-apple.com/restore.ipsw")!))
        XCTAssertNoThrow(try policy.validateFirmwareDownloadURL(URL(string: "https://updates.cdn-apple.com/restore.ipsw")!))

        XCTAssertFalse(policy.isAllowedCertificateCallbackTemplate("javascript://alert(1)"))
        XCTAssertFalse(policy.isAllowedCertificateCallbackTemplate("https://evil.example/cb"))
        XCTAssertTrue(policy.isAllowedCertificateCallbackTemplate("myapp://callback?p12={p12}"))
    }

    func testCertificateCallbackTemplateRequiresAWellFormedScheme() {
        let policy = SecurityPolicyGateway()
        // A template arrives straight from a deep link, so the text before `://` has to actually be
        // an RFC 3986 scheme. Otherwise what is approved here is not what `URL(string:)` resolves
        // once the certificate and its password have been substituted into it.
        XCTAssertFalse(policy.isAllowedCertificateCallbackTemplate("foo:http://evil.example/cb"))
        XCTAssertFalse(policy.isAllowedCertificateCallbackTemplate("https\n://evil.example/cb"))
        XCTAssertFalse(policy.isAllowedCertificateCallbackTemplate("1app://callback"))
        XCTAssertFalse(policy.isAllowedCertificateCallbackTemplate("://callback"))
        XCTAssertTrue(policy.isAllowedCertificateCallbackTemplate("my-app+1.example://callback"))
        // `_` is the one character accepted beyond RFC 3986: it cannot delimit a URL, so it does not
        // weaken the guarantee above, and real registered schemes use it.
        XCTAssertTrue(policy.isAllowedCertificateCallbackTemplate("my_app://callback"))
    }

    func testCertificateCallbackDenyListIsTheSharedOne() {
        // Two layers enforce this and they read one list: the deep-link router checks the template
        // before substitution, `CertificateManagementService` re-checks the resolved URL after it.
        let policy = SecurityPolicyGateway()
        for scheme in CertificateCallbackPolicy.disallowedSchemes {
            XCTAssertFalse(policy.isAllowedCertificateCallbackTemplate("\(scheme)://callback"))
            XCTAssertFalse(policy.isAllowedCertificateCallbackTemplate("\(scheme.uppercased())://callback"))
        }
    }

    // MARK: - Reset Use Case

    func testWorkspaceResetUseCaseConfirmationAndScopes() {
        let store = MockResetStore()
        let platform = MockPlatformAdapter()
        let useCase = WorkspaceResetUseCase(resetStore: store, platform: platform)

        platform.autoConfirmAlerts = false
        useCase.requestConfirmedReset(title: "Reset Work Cache", scope: .workCache)
        XCTAssertTrue(store.performedScopes.isEmpty)
        XCTAssertEqual(platform.restartCount, 0)

        platform.autoConfirmAlerts = true
        useCase.requestConfirmedReset(title: "Reset Settings", scope: .userDefaults)
        XCTAssertEqual(store.performedScopes, [.userDefaults])
        XCTAssertEqual(platform.restartCount, 1)
    }

    // MARK: - Direct Package Install Use Case

    func testDirectPackageInstallUseCaseConfirmAnywayAndCleanup() async throws {
        let transfer = MockTransferProvider()
        var directInstallCalls = 0
        var allowIssuesValues: [Bool] = []
        let installation = MockDirectInstallationProvider()
        installation.importPackageFile = { url in
            try? FileManager.default.removeItem(at: url)
            return ImportedPackageHandle()
        }
        installation.performDirectInstall = { _, allowingIssues in
            directInstallCalls += 1
            allowIssuesValues.append(allowingIssues)
            if !allowingIssues {
                throw DirectInstallationRequestError.verificationFailed(["Unsigned binary"])
            }
        }
        let useCase = DirectPackageInstallUseCase(
            securityPolicy: MockSecurityPolicy(),
            transferService: transfer,
            maximumPackageBytes: 1024,
            installation: installation
        )

        let outcome = try await useCase.execute(
            urlString: "https://cdn.example.com/demo.ipa",
            mode: .installWithoutSigning,
            onStatus: { _ in }
        )
        XCTAssertEqual(outcome, .needsIssueConfirmation(["Unsigned binary"]))
        XCTAssertEqual(directInstallCalls, 1)

        let confirmed = try useCase.confirmPendingInstall()
        XCTAssertEqual(confirmed, .submittedForInstallation)
        XCTAssertEqual(allowIssuesValues, [false, true])
        XCTAssertEqual(installation.released.count, 1)

        // Second confirmation without pending payload throws
        XCTAssertThrowsError(try useCase.confirmPendingInstall())
    }

    // MARK: - Firmware Use Case

    func testFirmwareDownloadUseCaseValidatesHTTPSAndSavesIntoFirmwareDirectory() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("VexSignFirmwareTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let transfer = MockTransferProvider()
        var keepAliveStopped = false
        let useCase = FirmwareDownloadUseCase(
            securityPolicy: SecurityPolicyGateway(),
            transferService: transfer,
            firmwareDirectory: tempDir,
            fileExists: { FileManager.default.fileExists(atPath: $0.path) },
            startKeepAlive: {
                return { keepAliveStopped = true }
            }
        )

        let insecureBuild = FirmwareBuildRecord(
            identifier: "iPhone16,1",
            version: "18.0",
            buildID: "22A1",
            fileSize: 1024,
            downloadURL: URL(string: "http://updates.cdn-apple.com/test.ipsw"),
            isStillSigned: true,
            formattedSize: "1 KB",
            filename: "test.ipsw"
        )
        do {
            _ = try await useCase.download(insecureBuild)
            XCTFail("Expected insecure firmware download to fail")
        } catch {
            XCTAssertFalse(keepAliveStopped)
        }

        let secureBuild = FirmwareBuildRecord(
            identifier: "iPhone16,1",
            version: "18.0",
            buildID: "22A1",
            fileSize: 1024,
            downloadURL: URL(string: "https://updates.cdn-apple.com/test.ipsw"),
            isStillSigned: true,
            formattedSize: "1 KB",
            filename: "test.ipsw"
        )
        let saved = try await useCase.download(secureBuild)
        XCTAssertTrue(keepAliveStopped)
        XCTAssertEqual(saved.lastPathComponent, "test.ipsw")
        XCTAssertNotNil(useCase.downloadedFileURL(for: secureBuild))
    }

    // MARK: - Presentation ViewModels

    func testPrivacyDiagnosticsAndDownloadsViewModels() {
        let privacy = MockPrivacyManager()
        let hiddenVM = HiddenAppsVaultViewModel(privacyManager: privacy)
        XCTAssertEqual(hiddenVM.hiddenCount, 1)
        hiddenVM.requestAccess()
        XCTAssertTrue(hiddenVM.isAuthenticated)
        hiddenVM.strictHidingEnabled = true
        XCTAssertTrue(privacy.strictHidingEnabled)

        let lockVM = SpecificAppLockViewModel(privacyManager: privacy)
        XCTAssertEqual(lockVM.lockedCount, 1)
        lockVM.toggleAppLock("u1")
        XCTAssertTrue(lockVM.isAppLocked("u1"))

        let diagProvider = MockDiagnosticsProvider()
        let platform = MockPlatformAdapter()
        let diagVM = DiagnosticsCenterViewModel(provider: diagProvider, platform: platform)
        XCTAssertEqual(diagVM.snapshot.certificateCount, 2)

        let files = MockDownloadedFilesManager()
        let downloadsVM = DownloadsTabViewModel(
            downloadedFiles: files,
            securityPolicy: SecurityPolicyGateway(),
            platform: platform,
            startDownloadHandler: { _ in true }
        )
        platform.pasteboardValue = "https://example.com/pkg.ipa"
        XCTAssertEqual(downloadsVM.initialURLFromPasteboard(currentText: ""), "https://example.com/pkg.ipa")
        XCTAssertFalse(downloadsVM.startDownload(fromRawURL: "http://127.0.0.1/bad.ipa"))
        XCTAssertTrue(downloadsVM.startDownload(fromRawURL: "https://example.com/good.ipa"))
    }
}
