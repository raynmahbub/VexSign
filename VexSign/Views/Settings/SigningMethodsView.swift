// MARK: - SigningMethodsView
/// Primary entry point for selecting and configuring a signing method.
/// Integrates paid certificates, free Apple ID (NativeSigning), and TrollStore.

import SwiftUI
import UIKit
import NimbleViews
import NimbleExtensions
import NativeSigning
import SideSign

struct SigningMethodsView: View {
    /// `NativeAccountPhase.isSignedIn` is internal to NativeSigning, so the case is
    /// matched here rather than read as a property.
    private var isSignedIn: Bool {
        guard let phase = nativeManager.snapshot?.phase else { return false }
        if case .signedIn = phase { return true }
        return false
    }

    @StateObject private var nativeManager = NativeSigningManager.shared
    @State private var selectedMethod: SigningMethod = .paidCertificate
    @State private var showAppleIDLogin = false
    @State private var showTeamSelection = false
    @State private var showProvisioningFlow = false
    @State private var showTrollStoreInstall = false
    @State private var showTrollStoreRefresh = false
    @State private var appleID = ""
    @State private var password = ""
    @State private var xcodeVersion = "15.0"
    @State private var pendingOperation: NativeAccountOperation?
    @State private var pendingChallenge: SideSignTwoFactorBroker.Challenge?
    @State private var twoFactorCode = ""
    @State private var isAuthenticating = false
    @State private var authError: String?

