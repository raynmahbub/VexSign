import Foundation
import NimbleExtensions

// MARK: - Diagnostics Center ViewModel

@MainActor
final class DiagnosticsCenterViewModel: ObservableObject {
    @Published private(set) var snapshot = DiagnosticOverviewSnapshot(
        migrationWarnings: [],
        certificateCount: 0,
        expiringCertificateCount: 0,
        repositoryCount: 0,
        failingRepositoryCount: 0,
        staleSourceCount: 0,
        certificates: [],
        failingSourceNames: [],
        recentTasks: []
    )
    @Published private(set) var isExporting = false
    /// Real checks from `SecurityDiagnosticsService`, not a stored score. An empty
    /// array means no security provider was injected (test doubles and previews).
    @Published private(set) var securityChecks: [SecurityCheck] = []

    private let provider: DiagnosticsProviding
    private let platform: PlatformSystemAdapting
    private let securityProvider: SecurityDiagnosticsProviding?

    init(
        provider: DiagnosticsProviding,
        platform: PlatformSystemAdapting,
        securityProvider: SecurityDiagnosticsProviding? = nil
    ) {
        self.provider = provider
        self.platform = platform
        self.securityProvider = securityProvider
        refresh()
    }

    func refresh() {
        snapshot = provider.currentSnapshot()
        securityChecks = securityProvider?.checks() ?? []
    }

    func exportDiagnostics() {
        guard !isExporting else { return }
        isExporting = true
        Task { @MainActor in
            let url = await provider.exportDiagnosticArchiveURL()
            isExporting = false
            if let url {
                platform.shareItems([url])
            } else {
                platform.notifyError(.localized("Could not create the diagnostics bundle."), sticky: false)
            }
        }
    }
}

// MARK: - Hidden Apps Vault ViewModel

@MainActor
final class HiddenAppsVaultViewModel: ObservableObject {
    @Published private(set) var apps: [AppPrivacyItem] = []
    @Published private(set) var isAuthenticated = false
    @Published var searchText = ""

    private let privacyManager: AppPrivacyManaging

    init(privacyManager: AppPrivacyManaging) {
        self.privacyManager = privacyManager
        reload()
    }

    var strictHidingEnabled: Bool {
        get { privacyManager.strictHidingEnabled }
        set {
            privacyManager.strictHidingEnabled = newValue
            objectWillChange.send()
        }
    }

    var biometryDisplayName: String? {
        privacyManager.biometryDisplayName
    }

    var filteredApps: [AppPrivacyItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return apps }
        return apps.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.identifier.localizedCaseInsensitiveContains(query)
        }
    }

    var hiddenCount: Int {
        apps.filter(\.isHidden).count
    }

    func reload() {
        apps = privacyManager.allLibraryApps()
    }

    func isAppHidden(_ uuid: String) -> Bool {
        privacyManager.isAppHidden(uuid)
    }

    func toggleHideApp(_ uuid: String) {
        privacyManager.toggleHideApp(uuid)
        reload()
    }

    func requestAccess() {
        privacyManager.authenticateToRevealHidden { [weak self] success in
            self?.isAuthenticated = success
            if success {
                self?.reload()
            }
        }
    }
}

// MARK: - Specific App Lock ViewModel

@MainActor
final class SpecificAppLockViewModel: ObservableObject {
    @Published private(set) var apps: [AppPrivacyItem] = []
    @Published var searchText = ""

    private let privacyManager: AppPrivacyManaging

    init(privacyManager: AppPrivacyManaging) {
        self.privacyManager = privacyManager
        reload()
    }

    var filteredApps: [AppPrivacyItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return apps }
        return apps.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.identifier.localizedCaseInsensitiveContains(query)
        }
    }

    var lockedCount: Int {
        apps.filter(\.isLocked).count
    }

    func reload() {
        apps = privacyManager.allLibraryApps()
    }

    func isAppLocked(_ uuid: String) -> Bool {
        privacyManager.isAppLocked(uuid)
    }

    func toggleAppLock(_ uuid: String) {
        privacyManager.toggleAppLock(uuid)
        reload()
    }
}

// MARK: - Favorites & Auto Updates ViewModel

@MainActor
final class FavoritesAutoUpdatesViewModel: ObservableObject {
    @Published private(set) var certificateOptions: [CertificateOptionItem] = []
    @Published private(set) var apps: [AppPrivacyItem] = []

    private let certificateCatalog: CertificateCatalogProviding
    private let privacyManager: AppPrivacyManaging

    init(
        certificateCatalog: CertificateCatalogProviding,
        privacyManager: AppPrivacyManaging
    ) {
        self.certificateCatalog = certificateCatalog
        self.privacyManager = privacyManager
        refresh()
    }

    func refresh() {
        certificateOptions = certificateCatalog.certificateOptions()
        apps = privacyManager.allLibraryApps()
    }
}
