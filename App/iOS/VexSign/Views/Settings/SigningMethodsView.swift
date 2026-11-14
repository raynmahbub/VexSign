// MARK: - SigningMethodsView
/// Primary entry point for selecting and configuring a signing method.
/// Integrates paid certificates, free Apple ID (NativeSigning), and TrollStore.

import SwiftUI
import NimbleViews
import NimbleExtensions
import NativeSigning

struct SigningMethodsView: View {
    /// `NativeAccountPhase.isSignedIn` is internal to NativeSigning, so the case is
    /// matched here rather than read as a property.
    private var isSignedIn: Bool {
        guard let phase = nativeManager.snapshot?.phase else { return false }
        if case .signedIn = phase { return true }
        return false
    }

    @StateObject private var nativeManager = NativeSigningManager.shared
    @StateObject private var signingMode = SigningModeManager.shared
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
    @State private var pendingChallenge: NativeSigningManager.TwoFactorChallenge?
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
                    guard SigningMethodAvailability.current(for: .paidCertificate).isAvailable else { return }
                    selectedMethod = .paidCertificate
                    signingMode.selectPreference(.directPaid)
                }

                if selectedMethod == .paidCertificate {
                    NavigationLink(destination: CertificatesView()) {
                        Label(.localized("Manage Certificates"), systemImage: "checkmark.seal")
                    }
                    .disabled(!SigningMethodAvailability.current(for: .paidCertificate).isAvailable)

                    Text(.localized("Import a .p12 certificate and .mobileprovision profile. Selecting this method routes installs through the direct OTA/IDevice pipeline. Profile scope, entitlements and certificate validity still require signing preflight."))
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
                    signingMode.selectPreference(.containerized)
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
        .onAppear {
            switch signingMode.preference {
            case .directPaid: selectedMethod = .paidCertificate
            case .containerized: selectedMethod = .freeAppleID
            case .automatic: break
            }
        }
        .task {
            await nativeManager.synchronizeProvider()
            await nativeManager.refreshRenewalCandidates()
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
        } message: { _ in
            Text(.localized("Enter the verification code sent to your trusted device"))
        }
        .task(id: pendingOperation?.id) {
            guard let operation = pendingOperation else { return }
            // Authentication continues after startAuthentication returns. Consume
            // its buffered challenges instead of checking one early snapshot.
            for await challenge in nativeManager.challenges(for: operation) {
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
                    if let reason = availability.availabilityReason {
                        Text(reason)
                            .font(.caption2)
                            .foregroundStyle(availability.isAvailable ? Color.secondary : Color.orange)
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

            if case .signedIn = nativeManager.snapshot?.phase {
                VStack(spacing: 12) {
                    Button {
                        showProvisioningFlow = true
                    } label: {
                        Label(.localized("Provision & Sign App"), systemImage: "signature")
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        Task { await nativeManager.refreshRenewalCandidates() }
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

            Divider()
            AnisetteProviderConfigView()

            Text(.localized("Free Apple ID: 3 apps per 7 days with weekly profile refresh and limited entitlements. Selecting this method routes app installs to the embedded LiveContainer host; the combined runtime must be loaded. Account sign-in alone does not import or install a guest."))
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

            if case .awaitingTwoFactor = nativeManager.snapshot?.phase {
                showTeamSelection = false
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

    private func submitTwoFactor(_ challenge: NativeSigningManager.TwoFactorChallenge) async {
        guard let operation = pendingOperation else { return }
        do {
            _ = try await nativeManager.submitTwoFactorCode(
                twoFactorCode,
                operationID: operation.id,
                challengeID: challenge.id
            )
            twoFactorCode = ""
            pendingChallenge = nil
            if case .awaitingTeamSelection = nativeManager.snapshot?.phase {
                showTeamSelection = true
            }
        } catch {
            authError = error.localizedDescription
        }
    }
}