    var body: some View {
        NBList(.localized("Signing Methods")) {
            // MARK: - Paid Certificate Section
            Section {
                signingMethodRow(
                    method: .paidCertificate,
                    isSelected: selectedMethod == .paidCertificate,
                    availability: SigningMethodAvailability.current(for: .paidCertificate)
                ) {
                    selectedMethod = .paidCertificate
                }

                if selectedMethod == .paidCertificate {
                    NavigationLink(destination: CertificatesView()) {
                        Label(.localized("Manage Certificates"), systemImage: "checkmark.seal")
                    }
                    .disabled(!SigningMethodAvailability.current(for: .paidCertificate).isAvailable)

                    Text(.localized("Import a .p12 certificate and .mobileprovision profile. No app limits, 1-year validity, full entitlement support."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text(.localized("Certificate-based Signing"))
            }

            // MARK: - Free Apple ID Section
            Section {
                signingMethodRow(
                    method: .freeAppleID,
                    isSelected: selectedMethod == .freeAppleID,
                    availability: SigningMethodAvailability.current(for: .freeAppleID)
                ) {
                    selectedMethod = .freeAppleID
                }

                if selectedMethod == .freeAppleID {
                    freeAppleIDContent
                }
            } header: {
                Text(.localized("Free Apple ID Signing"))
            }

            // MARK: - TrollStore Section
            Section {
                signingMethodRow(
                    method: .trollStore,
                    isSelected: selectedMethod == .trollStore,
                    availability: SigningMethodAvailability.current(for: .trollStore)
                ) {
                    selectedMethod = .trollStore
                }

                if selectedMethod == .trollStore {
                    trollStoreContent
                }
            } header: {
                Text(.localized("TrollStore Installation"))
            }

            // MARK: - Status & Diagnostics
            Section {
                if let snapshot = nativeManager.snapshot {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(.localized("Native Signing Status"))
                            .font(.headline)
                        HStack {
                            Image(systemName: snapshot.phase.icon)
                                .foregroundStyle(snapshot.phase.color)
                            Text(snapshot.phase.displayTitle)
                                .font(.subheadline.weight(.medium))
                        }
                        if snapshot.cleanupRequired {
                            Text(.localized("Cleanup required — some operations need retry"))
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Button(.localized("Check Native Signing Health")) {
                    Task { await nativeManager.refreshSnapshot() }
                }
                .disabled(!nativeManager.isBackendReady)

                NavigationLink(destination: CertificateStatusView()) {
                    Label(.localized("Certificate Revocation Status (OCSP/CRL)"), systemImage: "checkmark.shield")
                }
                .disabled(!isSignedIn)

                if let error = nativeManager.lastError {
                    Text(error)
                        .font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text(.localized("Diagnostics"))
            }
        }
        .task {
            await nativeManager.synchronizeProvider()
            await nativeManager.renewExpiringProfiles()
        }
        .sheet(isPresented: $showAppleIDLogin, onDismiss: { password = "" }) {
            AppleIDLoginView(
                appleID: $appleID,
                password: $password,
                xcodeVersion: $xcodeVersion,
                isAuthenticating: $isAuthenticating,
                authError: $authError,
                onSubmit: { Task { await performAppleIDLogin() } }
            )
        }
        .sheet(isPresented: $showTeamSelection) {
            if let operation = pendingOperation {
                TeamSelectionView(
                    teams: extractTeams(from: nativeManager.snapshot),
                    onSelect: { teamID in
                        Task { await selectTeam(teamID, operationID: operation.id) }
                    }
                )
            }
        }
        .alert(.localized("Two-Factor Authentication"), isPresented: Binding(
            get: { pendingChallenge != nil },
            set: { if !$0 { pendingChallenge = nil } }
        ), presenting: pendingChallenge) { challenge in
            TextField(.localized("6-digit code"), text: $twoFactorCode)
            Button(.localized("Cancel"), role: .cancel) {
                if let operation = pendingOperation {
                    Task { await nativeManager.cancelAuthentication(operationID: operation.id) }
                }
                pendingOperation = nil
                pendingChallenge = nil
                twoFactorCode = ""
            }
            Button(.localized("Submit")) {
                Task { await submitTwoFactor(challenge) }
            }
            .disabled(twoFactorCode.count != 6)
        } message: { challenge in
            Text(.localized("Enter the verification code sent to your trusted device"))
        }
        .task(id: pendingOperation?.id) {
            guard let operation = pendingOperation else { return }
            // Authentication continues after startAuthentication returns. Consume
            // its buffered challenges instead of checking one early snapshot.
            for await challenge in operation.challenges {
                guard !Task.isCancelled, pendingOperation?.id == operation.id else { return }
                twoFactorCode = ""
                pendingChallenge = challenge
            }
        }
        .onChange(of: nativeManager.snapshot) { _, snapshot in
            guard let operation = pendingOperation, let phase = snapshot?.phase else { return }
            switch phase {
            case .awaitingTeamSelection(let id, _, _) where id == operation.id:
                pendingChallenge = nil
                showTeamSelection = true
            case .signedIn:
                pendingChallenge = nil
                pendingOperation = nil
                showTeamSelection = false
            default: break
            }
        }
        .onDisappear {
            if let operation = pendingOperation {
                Task { await nativeManager.cancelAuthentication(operationID: operation.id) }
            }
            pendingOperation = nil
            pendingChallenge = nil
            password = ""
            twoFactorCode = ""
        }
    }

    // MARK: - Subviews

    private func signingMethodRow(
        method: SigningMethod,
        isSelected: Bool,
        availability: SigningMethodAvailability,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: method.icon)
                    .font(.title2)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(method.displayName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(method.shortDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    // An unavailable row must say why; the reason was computed
                    // but never rendered before.
                    if !availability.isAvailable, let reason = availability.availabilityReason {
                        Text(reason)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    }
                }

                Spacer()

                if availability.isAvailable {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .font(.title3)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.title3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(availability.isAvailable ? 1.0 : 0.6)
    }

    private var freeAppleIDContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Status
            if let snapshot = nativeManager.snapshot {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: snapshot.phase.icon)
                            .foregroundStyle(snapshot.phase.color)
                        Text(snapshot.phase.displayTitle)
                            .font(.subheadline.weight(.medium))
                    }
                    if case .signedIn(let context) = snapshot.phase {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(String.localized("Team: %@ (%@)", arguments: context.team.identifier, context.team.membership.displayName))
                                .font(.caption).foregroundStyle(.secondary)
                            // Locally indexed apps are not Apple portal/device quota.
                            HStack(spacing: 4) {
                                Image(systemName: "app.badge")
                                    .font(.caption2)
                                Group {
                                    if nativeManager.freeAccountInventoryAvailable {
                                        Text(String.localized("%lld indexed apps — not portal quota", arguments: nativeManager.freeAccountAppCount))
                                    } else {
                                        Text(.localized("Profile inventory unavailable"))
                                    }
                                }
                                .font(.caption)
                            }
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(uiColor: .quaternarySystemFill)))
            }

            // Actions based on state
            if case .signedIn = nativeManager.snapshot?.phase {
                // Signed in - show provisioning options
                VStack(spacing: 12) {
                    Button {
                        showProvisioningFlow = true
                    } label: {
                        Label(.localized("Provision & Sign App"), systemImage: "signature")
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        Task { await nativeManager.renewExpiringProfiles() }
                    } label: {
                        Label(.localized("Check Profiles for Renewal"), systemImage: "arrow.triangle.2.circlepath")
                    }
                    if !nativeManager.renewalCandidates.isEmpty {
                        Text(.localized("Profiles need renewal review. Background discovery does not authorize account changes, re-signing or installation."))
                            .font(.caption).foregroundStyle(.orange)
                        ForEach(nativeManager.renewalCandidates) { profile in
                            VStack(alignment: .leading) {
                                Text(profile.bundleIdentifier).font(.caption.weight(.medium))
                                Text(profile.expiresAt, style: .date).font(.caption2)
                            }
                        }
                    }

                    Button(role: .destructive) {
                        Task { try? await nativeManager.signOut() } // try? ok: sign out is best-effort, UI reflects state
                    } label: {
                        Label(.localized("Sign Out"), systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                // Not signed in - show login
                Button {
                    showAppleIDLogin = true
                } label: {
                    Label(.localized("Sign in with Apple ID"), systemImage: "person.crop.circle.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!nativeManager.isBackendReady)

                if !nativeManager.isBackendReady {
                    Text(.localized("Native signing backend not initialized. Check diagnostics."))
                        .font(.caption).foregroundStyle(.red)
                }
            }

            // Anisette Provider Configuration
            Divider()
            AnisetteProviderConfigView()

            // Info
            Text(.localized("Free Apple ID: 3 apps per 7 days. Requires weekly profile refresh. Limited entitlements (no push, no iCloud, no app groups)."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .sheet(isPresented: $showProvisioningFlow) {
            ProvisioningFlowView()
        }
    }

    private var trollStoreContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            let caps = SigningMethodAvailability.current(for: .trollStore)

            if caps.isAvailable {
                Label(.localized("This copy of VexSign was installed by TrollStore"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline)

                Text(.localized("TrollStore installs signed IPAs permanently: no 7-day expiry and no Apple ID. VexSign hands the IPA over through TrollStore's install URL and cannot read back the result."))
                    .font(.caption).foregroundStyle(.secondary)

                Button {
                    showTrollStoreInstall = true
                } label: {
                    Label(.localized("Send a Signed IPA to TrollStore"), systemImage: "t.square.fill")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    showTrollStoreRefresh = true
                } label: {
                    Label(.localized("Open TrollStore"), systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.bordered)
            } else {
                Label(.localized("TrollStore install not detected here"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.subheadline)

                Text(.localized("VexSign can only recognise a TrollStore install of itself, by the marker TrollStore leaves beside the app. On this copy it cannot see one, which does not prove TrollStore is absent. VexSign never installs TrollStore."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .sheet(isPresented: $showTrollStoreInstall) {
            TrollStoreInstallView()
        }
        .sheet(isPresented: $showTrollStoreRefresh) {
            TrollStoreRefreshView()
        }
    }

    // MARK: - Helpers

    private func extractTeams(from snapshot: NativeAccountSnapshot?) -> [NativeAccountTeam] {
        guard case .awaitingTeamSelection(_, let teams, _) = snapshot?.phase else { return [] }
        return teams
    }

    private func performAppleIDLogin() async {
        isAuthenticating = true
        authError = nil
        do {
            let operation = try await nativeManager.authenticate(
                appleID: appleID,
                password: password,
                xcodeVersion: xcodeVersion
            )
            pendingOperation = operation
            isAuthenticating = false
            showAppleIDLogin = false

            // Check if 2FA is required
            if case .awaitingTwoFactor = nativeManager.snapshot?.phase {
                showTeamSelection = false // Will show 2FA alert instead
            } else if case .awaitingTeamSelection = nativeManager.snapshot?.phase {
                showTeamSelection = true
            }
        } catch {
            isAuthenticating = false
            authError = error.localizedDescription
        }
    }

    private func selectTeam(_ teamID: String, operationID: UUID) async {
        do {
            try await nativeManager.selectTeam(identifier: teamID, operationID: operationID)
            showTeamSelection = false
            pendingOperation = nil
        } catch {
            authError = error.localizedDescription
        }
    }

    private func submitTwoFactor(_ challenge: SideSignTwoFactorBroker.Challenge) async {
        guard let operation = pendingOperation else { return }
        // The challenge travels beside the response: `submitTwoFactor` takes the
        // challenge id as its own argument, and `TwoFactorResponse` carries only the code.
        let response = TwoFactorResponse.verificationCode(twoFactorCode)
        do {
            _ = try await nativeManager.submitTwoFactor(response, operationID: operation.id, challengeID: challenge.id)
            twoFactorCode = ""
            pendingChallenge = nil
            // Check if team selection is next
            if case .awaitingTeamSelection = nativeManager.snapshot?.phase {
                showTeamSelection = true
            }
        } catch {
            authError = error.localizedDescription
        }
    }
}

// MARK: - Supporting Views

private struct AppleIDLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var appleID: String
    @Binding var password: String
    @Binding var xcodeVersion: String
    @Binding var isAuthenticating: Bool
    @Binding var authError: String?
    let onSubmit: () -> Void
    @State private var providerConsent = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(.localized("Apple ID"), text: $appleID)
                        .textContentType(.username)
                        .autocapitalization(.none)
                    SecureField(.localized("Password"), text: $password)
                        .textContentType(.password)
                    TextField(.localized("Xcode Version"), text: $xcodeVersion)
                    Toggle(.localized("I approve using the selected anisette provider"), isOn: $providerConsent)
                } header: {
                    Text(.localized("Credentials"))
                } footer: {
                    Text(.localized("Your password is used to authenticate with Apple. The selected anisette provider receives provisioning and device metadata, not your Apple ID or password. Session tokens may be saved in device-only Keychain storage."))
                        .font(.caption)
                }

                if let error = authError {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(.localized("Sign in with Apple ID"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(.localized("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(.localized("Sign In")) { onSubmit() }
                        .disabled(appleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty || isAuthenticating || !providerConsent)
                }
            }
            .overlay {
                if isAuthenticating {
                    ProgressView(.localized("Authenticating…"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.1))
                }
            }
        }
        .presentationDetents([.large])
    }
}

private struct TeamSelectionView: View {
    let teams: [NativeAccountTeam]
    let onSelect: (String) -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(teams, id: \.identifier) { team in
                    Button {
                        onSelect(team.identifier)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(team.identifier)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text(team.membership.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: team.membership == .free ? "person" : "checkmark.seal")
                                .foregroundStyle(team.membership == .free ? .orange : .green)
                        }
                    }
                }
            }
            .navigationTitle(.localized("Select Team"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(.localized("Cancel")) { onSelect("") }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - TrollStore Views

private struct TrollStoreInstallView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var downloadManager = DownloadManager.shared
    @State private var selectedDownload: Download?
    @State private var showDownloadPicker = false
    @State private var installError: String?
    @State private var isInstalling = false

    private var signedDownloads: [Download] {
        downloadManager.downloads.filter { $0.phase == .completed && !$0.onlyArchiving }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "t.square.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Color.accentColor)

                Text(.localized("Install via TrollStore"))
                    .font(.title2.weight(.semibold))

                Text(.localized("Select a signed IPA to install permanently via TrollStore. The app must already be signed with a valid certificate."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if signedDownloads.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tray")
                            .font(.system(size: 36))
                            .foregroundStyle(.secondary)
                        Text(.localized("No signed IPAs available"))
                            .font(.headline)
                        Text(.localized("Sign an app first, then return here to install via TrollStore."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                } else {
                    List {
                        ForEach(signedDownloads, id: \.id) { download in
                            Button {
                                selectedDownload = download
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(download.fileName)
                                            .font(.headline)
                                            .foregroundStyle(.primary)
                                        Text(download.appDescription ?? "")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if selectedDownload?.id == download.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 300)
                }

                if let download = selectedDownload {
                    Button {
                        Task { await installViaTrollStore(download) }
                    } label: {
                        if isInstalling {
                            HStack {
                                ProgressView().scaleEffect(0.8)
                                Text(.localized("Opening TrollStore…"))
                            }
                        } else {
                            Label(String.localized("Open %@ in TrollStore", arguments: download.fileName), systemImage: "t.square.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isInstalling)

                    Button {
                        share(download)
                    } label: {
                        Label(.localized("Share Signed IPA Instead"), systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)

                    // The hand-off is a request to another app. Nothing here can
                    // observe whether TrollStore finished installing it.
                    Text(.localized("TrollStore performs the install itself. VexSign cannot confirm the result — check TrollStore, then launch the app."))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if let error = installError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding()
            .navigationTitle(.localized("TrollStore Install"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(.localized("Cancel")) { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }

    private func installViaTrollStore(_ download: Download) async {
        isInstalling = true
        installError = nil
        defer { isInstalling = false }

        // Same resolution order DownloadManager uses: the retained package first,
        // then the staged download. `Download` has no localURL property.
        guard let ipaURL = download.retainedPackageURL ?? download.pendingFileURL else {
            installError = .localized("Signed IPA file not found")
            return
        }
        guard FileManager.default.fileExists(atPath: ipaURL.path) else {
            installError = .localized("Signed IPA file not found")
            return
        }

        // TrollStore answers on Apple's Magnifier scheme; `trollstore://` is not
        // registered by any TrollStore release. The URL builder keeps the IPA's
        // own query intact, and the outcome stays a hand-off: iOS opening the URL
        // is not evidence that TrollStore installed anything.
        switch await TrollStoreHandoff.handOff(ipaURL: ipaURL) {
        case .openedUnverified:
            dismiss()
        case .openFailed:
            installError = .localized("iOS refused to open the TrollStore hand-off URL, so nothing was installed.")
        }
    }

    /// Share sheet, so the signed IPA can be handed to TrollStore even when the
    /// scheme is off or this copy of the app cannot locate TrollStore.
    private func share(_ download: Download) {
        guard let ipaURL = download.retainedPackageURL ?? download.pendingFileURL,
              FileManager.default.fileExists(atPath: ipaURL.path) else {
            installError = .localized("Signed IPA file not found")
            return
        }
        UIActivityViewController.show(activityItems: [ipaURL])
    }
}

private struct TrollStoreRefreshView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isOpening = false
    @State private var openFailed = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 48))
                    .foregroundStyle(Color.accentColor)

                Text(.localized("Refresh All Apps in TrollStore"))
                    .font(.title2.weight(.semibold))

                // TrollStore has no URL command for a refresh: `TSSceneDelegate`
                // only handles install and enable-jit. Claiming to have triggered
                // one would be inventing work that never happened.
                Text(.localized("VexSign cannot start a refresh for you — TrollStore does not accept a URL command for it. Open TrollStore, then use Refresh All App Registrations there. Only apps TrollStore installed are affected."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button {
                    Task { await openTrollStore() }
                } label: {
                    if isOpening {
                        HStack {
                            ProgressView().scaleEffect(0.8)
                            Text(.localized("Opening…"))
                        }
                    } else {
                        Label(.localized("Open TrollStore"), systemImage: "arrow.up.forward.app")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isOpening)

                if openFailed {
                    Text(.localized("iOS did not open the URL. TrollStore may not be installed, or its URL Scheme setting is off."))
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
            .padding()
            .navigationTitle(.localized("TrollStore Refresh"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(.localized("Cancel")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func openTrollStore() async {
        isOpening = true
        openFailed = false
        defer { isOpening = false }

        guard let url = URL(string: "\(TrollStoreHandoff.scheme)://") else {
            openFailed = true
            return
        }
        let outcome = await TrollStoreHandoff.open(url)
        if outcome == .openFailed {
            openFailed = true
        }
    }
}

// MARK: - Extensions

extension NativeAccountPhase {
    var icon: String {
        switch self {
        case .signedOut: return "person.crop.circle.badge.xmark"
        case .authenticating: return "person.crop.circle.badge.questionmark"
        case .awaitingTwoFactor: return "person.crop.circle.badge.exclamationmark"
        case .awaitingTeamSelection: return "person.2.fill"
        case .signedIn: return "person.crop.circle.fill.badge.checkmark"
        case .expired: return "person.crop.circle.badge.clock"
        }
    }

    var color: Color {
        switch self {
        case .signedOut: return .secondary
        case .authenticating, .awaitingTwoFactor, .awaitingTeamSelection: return .orange
        case .signedIn: return .green
        case .expired: return .red
        }
    }

    var displayTitle: String {
        switch self {
        case .signedOut: return .localized("Signed Out")
        case .authenticating: return .localized("Authenticating…")
        case .awaitingTwoFactor: return .localized("Two-Factor Required")
        case .awaitingTeamSelection: return .localized("Select Team")
        case .signedIn(let context): return .localized("Signed In: %@", arguments: context.team.identifier)
        case .expired: return .localized("Session Expired")
        }
    }
}

extension NativeAccountMembership {
    var displayName: String {
        switch self {
        case .free: return .localized("Free")
        case .paidVerified: return .localized("Paid (Verified)")
        case .developerProgramUnverified: return .localized("Developer Program (Unverified)")
        }
    }
}