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
    @StateObject private var downloadManager = DownloadManager.shared
    @ObservedObject private var lockManager = AppLockManager.shared

    @FetchRequest(entity: CertificatePair.entity(), sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)])
    private var certificates: FetchedResults<CertificatePair>

    @FetchRequest(entity: AltSource.entity(), sortDescriptors: [])
    private var repositories: FetchedResults<AltSource>

    @FetchRequest(entity: Signed.entity(), sortDescriptors: [])
    private var signedApps: FetchedResults<Signed>

    @FetchRequest(entity: Imported.entity(), sortDescriptors: [])
    private var importedApps: FetchedResults<Imported>

    @State private var packageURL = ""
    @State private var isDropTargeted = false
    @State private var quickSignApp: AnyApp?
    @State private var showAddRepository = false

    @ObservedObject private var appearance = AppearanceStore.shared
    @ObservedObject private var tasks = UnifiedTaskCenter.shared
    @ObservedObject private var libraryStatus = LibraryStatusStore.shared
    @AppStorage("vexsign.selectedCert") private var selectedCertificateIndex = 0

    private var visibleAppCount: Int {
        let signed = signedApps.filter { app in
            guard lockManager.strictHidingEnabled, let uuid = app.uuid else { return true }
            return !lockManager.isStrictlyHidden(uuid)
        }.count
        let imported = importedApps.filter { app in
            guard lockManager.strictHidingEnabled, let uuid = app.uuid else { return true }
            return !lockManager.isStrictlyHidden(uuid)
        }.count
        return signed + imported
    }

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
                            workspaceDashboard
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 22)
                    .padding(.bottom, 116)
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
            .sheet(isPresented: $showAddRepository) {
                SourcesAddView()
            }
        }
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
            openTab(.appStore)
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
            .font(.system(size: 16, weight: .medium, design: .monospaced))
            .foregroundStyle(FlarePalette.pink)
            .tint(FlarePalette.pink)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .submitLabel(.go)
            .onSubmit { startURLDownload() }
        }
        .padding(.horizontal, 19)
        .frame(height: 64)
        .background(FlarePalette.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(FlarePalette.border, lineWidth: 1)
        }
        .accessibilityLabel(Text(.localized("Download app from URL")))
        .accessibilityHint(Text(.localized("Enter a direct IPA or TIPA URL and press Go.")))
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
            onQuickSign: { browseForPackages(quickSign: true) },
            onOpenTab: { openTab($0) },
            onAddRepository: { showAddRepository = true }
        )
        .task { libraryStatus.refresh(dashboardVisibleApps) }
    }

    // MARK: - Working actions

    private func openTab(_ tab: TabEnum) {
        // Primary tabs are always visible; only a hidden legacy tab needs to
        // be surfaced again before switching to it.
        TabBarPreferences.shared.setHidden(tab, false)
        TabSelectionObserver.shared.selectedTab = tab
    }

    private func browseForPackages(quickSign: Bool = false) {
        DocumentPicker.open([.ipa, .tipa], multiple: !quickSign, folder: .apps) { urls in
            guard !urls.isEmpty else { return }
            if quickSign {
                enqueuePackage(urls[0], quickSign: true)
            } else {
                urls.forEach { enqueuePackage($0) }
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            let identifier = provider.registeredTypeIdentifiers.first { id in
                UTType(id)?.conforms(to: .fileURL) == true
            } ?? UTType.fileURL.identifier

            provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, _ in
                let url: URL?
                if let itemURL = item as? URL {
                    url = itemURL
                } else if let itemURL = item as? NSURL {
                    url = itemURL as URL
                } else if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let path = item as? String {
                    url = URL(fileURLWithPath: path)
                } else {
                    url = nil
                }

                guard let url else { return }
                DispatchQueue.main.async {
                    guard ["ipa", "tipa"].contains(url.pathExtension.lowercased()) else {
                        Toast.error(.localized("Please drop an IPA or TIPA file."))
                        return
                    }
                    enqueuePackage(url)
                }
            }
        }
        return true
    }

    private func enqueuePackage(_ url: URL, quickSign: Bool = false) {
        guard let stagedURL = stagePackage(url) else { return }

        if quickSign {
            // Quick Sign uses the same import pipeline as the Library, but keeps
            // the returned app so the signing sheet can open immediately.
            FR.handlePackageFile(stagedURL) { result in
                switch result {
                case .success(let app):
                    Task { @MainActor in
                        ImportDuplicateReview.resolve(app) { chosen, _ in
                            Toast.success(.localized("App ready to sign"), systemImage: "signature")
                            quickSignApp = AnyApp(base: chosen)
                        }
                    }
                case .failure(let error):
                    Toast.error(error.localizedDescription, duration: .long)
                }
            }
            return
        }

        _ = downloadManager.startArchive(
            from: stagedURL,
            id: "VexSignHomeImport_\(UUID().uuidString)",
            appName: stagedURL.deletingPathExtension().lastPathComponent,
            reviewDuplicates: true
        ) { error in
            if let error {
                Toast.error(error.localizedDescription, duration: .long)
            }
        }
    }

    private func stagePackage(_ url: URL) -> URL? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }

        let fileManager = FileManager.default
        let directory = fileManager.downloadStaging
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = FileManagerActions.uniqueURL(for: url.lastPathComponent, in: directory)
            try fileManager.copyItem(at: url, to: target)
            return target
        } catch {
            Toast.error(error.localizedDescription, duration: .long)
            return nil
        }
    }

    private func startURLDownload() {
        let value = packageURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            Toast.error(.localized("Enter a valid HTTP or HTTPS app URL."))
            return
        }

        _ = downloadManager.startDownload(
            from: url,
            id: "VexSignHomeURL_\(UUID().uuidString)",
            appName: url.deletingPathExtension().lastPathComponent
        )
        Toast.info(.localized("Download started"), systemImage: "arrow.down.circle")
        packageURL = ""
    }
}

