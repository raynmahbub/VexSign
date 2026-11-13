//
//  HomeView.swift
//  VexSign
//
//  The Home tab adapts to the selected appearance: the FlareStore-inspired
//  grid layout for Flare, and a token-driven dashboard for the modern themes.
//

import SwiftUI
import NimbleViews
import CoreData
import UniformTypeIdentifiers
import NimbleExtensions

struct HomeView: View {
    @ObservedObject private var updateChecker = AppUpdateChecker.shared
    @StateObject var downloadManager = DownloadManager.shared
    @ObservedObject private var lockManager = AppLockManager.shared

    @FetchRequest(entity: CertificatePair.entity(), sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)])
    private var certificates: FetchedResults<CertificatePair>

    @FetchRequest(entity: AltSource.entity(), sortDescriptors: [])
    private var repositories: FetchedResults<AltSource>

    @FetchRequest(entity: Signed.entity(), sortDescriptors: [])
    private var signedApps: FetchedResults<Signed>

    @FetchRequest(entity: Imported.entity(), sortDescriptors: [])
    private var importedApps: FetchedResults<Imported>

    @State var packageURL = ""
    @State private var isDropTargeted = false
    @State var quickSignApp: AnyApp?
    @State private var showAddRepository = false
    @State private var showUniversalSearch = false
    @State private var universalQuery = ""

    @ObservedObject private var appearance = AppearanceStore.shared
    @ObservedObject private var libraryStatus = LibraryStatusStore.shared
    @AppStorage("vexsign.selectedCert") private var selectedCertificateIndex = 0

    /// One privacy-filtered count feeds every Home presentation, so the Flare and
    /// dashboard themes never disagree about how many apps are visible.
    private var visibleAppCount: Int { dashboardVisibleApps.count }

    private var isFlareWebTheme: Bool {
        appearance.isFlare
    }

    private var updateCount: Int { updateChecker.updateCount }

    private var updateTitle: String {
        if updateCount == 1 { return .localized("1 Update Available") }
        if updateCount > 1 { return String.localized("%lld Updates Available", arguments: updateCount) }
        return .localized("No Updates Available")
    }

    private var updateSubtitle: String {
        updateCount > 0
            ? .localized("From repositories you have installed")
            : .localized("Your repositories are up to date")
    }

    var body: some View {
        NBNavigationView("", displayMode: .inline) {
            ZStack {
                if appearance.visualTheme.isLegacyPresentation {
                    FlareGridBackground().ignoresSafeArea()
                } else {
                    Theme.background.ignoresSafeArea()
                }

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        universalSearchBar
                        if EmbeddedContainerRuntime.isAvailable { embeddedSwitches }
                        if appearance.visualTheme.isLegacyPresentation {
                            header
                            if isFlareWebTheme { flareHero }
                            statistics
                            updatesCard
                            importCard
                            packageURLField
                            quickSignRow
                            featureRows
                        } else {
                            // The dashboard already includes import, quick sign, updates,
                            // URL downloads, metrics and workspace tools. Keep one source of
                            // each action instead of stacking a second quick panel above it.
                            workspaceDashboard
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 22)
                    .padding(.bottom, 32)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task {
                if updateChecker.availableUpdates.isEmpty {
                    await updateChecker.checkNow()
                }
            }
            .fullScreenCover(item: $quickSignApp) { app in
                SigningView(app: app.base)
            }
            .sheet(isPresented: $showUniversalSearch) {
                NavigationStack {
                    List {
                        Section {
                            TextField(.localized("Search VexSign"), text: $universalQuery)
                                .textInputAutocapitalization(.never)
                                .submitLabel(.search)
                        }
                        Section {
                            searchDestination(.library, title: .localized("Search Library"), icon: "square.grid.2x2")
                            searchDestination(.appStore, title: .localized("Search Apps & Sources"), icon: "bag")
                            searchDestination(.settings, title: .localized("Search Settings"), icon: "gearshape")
                        } footer: {
                            Text(.localized("Use the same query across Library, repository apps and Settings. Each destination keeps its existing privacy rules and filters."))
                        }
                    }
                    .navigationTitle(.localized("Search VexSign"))
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(.localized("Done")) { showUniversalSearch = false }
                        }
                    }
                }
            }
            .sheet(isPresented: $showAddRepository) {
                SourcesAddView()
            }
        }
    }

    private var universalSearchBar: some View {
        Button { showUniversalSearch = true } label: {
            HStack {
                Image(systemName: "magnifyingglass")
                Text(.localized("Search VexSign"))
                Spacer()
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .padding()
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(A11y.Home.search)
    }

    private func searchDestination(_ tab: TabEnum, title: String, icon: String) -> some View {
        Button {
            showUniversalSearch = false
            TabSelectionObserver.shared.search(universalQuery, in: tab)
        } label: { Label(title, systemImage: icon) }
    }

    private var embeddedSwitches: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(.localized("Built-in apps")).font(.headline)
            EmbeddedContainerControls()
        }
        .padding()
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("VexSign")
                .font(.system(size: 36, weight: .bold, design: .default))
                .foregroundStyle(FlarePalette.text)
                .tracking(-1.2)
            Spacer()
        }
        .padding(.top, 6)
        .accessibilityAddTraits(.isHeader)
    }

    private var flareHero: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Theme.websiteAccent.opacity(0.18))
                        .frame(width: 42, height: 42)
                    Image(systemName: "sparkles")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Theme.websiteAccent)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(.localized("iOS App Signing Tools"))
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .foregroundStyle(FlarePalette.text)
                    Text(.localized("Sign, install, and manage your apps on-device."))
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(FlarePalette.muted)
                }
                Spacer(minLength: 0)
            }

            Text(.localized("A native VexSign workspace for certificates, app sources, signing and installation — no Mac required."))
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .foregroundStyle(FlarePalette.muted)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                flareBadge(.localized("On device"), icon: "iphone")
                flareBadge(.localized("Private"), icon: "lock.fill")
                flareBadge(.localized("Fast"), icon: "bolt.fill")
            }
        }
        .padding(17)
        .background(Theme.cardElevated, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Theme.websiteAccent.opacity(0.34), lineWidth: 1)
        }
        .shadow(color: Theme.websiteGlow, radius: 20, y: 8)
    }

    private func flareBadge(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.websiteAccentSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Theme.websiteAccentSecondary.opacity(0.12), in: Capsule())
    }

    // MARK: - Summary cards

    private var statistics: some View {
        HStack(spacing: 10) {
            HomeMetricCard(
                icon: "folder.fill",
                value: "\(repositories.count)",
                title: .localized("Repos"),
                tint: FlarePalette.pink
            ) {
                openTab(.appStore)
            }

            HomeMetricCard(
                icon: "checkmark.shield.fill",
                value: "\(certificates.count)",
                title: .localized("Certs"),
                tint: FlarePalette.purple
            ) {
                openTab(.settings)
            }

            HomeMetricCard(
                icon: "square.grid.2x2.fill",
                value: "\(visibleAppCount)",
                title: .localized("Apps"),
                tint: FlarePalette.green
            ) {
                openTab(.library)
            }
        }
    }

    private var updatesCard: some View {
        Button {
            TabSelectionObserver.shared.openAppStoreUpdates()
        } label: {
            HStack(spacing: 14) {
                HomeIconTile(
                    systemImage: "arrow.down.circle.fill",
                    tint: FlarePalette.pink,
                    size: 50
                )

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(updateTitle)
                            .font(.system(size: 19, weight: .bold, design: .monospaced))
                            .foregroundStyle(FlarePalette.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)

                        if updateCount > 0 {
                            Text("\(updateCount)")
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .foregroundStyle(FlarePalette.text)
                                .frame(minWidth: 30, minHeight: 30)
                                .background(FlarePalette.pink, in: Circle())
                        }
                    }

                    Text(updateSubtitle)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(FlarePalette.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }

                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(FlarePalette.muted)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 84)
            .background(FlarePalette.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(FlarePalette.pink.opacity(0.62), lineWidth: 1.2)
            }
        }
        .buttonStyle(VexSignFlareButtonStyle())
        .accessibilityLabel(Text(updateCount > 0
                                 ? String.localized("%lld updates available", arguments: updateCount)
                                 : .localized("No updates available")))
    }

    // MARK: - Import and download actions

    private var importCard: some View {
        Button {
            browseForPackages()
        } label: {
            VStack(spacing: 13) {
                ZStack {
                    Circle()
                        .fill(FlarePalette.pink.opacity(0.14))
                        .frame(width: 58, height: 58)
                    Circle()
                        .stroke(FlarePalette.pink.opacity(0.60), lineWidth: 1.2)
                        .frame(width: 58, height: 58)
                    Image(systemName: "plus")
                        .font(.system(size: 33, weight: .light))
                        .foregroundStyle(FlarePalette.pink)
                }
                .shadow(color: FlarePalette.pink.opacity(0.42), radius: 18)

                Text(.localized("Import IPA / TIPA"))
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundStyle(FlarePalette.text)

                Text(.localized("Tap to browse or drag & drop files"))
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(FlarePalette.muted)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 210)
            .background(FlarePalette.card.opacity(isDropTargeted ? 0.92 : 0.82), in: RoundedRectangle(cornerRadius: 23, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 23, style: .continuous)
                    .stroke(
                        isDropTargeted ? FlarePalette.pink : FlarePalette.grid,
                        style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1.2, dash: [9, 8])
                    )
            }
        }
        .buttonStyle(VexSignFlareButtonStyle())
        .accessibilityIdentifier(A11y.Home.importPackages)
        .onDrop(of: [UTType.fileURL.identifier, UTType.item.identifier], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(.localized("Import IPA or TIPA")))
        .accessibilityHint(Text(.localized("Choose an IPA or TIPA file from Files, or drop one here.")))
    }

    private var packageURLField: some View {
        HStack(spacing: 13) {
            Image(systemName: "link")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(FlarePalette.muted)

            TextField(
                "https://example.com/app.ipa",
                text: $packageURL
            )
            .font(.system(.body, design: .monospaced).weight(.medium))
            .foregroundStyle(FlarePalette.pink)
            .tint(FlarePalette.pink)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .submitLabel(.go)
            .onSubmit { startURLDownload() }
            .accessibilityLabel(Text(.localized("Download app from URL")))
            .accessibilityHint(Text(.localized("Enter a direct IPA or TIPA URL and press Go.")))
        }
        .padding(.horizontal, 19)
        .padding(.vertical, 10)
        .frame(minHeight: 64)
        .background(FlarePalette.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(FlarePalette.border, lineWidth: 1)
        }
    }

    private var quickSignRow: some View {
        Button {
            browseForPackages(quickSign: true)
        } label: {
            HomeFeatureRow(
                icon: "signature",
                title: .localized("Quick Sign"),
                subtitle: .localized("Pick and sign IPA immediately."),
                tint: FlarePalette.pink
            )
        }
        .buttonStyle(VexSignFlareButtonStyle())
    }

    private var featureRows: some View {
        VStack(spacing: 14) {
            NavigationLink {
                CertificatesView()
            } label: {
                HomeFeatureRow(
                    icon: "checkmark.shield.fill",
                    title: .localized("Certificates"),
                    subtitle: .localized("Manage your signing certificates"),
                    tint: FlarePalette.purple
                )
            }
            .buttonStyle(VexSignFlareButtonStyle())

            Button {
                showAddRepository = true
            } label: {
                HomeFeatureRow(
                    icon: "plus.circle.fill",
                    title: .localized("Add Repository"),
                    subtitle: .localized("Add a new app source"),
                    tint: FlarePalette.green
                )
            }
            .buttonStyle(VexSignFlareButtonStyle())

            NavigationLink {
                TaskCenterView()
            } label: {
                HomeFeatureRow(
                    icon: "list.bullet.rectangle.fill",
                    title: .localized("Task Center"),
                    subtitle: .localized("Downloads, imports, signing and installs"),
                    tint: FlarePalette.pink
                )
            }
            .buttonStyle(VexSignFlareButtonStyle())

            NavigationLink {
                IPSWBrowserView(inNavigationStack: false)
            } label: {
                HomeFeatureRow(
                    icon: "externaldrive.fill",
                    title: .localized("IPSW Browser"),
                    subtitle: .localized("Browse firmware and signing status"),
                    tint: FlarePalette.purple
                )
            }
            .buttonStyle(VexSignFlareButtonStyle())
        }
    }

    // MARK: - Quiet, actionable workspace (System and new presets)

    private var dashboardVisibleApps: [AppInfoPresentable] {
        let apps = signedApps.map { $0 as AppInfoPresentable } + importedApps.map { $0 as AppInfoPresentable }
        return apps.filter { app in
            guard let uuid = app.uuid else { return true }
            return !lockManager.isAppHidden(uuid) && (!lockManager.isAppLocked(uuid) || lockManager.isSessionUnlocked(uuid))
        }
    }

    private var recentVisibleApps: [AnyApp] {
        dashboardVisibleApps.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            .prefix(3).map { AnyApp(base: $0) }
    }

    private var attentionCount: Int {
        dashboardVisibleApps.filter { app in
            let status = libraryStatus.status(for: app)
            let certificate = Storage.shared.getCertificate(from: app)
            return LibraryAttentionReason.evaluate(
                isSigned: app.isSigned, expiry: status.expiresAt ?? certificate?.expiration,
                revoked: certificate?.revoked == true,
                hasUpdate: updateChecker.hasUpdate(for: app) != nil
            ) != nil
        }.count
    }

    private var dashboardCertificate: CertificatePair? {
        guard certificates.indices.contains(selectedCertificateIndex) else { return nil }
        return certificates[selectedCertificateIndex]
    }

    private var workspaceDashboard: some View {
        VexHomeDashboard(
            certificate: dashboardCertificate,
            appCount: dashboardVisibleApps.count,
            repositoryCount: repositories.count,
            certificateCount: certificates.count,
            attentionCount: attentionCount,
            updateCount: updateCount,
            recentApps: recentVisibleApps,
            onImport: { browseForPackages() },
            onDropPackages: { handleDrop($0) },
            onQuickSign: { browseForPackages(quickSign: true) },
            onOpenTab: { openTab($0) },
            onOpenUpdates: { TabSelectionObserver.shared.openAppStoreUpdates() },
            onAddRepository: { showAddRepository = true }
        )
        .task { libraryStatus.refresh(dashboardVisibleApps) }
    }
}
