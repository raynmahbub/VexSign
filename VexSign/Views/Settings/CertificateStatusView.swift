// MARK: - CertificateStatusView
/// UI for certificate revocation status (OCSP/CRL) checking and consent management.

import SwiftUI
import NimbleViews
import NimbleExtensions
import NativeSigning

struct CertificateStatusView: View {
    @StateObject private var manager = NativeSigningManager.shared
    @State private var selectedIdentity: NativeSigningManager.SigningIdentity?
    @State private var showConsentSheet = false
    @State private var statusResults: [UUID: NativeAccountCertificateStatus] = [:]
    @State private var isChecking = false
    @State private var isLoadingIdentities = false
    @State private var errorMessage: String?
    @State private var identities: [NativeSigningManager.SigningIdentity] = []

    var body: some View {
        NBList(.localized("Certificate Status")) {
            Section {
                if let snapshot = manager.snapshot,
                   case .signedIn(let context) = snapshot.phase {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(.localized("Active Context"))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text("Team: \(context.team.identifier)")
                            .font(.subheadline.weight(.medium))
                        Text("Expires: \(context.expiresAt?.formatted() ?? .localized("Unknown"))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } else {
                    Text(.localized("Sign in with a Free Apple ID to check certificate status."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(.localized("Current Session"))
            }

            Section {
                if !identities.isEmpty {
                    ForEach(identities) { identity in
                        CertificateStatusRow(
                            identity: identity,
                            status: statusResults[identity.identityID]?.status ?? .unknown,
                            lastChecked: statusResults[identity.identityID]?.checkedAt,
                            onCheck: { checkIdentity(identity) },
                            onConsent: { requestConsentForIdentity(identity) }
                        )
                    }
                } else if manager.isBackendReady {
                    if isLoadingIdentities {
                        HStack {
                            ProgressView().scaleEffect(0.8)
                            Text(.localized("Loading identities…"))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "checkmark.seal")
                                .font(.system(size: 36))
                                .foregroundStyle(.secondary)
                            Text(.localized("No signing identities found"))
                                .font(.headline)
                            Text(.localized("Create a signing identity by provisioning an app first."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Button {
                                loadIdentities()
                            } label: {
                                Label(.localized("Refresh"), systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(NBButtonStyle(.bordered))
                        }
                        .padding()
                    }
                } else {
                    Text(.localized("Native signing backend not initialized. Configure Anisette Provider first."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(.localized("Certificate Status"))
            } footer: {
                Text(.localized("Certificate status checks use Apple's OCSP/CRL responders. Positive cached responses are required; missing or unknown status never counts as valid. Explicit consent is required for each check."))
            }

            Section {
                if !identities.isEmpty {
                    Button {
                        checkAllIdentities()
                    } label: {
                        if isChecking {
                            HStack {
                                ProgressView().scaleEffect(0.8)
                                Text(.localized("Checking All…"))
                            }
                        } else {
                            Label(.localized("Check All Certificates"), systemImage: "checkmark.shield")
                        }
                    }
                    .buttonStyle(NBButtonStyle(.prominent))
                    .disabled(isChecking)
                }

                Button {
                    loadIdentities()
                } label: {
                    Label(.localized("Refresh Identities"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(NBButtonStyle(.bordered))
                .disabled(isLoadingIdentities)

                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .task {
            await loadIdentities()
        }
        .sheet(isPresented: $showConsentSheet) {
            if let identity = selectedIdentity {
                CertificateStatusConsentView(
                    identityName: identity.displayName,
                    onConfirm: {
                        Task { await performStatusCheck(for: identity) }
                    }
                )
            }
        }
        .alert(.localized("Error"), isPresented: .constant(errorMessage != nil), presenting: errorMessage) { _ in
            Button(.localized("OK")) { errorMessage = nil }
        } message: { msg in
            Text(msg)
        }
    }

    @MainActor
    private func loadIdentities() async {
        isLoadingIdentities = true
        defer { isLoadingIdentities = false }
        identities = await manager.listSigningIdentities()
    }

    private func checkAllIdentities() {
        for identity in identities {
            checkIdentity(identity)
        }
    }

    private func checkIdentity(_ identity: NativeSigningManager.SigningIdentity) {
        guard let contextID = getContextID() else { return }
        selectedIdentity = identity
        showConsentSheet = true
    }

    private func requestConsentForIdentity(_ identity: NativeSigningManager.SigningIdentity) {
        checkIdentity(identity)
    }

    private func getContextID() -> UUID? {
        guard case .signedIn(let context) = manager.snapshot?.phase else { return nil }
        return context.id
    }

    @MainActor
    private func performStatusCheck(for identity: NativeSigningManager.SigningIdentity) async {
        isChecking = true
        errorMessage = nil
        defer { isChecking = false }

        do {
            guard let contextID = getContextID() else {
                errorMessage = .localized("No active signing context")
                return
            }
            let result = try await manager.evaluateCertificateStatus(
                contextID: contextID,
                identityID: identity.identityID,
                consent: nil // Will be provided by consent view
            )
            statusResults[identity.identityID] = result
        } catch {
            errorMessage = manager.mapError(error, context: .certificateStatus).message
        }
    }
}

private struct CertificateStatusRow: View {
    let identityName: String
    let status: NativeAccountCertificateStatus.Status
    let lastChecked: Date?
    let onCheck: () -> Void
    let onConsent: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: status.icon)
                    .foregroundStyle(status.color)
                    .font(.title2)
                VStack(alignment: .leading) {
                    Text(identityName)
                        .font(.headline)
                    Text(status.displayName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(status.color)
                }
                Spacer()
            }

            if let checked = lastChecked {
                Text("\(String.localized("Last checked")): \(checked.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button {
                    onConsent()
                } label: {
                    Label(.localized("Request Consent & Check"), systemImage: "hand.raised.fill")
                }
                .buttonStyle(NBButtonStyle(.borderedProminent))

                Button {
                    onCheck()
                } label: {
                    Label(.localized("Refresh"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(NBButtonStyle(.bordered))
            }
        }
        .padding()
        .background(Color(uiColor: .quaternarySystemFill))
        .cornerRadius(14)
    }
}

private struct CertificateStatusConsentView: View {
    let identityName: String
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var consentGiven = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.orange)

                        Text(.localized("Certificate Status Consent Required"))
                            .font(.title2.weight(.bold))

                        Text(.localized("Checking the revocation status of **\(identityName)** requires explicit consent for network disclosure to Apple's OCSP/CRL responders."))
                            .font(.body)

                        Text(.localized("This will:"))
                            .font(.headline)
                        VStack(alignment: .leading, spacing: 8) {
                            Label(.localized("Send certificate serial/issuer to Apple's OCSP responder"), systemImage: "network")
                            Label(.localized("Query CRL distribution points if OCSP unavailable"), systemImage: "doc.text.magnifyingglass")
                            Label(.localized("Require positive cached response (no network fetch)"), systemImage: "lock.shield")
                        }
                        .font(.subheadline)

                        Text(.localized("Missing or unknown status never counts as valid. This consent is single-use and expires in 2 minutes."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }

                Section {
                    Toggle(.localized("I understand and consent to this status check"), isOn: $consentGiven)
                }
            }
            .navigationTitle(.localized("Status Consent"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(.localized("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(.localized("Allow")) {
                        onConfirm()
                        dismiss()
                    }
                    .disabled(!consentGiven)
                }
            }
        }
        .presentationDetents([.large])
    }
}

// MARK: - Extensions

extension NativeAccountCertificateStatus.Status {
    var icon: String {
        switch self {
        case .good: return "checkmark.shield.fill"
        case .revoked: return "xmark.shield.fill"
        case .expired: return "clock.shield.fill"
        case .unknown: return "questionmark.shield.fill"
        case .ocspUnavailable: return "wifi.slash"
        case .crlUnavailable: return "doc.text.magnifyingglass"
        }
    }

    var color: Color {
        switch self {
        case .good: return .green
        case .revoked: return .red
        case .expired: return .orange
        case .unknown: return .secondary
        case .ocspUnavailable: return .orange
        case .crlUnavailable: return .orange
        }
    }

    var displayName: String {
        switch self {
        case .good: return .localized("Valid")
        case .revoked: return .localized("Revoked")
        case .expired: return .localized("Expired")
        case .unknown: return .localized("Unknown")
        case .ocspUnavailable: return .localized("OCSP Unavailable")
        case .crlUnavailable: return .localized("CRL Unavailable")
        }
    }
}