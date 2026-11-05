// MARK: - SigningMethodsView
/// Primary entry point for selecting and configuring a signing method.
/// Integrates paid certificates, free Apple ID (NativeSigning), and TrollStore.

import SwiftUI
import NimbleViews
import NimbleExtensions
import NativeSigning
import SideSign

struct SigningMethodsView: View {
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
                .disabled(!(nativeManager.snapshot?.phase.isSignedIn ?? false))

                if let error = nativeManager.lastError {
                    Text(error)
                        .font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text(.localized("Diagnostics"))
            }
        }
        .sheet(isPresented: $showAppleIDLogin) {
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
        .alert(.localized("Two-Factor Authentication"), isPresented: .constant(pendingChallenge != nil), presenting: pendingChallenge) { challenge in
            TextField(.localized("6-digit code"), text: $twoFactorCode)
            Button(.localized("Cancel"), role: .cancel) {
                pendingChallenge = nil
            }
            Button(.localized("Submit")) {
                Task { await submitTwoFactor(challenge) }
            }
            .disabled(twoFactorCode.count != 6)
        } message: { challenge in
            Text(.localized("Enter the verification code sent to your trusted device"))
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
                    .foregroundStyle(isSelected ? .accentColor : .secondary)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(method.displayName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(method.shortDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if availability.isAvailable {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? .accentColor : .secondary)
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
                            Text(.localized("Team: %@ (%@)", arguments: context.team.identifier, context.team.membership.displayName))
                                .font(.caption).foregroundStyle(.secondary)
                            // 3-app limit indicator
                            HStack(spacing: 4) {
                                Image(systemName: "app.badge")
                                    .font(.caption2)
                                Text(.localized("%lld/3 apps used", arguments: nativeManager.freeAccountAppCount))
                                    .font(.caption)
                            }
                            .foregroundStyle(nativeManager.freeAccountAppCount >= 3 ? .red : .secondary)
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
                    .buttonStyle(NBButtonStyle(.prominent))
                    .disabled(nativeManager.freeAccountAppCount >= 3)

                    if nativeManager.freeAccountAppCount >= 3 {
                        Text(.localized("App limit reached (3/3). Revoke an app or wait for expiry."))
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Button(role: .destructive) {
                        Task { try? await nativeManager.signOut() } // try? ok: sign out is best-effort, UI reflects state
                    } label: {
                        Label(.localized("Sign Out"), systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .buttonStyle(NBButtonStyle(.bordered))
                }
            } else {
                // Not signed in - show login
                Button {
                    showAppleIDLogin = true
                } label: {
                    Label(.localized("Sign in with Apple ID"), systemImage: "person.crop.circle.badge.plus")
                }
                .buttonStyle(NBButtonStyle(.prominent))
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
                Label(.localized("TrollStore detected — permanent installation available"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline)

                Text(.localized("TrollStore allows permanent, certificate-free installation of signed IPAs on iOS 14.0–16.6.1. No 7-day expiry, no Apple ID needed."))
                    .font(.caption).foregroundStyle(.secondary)

                Button {
                    showTrollStoreInstall = true
                } label: {
                    Label(.localized("Install App via TrollStore"), systemImage: "t.square.fill")
                }
                .buttonStyle(NBButtonStyle(.prominent))

                Button {
                    showTrollStoreRefresh = true
                } label: {
                    Label(.localized("Refresh All (TrollStore)"), systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(NBButtonStyle(.bordered))
            } else {
                Label(.localized("TrollStore not available on this device"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.subheadline)

                Text(.localized("TrollStore requires iOS 14.0–16.6.1 and a separate installation. VexSign can detect it but cannot install it."))
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
    @Binding var appleID: String
    @Binding var password: String
    @Binding var xcodeVersion: String
    @Binding var isAuthenticating: Bool
    @Binding var authError: String?
    let onSubmit: () -> Void

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
                } header: {
                    Text(.localized("Credentials"))
                } footer: {
                    Text(.localized("Your Apple ID and password are used only for authentication with Apple's servers. They are never stored, logged, or sent to any third party."))
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
                    Button(.localized("Cancel")) { onSubmit = {} }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(.localized("Sign In")) { onSubmit() }
                        .disabled(appleID.isEmpty || password.isEmpty || isAuthenticating)
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
        .presentationDetents([.medium])
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
                    .foregroundStyle(.accentColor)

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
                                            .foregroundStyle(.accentColor)
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
                                Text(.localized("Installing…"))
                            }
                        } else {
                            Label(.localized("Install %@", arguments: download.fileName), systemImage: "t.square.fill")
                        }
                    }
                    .buttonStyle(NBButtonStyle(.prominent))
                    .disabled(isInstalling)
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

        // Use TrollStore's URL scheme
        guard var components = URLComponents(url: URL(string: "trollstore://install")!, resolvingAgainstBaseURL: false) else {
            installError = .localized("Invalid TrollStore URL")
            return
        }
        components.queryItems = [URLQueryItem(name: "url", value: ipaURL.absoluteString)]
        guard let installURL = components.url else {
            installError = .localized("Failed to create install URL")
            return
        }

        let success = await UIApplication.shared.open(installURL)
        if !success {
            installError = .localized("TrollStore installation failed or was cancelled")
        } else {
            dismiss()
        }
    }
}

private struct TrollStoreRefreshView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isRefreshing = false
    @State private var refreshResult: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 48))
                    .foregroundStyle(.accentColor)

                Text(.localized("Refresh All Apps via TrollStore"))
                    .font(.title2.weight(.semibold))

                Text(.localized("This will trigger TrollStore to refresh all installed apps, extending their validity. Requires TrollStore to be installed and accessible."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button {
                    Task { await refreshAll() }
                } label: {
                    if isRefreshing {
                        HStack {
                            ProgressView().scaleEffect(0.8)
                            Text(.localized("Refreshing…"))
                        }
                    } else {
                        Label(.localized("Refresh All"), systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .buttonStyle(NBButtonStyle(.prominent))
                .disabled(isRefreshing)

                if let result = refreshResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(.green)
                }

                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
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

    private func refreshAll() async {
        isRefreshing = true
        refreshResult = nil
        errorMessage = nil
        defer { isRefreshing = false }

        guard let url = URL(string: "trollstore://refresh") else {
            errorMessage = .localized("Invalid TrollStore URL")
            return
        }

        let success = await UIApplication.shared.open(url)
        if success {
            refreshResult = .localized("Refresh triggered successfully. Check TrollStore for progress.")
        } else {
            errorMessage = .localized("Failed to trigger refresh. Is TrollStore installed?")
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
        case .expired(let date): return .localized("Session Expired")
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