// MARK: - Original Flare-inspired presentation tokens

private enum FlarePalette {
    private static var visualTheme: VexSignVisualTheme {
        AppearanceStore.snapshot().visualTheme
    }

    private static var isBase: Bool { !visualTheme.isLegacyPresentation }
    private static var isWeb: Bool { visualTheme == .flare }

    static var background: Color {
        isBase ? Theme.background : Color(red: 0.025, green: 0.022, blue: 0.045)
    }
    static var card: Color {
        isBase ? Theme.card : (isWeb ? Theme.card : Color(red: 0.065, green: 0.065, blue: 0.095))
    }
    static var border: Color {
        isBase ? Theme.separator : (isWeb ? Theme.separator : Color.white.opacity(0.10))
    }
    static var grid: Color {
        if isBase { return .clear }
        if isWeb { return Theme.separator.opacity(0.8) }
        return Color(red: 0.42, green: 0.025, blue: 0.19).opacity(0.52)
    }
    static var muted: Color {
        isBase ? Theme.secondary : Color(red: 0.49, green: 0.47, blue: 0.55)
    }
    static var text: Color {
        isBase ? Theme.primary : .white
    }
    static var pink: Color {
        isBase ? Theme.tint : (isWeb ? Theme.websiteAccent : Color(red: 1.0, green: 0.12, blue: 0.34))
    }
    static var purple: Color {
        isWeb ? Theme.websiteAccentSecondary : Color(red: 0.62, green: 0.20, blue: 1.0)
    }
    static var green: Color { Color(red: 0.03, green: 0.76, blue: 0.50) }
}

private struct FlareGridBackground: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            let spacing: CGFloat = 71

            var x: CGFloat = 0
            while x <= size.width + spacing {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += spacing
            }

            var y: CGFloat = 0
            while y <= size.height + spacing {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += spacing
            }

            context.stroke(path, with: .color(FlarePalette.grid), lineWidth: 0.8)
        }
        .background(FlarePalette.background)
        // Purely decorative — keep it out of VoiceOver and Reduce Motion.
        .accessibilityHidden(true)
    }
}

private struct HomeIconTile: View {
    let systemImage: String
    let tint: Color
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .fill(tint.opacity(0.15))
                .frame(width: size, height: size)
            Image(systemName: systemImage)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(tint)
        }
    }
}

private struct HomeMetricCard: View {
    let icon: String
    let value: String
    let title: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(height: 30)

                Text(value)
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                    .foregroundStyle(FlarePalette.text)
                    .monospacedDigit()

                Text(title)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(FlarePalette.muted)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 104)
            .background(FlarePalette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(FlarePalette.border, lineWidth: 1)
            }
        }
        .buttonStyle(VexSignFlareButtonStyle())
        .accessibilityLabel(Text("\(value) \(title)"))
    }
}

private struct HomeFeatureRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let tint: Color

    var body: some View {
        HStack(spacing: 16) {
            HomeIconTile(systemImage: icon, tint: tint, size: 48)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundStyle(FlarePalette.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(subtitle)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(FlarePalette.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            Spacer(minLength: 6)
            Image(systemName: "chevron.right")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(FlarePalette.muted)
        }
        .padding(.horizontal, 17)
        .frame(minHeight: 82)
        .background(FlarePalette.card, in: RoundedRectangle(cornerRadius: 21, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 21, style: .continuous)
                .stroke(FlarePalette.border, lineWidth: 1)
        }
        .contentShape(Rectangle())
    }
}
