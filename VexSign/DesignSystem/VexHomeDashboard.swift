//
//  VexHomeDashboard.swift
//  VexSign
//
//  The default Home surface: a compact, content-first dashboard built from the
//  shared design tokens. It deliberately uses system text styles, adaptive
//  surfaces and 44pt controls so it remains usable at every Dynamic Type size.
//

import SwiftUI
import CoreData
import UniformTypeIdentifiers
import NimbleExtensions

struct VexHomeDashboard: View {
    let certificate: CertificatePair?
    let appCount: Int
    let repositoryCount: Int
    let certificateCount: Int
    let attentionCount: Int
    let updateCount: Int
    let recentApps: [AnyApp]

    let onImport: () -> Void
    let onDropPackages: ([NSItemProvider]) -> Bool
    let onQuickSign: () -> Void
    let onOpenTab: (TabEnum) -> Void
    let onOpenUpdates: () -> Void
    let onAddRepository: () -> Void

    @ObservedObject private var tasks = UnifiedTaskCenter.shared
    @ObservedObject private var downloadManager = DownloadManager.shared

    @State private var urlText = ""
    @State private var isDropTargeted = false
    @State private var isCertificateManagerPresented = false

    private var activeTask: UnifiedTask? {
        tasks.tasks.first { $0.phase.isInProgress }
    }

    private var isSigningReady: Bool {
        guard let certificate, !certificate.revoked else { return false }
        return certificate.expiration.map { $0 > Date() } ?? true
    }

    private var signingActionTitle: String {
        if isSigningReady { return .localized("Quick sign") }
        if certificateCount == 0 { return .localized("Add certificate") }
        return certificate == nil ? .localized("Select certificate") : .localized("Review certificate")
    }

    private var signingActionIcon: String {
        isSigningReady ? "signature" : "checkmark.seal.fill"
    }

    private var completedSetupSteps: Int {
        VexHomeSetup.completedSteps(
            certificates: certificateCount,
            repositories: repositoryCount,
            apps: appCount
        )
    }

