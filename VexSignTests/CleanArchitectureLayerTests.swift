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

    private final class MockLease {}

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
            lastConfirmTitle = title
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
        func exportDiagnosticArchiveURL() -> URL? { exportURL }
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

        let source = DeepLinkCommand.parse(URL(string: "feather://source/https%3A%2F%2Frepo.example.com%2Fapps.json")!)
        XCTAssertEqual(source, .addSource("https://repo.example.com/apps.json"))

        let navigate = DeepLinkCommand.parse(URL(string: "vexsign://signedApps")!)
        XCTAssertEqual(navigate, .openWorkspace(.signedApps))

        let sharedTweak = DeepLinkCommand.parse(URL(string: "file:///tmp/tweak.dylib")!)
        XCTAssertEqual(sharedTweak, .importTweakFile(URL(string: "file:///tmp/tweak.dylib")!))

        let launchQuery = DeepLinkCommand.parse(URL(string: "vexsign://launch?bundleId=com.example.app")!)
        XCTAssertEqual(launchQuery, .launchApp(bundleIdentifier: "com.example.app"))

        let launchPath = DeepLinkCommand.parse(URL(string: "vexsign://launch/com.example.app")!)
        XCTAssertEqual(launchPath, .launchApp(bundleIdentifier: "com.example.app"))

        let launchEmpty = DeepLinkCommand.parse(URL(string: "vexsign://launch?bundleId=%20")!)
        XCTAssertEqual(launchEmpty, .unsupported)

        let invalid = DeepLinkCommand.parse(URL(string: "unknown://navigate/home")!)
        XCTAssertEqual(invalid, .unsupported)
    }

    func testDeepLinkRouterRejectsInsecureInstallURLAndRoutesValidDestination() {
        let platform = MockPlatformAdapter()
        var navigated: WorkspaceDestination?
        var startedURL: URL?
        var launchedBundleID: String?

        let router = DeepLinkRouterUseCase(
            securityPolicy: SecurityPolicyGateway(),
            platform: platform,
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
        let fakeApp = FakeApp()

        let useCase = DirectPackageInstallUseCase(
            securityPolicy: MockSecurityPolicy(),
            transferService: transfer,
            isContainerizedPipeline: { false },
            isContainerizedAppPipeline: { _ in false },
            enqueueDownload: { _, _ in },
            acquireTemporaryWork: { MockLease() },
            importPackageFile: { url in
                try? FileManager.default.removeItem(at: url)
                return fakeApp
            },
            performDirectInstall: { _, allowingIssues in
                directInstallCalls += 1
                allowIssuesValues.append(allowingIssues)
                if !allowingIssues {
                    throw DirectInstaller.DirectInstallError.verificationFailed(["Unsigned binary"])
                }
            }
        )

        let outcome = try await useCase.execute(
            urlString: "https://cdn.example.com/demo.ipa",
            mode: .installWithoutSigning,
            onStatus: { _ in }
        )
        XCTAssertEqual(outcome, .needsIssueConfirmation(["Unsigned binary"]))
        XCTAssertEqual(directInstallCalls, 1)

        let confirmed = try useCase.confirmPendingInstall()
        XCTAssertEqual(confirmed, .installedDirectly)
        XCTAssertEqual(allowIssuesValues, [false, true])

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