    private var needsSetup: Bool { !VexHomeSetup.isComplete(
        certificates: certificateCount,
        repositories: repositoryCount,
        apps: appCount
    ) }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            updatesCard
            importCard
            packageURLField
            hero
            if !recentApps.isEmpty { recentAppsSection }
            statusSection
            metrics
            if needsSetup { gettingStarted }
            toolsSection
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $isCertificateManagerPresented) {
            NavigationStack {
                CertificatesView()
            }
            .adaptiveSheetSizing()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VexHomeMark()

            TimelineView(.periodic(from: .now, by: 60)) { context in
                VStack(alignment: .leading, spacing: 2) {
                    Text(WorkspaceGreeting.title(hour: Calendar.current.component(.hour, from: context.date)))
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .accessibilityAddTraits(.isHeader)
                    Text(.localized("Your signing workspace"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            NavigationLink(destination: TaskCenterView()) {
                ZStack {
                    Circle()
                        .fill(Theme.card)
                    Circle()
                        .stroke(Theme.separator, lineWidth: 0.5)
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.tint)
                }
                .frame(width: 44, height: 44)
                .contentShape(Circle())
            }
            .buttonStyle(VexSignFlareButtonStyle())
            .accessibilityLabel(Text(.localized("Task Center")))
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Text(.localized("ON-DEVICE SIGNING"))
                    .font(.caption2.weight(.bold))
                    .tracking(1.4)
                    .foregroundStyle(.white.opacity(0.78))
                Spacer(minLength: 4)
                certificatePill
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(.localized("Your apps. Your signing.\nOn device."))
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Text(.localized("Import an IPA, sign it with your certificate, and install it — without leaving your iPhone."))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                VexHeroAction(
                    title: signingActionTitle,
                    systemImage: signingActionIcon,
                    filled: true,
                    action: {
                        if isSigningReady {
                            onQuickSign()
                        } else {
                            isCertificateManagerPresented = true
                        }
                    }
                )
                VexHeroAction(
                    title: .localized("Open Library"),
                    systemImage: "square.grid.2x2",
                    filled: false,
                    action: { onOpenTab(.library) }
                )
            }
        }
        .padding(22)
        .background {
            ZStack {
                LinearGradient(
                    colors: [Theme.tint, Theme.tintDeep, Theme.websiteAccent],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Circle()
                    .fill(Color.white.opacity(0.16))
                    .frame(width: 230, height: 230)
                    .blur(radius: 46)
                    .offset(x: 132, y: -118)
                Circle()
                    .fill(Theme.websiteAccentSecondary.opacity(0.24))
                    .frame(width: 190, height: 190)
                    .blur(radius: 54)
                    .offset(x: -120, y: 126)
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 0.75)
        }
        .shadow(color: Theme.tint.opacity(0.24), radius: 22, y: 10)
    }

    private var certificatePill: some View {
        let state = certificateState
        return Label(state.title, systemImage: state.icon)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(.white)
            .background(Color.white.opacity(0.14), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 0.5))
    }

    private var certificateState: (title: String, icon: String) {
        guard let certificate else {
            return (certificateCount == 0 ? .localized("Set up signing") : .localized("Select certificate"), "exclamationmark.shield")
        }
        if certificate.revoked {
            return (.localized("Certificate revoked"), "xmark.shield")
        }
        guard let expiry = certificate.expiration else {
            return (.localized("Certificate ready"), "checkmark.shield")
        }
        guard expiry > Date() else {
            return (.localized("Certificate expired"), "xmark.shield")
        }
        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: Date()),
            to: calendar.startOfDay(for: expiry)
        ).day ?? 0
        if days < 0 { return (.localized("Certificate expired"), "xmark.shield") }
        if days <= 30 {
            return (String.localized("Expires in %lld days", arguments: days), "clock.badge.exclamationmark")
        }
        return (.localized("Certificate ready"), "checkmark.shield")
    }

    // MARK: - Metrics

    private var metrics: some View {
        VexHomeSurface(padding: 0) {
            HStack(spacing: 0) {
                metric(value: appCount, label: .localized("Library"), icon: "square.grid.2x2.fill") {
                    onOpenTab(.library)
                }
                metricDivider
                metric(value: certificateCount, label: .localized("Certificates"), icon: "checkmark.seal.fill") {
                    onOpenTab(.settings)
                }
                metricDivider
                metric(value: repositoryCount, label: .localized("Repositories"), icon: "globe.desk.fill") {
                    onOpenTab(.appStore)
                }
            }
            .padding(.vertical, 14)
        }
    }

    private var metricDivider: some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(width: 0.5, height: 34)
            .accessibilityHidden(true)
    }

    private func metric(value: Int, label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: icon)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.tint)
                    Text("\(value)")
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .monospacedDigit()
                }
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(VexSignFlareButtonStyle())
        .accessibilityLabel(Text("\(value) \(label)"))
    }

    // MARK: - Updates and import

    private var updatesCard: some View {
        let title = updateCount == 1
            ? .localized("1 Update Available")
            : updateCount > 1
                ? String.localized("%lld Updates Available", arguments: updateCount)
                : .localized("No Updates Available")
        let detail = updateCount > 0
            ? .localized("From repositories you have installed")
            : .localized("Your repositories are up to date")

        return Button(action: onOpenUpdates) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .fill(Theme.tintSoft)
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(Theme.tint)
                }
                .frame(width: 54, height: 54)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.system(.headline, design: .rounded).weight(.bold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        if updateCount > 0 {
                            Text("\(updateCount)")
                                .font(.caption.weight(.bold).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(Theme.tint, in: Capsule())
                        }
                    }
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }

                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Theme.tint.opacity(0.42), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(VexSignFlareButtonStyle())
        .accessibilityLabel(Text(updateCount > 0
            ? String.localized("%lld updates available", arguments: updateCount)
            : .localized("No updates available")))
    }

    private var importCard: some View {
        Button(action: onImport) {
            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Theme.tintSoft)
                    Circle()
                        .stroke(Theme.tint.opacity(0.55), lineWidth: 1)
                    Image(systemName: "plus")
                        .font(.system(size: 31, weight: .light))
                        .foregroundStyle(Theme.tint)
                }
                .frame(width: 70, height: 70)
                .shadow(color: Theme.tint.opacity(0.2), radius: 18)

                Text(.localized("Import IPA / TIPA"))
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)

                Text(.localized("Tap to browse or drag & drop files"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 226)
            .padding(18)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(
                        isDropTargeted ? Theme.tint : Theme.tint.opacity(0.32),
                        style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: [8, 7])
                    )
            }
        }
        .buttonStyle(VexSignFlareButtonStyle())
        .accessibilityIdentifier(A11y.Home.importPackages)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(.localized("Import IPA or TIPA")))
        .accessibilityHint(Text(.localized("Choose an IPA or TIPA file from Files, or drop one here.")))
        .onDrop(
            of: [UTType.fileURL.identifier, UTType.item.identifier],
            isTargeted: $isDropTargeted,
            perform: onDropPackages
        )
    }

    private var packageURLField: some View {
        HStack(spacing: 12) {
            Image(systemName: "link")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("https://example.com/app.ipa", text: $urlText)
                .font(.system(.body, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.go)
                .onSubmit(startURLDownload)
                .accessibilityLabel(Text(.localized("Download app from URL")))

            Button(action: startURLDownload) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(Theme.tint)
            }
            .buttonStyle(.plain)
            .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel(Text(.localized("Download")))
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 62)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Theme.separator, lineWidth: 0.75)
        }
        .accessibilityHint(Text(.localized("Enter a direct IPA or TIPA URL and press Go.")))
    }

    // MARK: - Getting started

    private var gettingStarted: some View {
        VexHomeSurface {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(.localized("Get started"))
                            .font(.headline)
                        Text(.localized("Three steps to your first signed app."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text(String.localized("%lld of 3", arguments: completedSetupSteps))
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.tint)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Theme.tintSoft, in: Capsule())
                }

                VexSetupRow(
                    title: .localized("Add a signing certificate"),
                    detail: .localized("Import a .p12 and its provisioning profile."),
                    systemImage: "checkmark.seal",
                    done: certificateCount > 0,
                    action: { onOpenTab(.settings) }
                )
                VexSetupRow(
                    title: .localized("Add an app source"),
                    detail: .localized("Browse repositories or import an IPA."),
                    systemImage: "globe.desk",
                    done: repositoryCount > 0,
                    action: onAddRepository
                )
                VexSetupRow(
                    title: .localized("Import your first IPA"),
                    detail: .localized("It stays on this device until you sign it."),
                    systemImage: "square.and.arrow.down",
                    done: appCount > 0,
                    action: onImport
                )
            }
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusSection: some View {
        if activeTask != nil || attentionCount > 0 {
            VStack(alignment: .leading, spacing: 12) {
                VexSectionTitle(title: .localized("In your workspace"), detail: nil)

                if let task = activeTask {
                    NavigationLink(destination: TaskCenterView()) {
                        VexStatusCard(
                            title: task.title,
                            detail: String.localized("%@ · %@", arguments: task.kind.title, task.phase.title),
                            systemImage: task.kind.icon,
                            tint: Theme.tint,
                            showsProgress: true,
                            progress: task.progress
                        )
                    }
                    .buttonStyle(VexSignFlareButtonStyle())
                }

                if attentionCount > 0 {
                    Button { onOpenTab(.library) } label: {
                        VexStatusCard(
                            title: String.localized("%lld items need review", arguments: attentionCount),
                            detail: .localized("Open Library to fix expiry, revocation or updates."),
                            systemImage: "exclamationmark.triangle.fill",
                            tint: Color.orange,
                            showsProgress: false,
                            progress: 0
                        )
                    }
                    .buttonStyle(VexSignFlareButtonStyle())
                }

            }
        }
    }

    // MARK: - Recent apps

    private var recentAppsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VexSectionTitle(title: .localized("Recently added"), detail: nil)
                Spacer(minLength: 8)
                Button(.localized("See all")) { onOpenTab(.library) }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.tint)
                    .buttonStyle(.plain)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(recentApps) { item in
                        Button { onOpenTab(.library) } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                FRAppIconView(app: item.base, size: 46)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.base.name ?? .localized("Application"))
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(item.base.isSigned ? .localized("Signed") : .localized("Imported"))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(14)
                            .frame(width: 156, alignment: .leading)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.rail, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: Theme.Radius.rail, style: .continuous)
                                    .stroke(Theme.separator, lineWidth: 0.5)
                            }
                        }
                        .buttonStyle(VexSignFlareButtonStyle())
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    // MARK: - Tools

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VexSectionTitle(title: .localized("Workspace tools"), detail: nil)
            VexHomeSurface(padding: 0) {
                VStack(spacing: 0) {
                    NavigationLink(destination: CertificatesView()) {
                        VexToolRow(
                            title: .localized("Certificates"),
                            detail: .localized("Identity, provisioning and expiry"),
                            systemImage: "checkmark.seal.fill",
                            tint: Theme.tint
                        )
                    }
                    .buttonStyle(.plain)

                    toolDivider

                    Button(action: onAddRepository) {
                        VexToolRow(
                            title: .localized("Add repository"),
                            detail: .localized("Connect an AltStore-compatible source"),
                            systemImage: "plus.circle.fill",
                            tint: Color(red: 0.36, green: 0.78, blue: 0.58)
                        )
                    }
                    .buttonStyle(.plain)

                    toolDivider

                    NavigationLink(destination: CompanionSigningWorkflowView()) {
                        VexToolRow(
                            title: .localized("Companion apps"),
                            detail: .localized("Apple TV, Watch and Vision"),
                            systemImage: "arrow.triangle.branch",
                            tint: Color(red: 0.96, green: 0.56, blue: 0.32)
                        )
                    }
                    .buttonStyle(.plain)

                }
            }
        }
    }

    private var toolDivider: some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(height: 0.5)
            .padding(.leading, 60)
            .accessibilityHidden(true)
    }

    // MARK: - URL download

    private func startURLDownload() {
        let value = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
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
        urlText = ""
    }
}
