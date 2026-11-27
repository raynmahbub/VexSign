// MARK: - Unified signing identities screen
//
// Reads the real certificate store and the real Keychain vault. Providers and
// networking are touched only through the adapter, never from a view body.

import SwiftUI
import NimbleViews
import NimbleExtensions

@MainActor
final class UnifiedIdentityModel: ObservableObject {
    @Published private(set) var identities: [UnifiedSigningIdentity] = []
    @Published private(set) var providerStatus: SigningProviderStatus?
    @Published private(set) var isBusy = false
    @Published var message: String?

    private let adapter = NexCertsProviderAdapter()

    func load(records: [CertificateRecord]) async {
        isBusy = true
        defer { isBusy = false }
        let inputs: [SigningIdentityStore.Input]
        do { inputs = try await SigningIdentityStore.snapshot() }
        catch {
            inputs = []
            message = .localized("The signing certificate store could not be read. No identity was claimed as usable.")
        }
        // `CertificateRecord.id` and `SigningIdentityStore.Input.reference` are
        // both the Core Data objectID URI. Joining on that avoids guessing from
        // display names, which may be identical across different certificates.
        let byReference = Dictionary(uniqueKeysWithValues: inputs.map { ($0.reference, $0) })
        let candidates = records.compactMap { record -> UnifiedIdentityCatalog.EngineCandidate? in
            guard let input = byReference[record.id] else { return nil }
            return .init(input: input, record: record)
        }
        let engine = UnifiedIdentityCatalog.engineIdentities(from: candidates)
        let vault = await CertificateVault().snapshot()
        let vaulted = UnifiedIdentityCatalog.vaultIdentities(
            certificates: vault.state.certificates,
            profiles: vault.state.profiles
        )
        identities = (engine + vaulted).sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        do { providerStatus = try await adapter.status() }
        catch { providerStatus = .init(provider: .communityNexCerts, state: .unavailable,
                                       detail: error.localizedDescription, checkedAt: Date()) }
        if let error = vault.loadError { message = error }
    }

    func disconnectCommunitySource() async {
        await run {
            try await adapter.disconnect()
            providerStatus = try await adapter.status()
            message = "Community source access turned off. Imported certificates were kept and are still usable."
        }
    }

    func cancelProviderWork() { adapter.cancel() }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do { try await operation() }
        catch { message = error.localizedDescription }
    }
}

struct UnifiedSigningIdentitiesView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @WorkspaceQuery(\.certificates, order: .newestFirst) private var records: [CertificateRecord]
    @StateObject private var model = UnifiedIdentityModel()
    @State private var showingVault = false

    var body: some View {
        NBNavigationView(.localized("Signing Identities"), displayMode: .inline) {
            List {
                if let message = model.message {
                    Section { Text(message).font(.footnote).foregroundStyle(.secondary) }
                }
                Section {
                    if model.identities.isEmpty {
                        Text(.localized("No identities yet. Import a certificate or a PKCS#12 and profile pair."))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.identities) { identity in
                        _identityRow(identity)
                    }
                } header: {
                    Text(.localized("Identities"))
                }
                Section {
                    if let status = model.providerStatus {
                        LabeledContent(.localized("Community source"), value: status.state.rawValue)
                        Text(status.detail).font(.footnote).foregroundStyle(.secondary)
                        if status.state != .notConfigured {
                            Button(role: .destructive) {
                                Task { await model.disconnectCommunitySource() }
                            } label: {
                                Text(.localized("Disconnect Community Source"))
                            }
                        }
                    }
                    Button {
                        showingVault = true
                    } label: {
                        Text(.localized("Open Keychain Certificate Vault"))
                    }
                } header: {
                    Text(.localized("Sources"))
                } footer: {
                    Text(.localized("Disconnecting turns off provider access. It does not revoke certificates or delete imported identities."))
                        .font(.footnote)
                }
            }
            .listStyle(.insetGrouped)
            .overlay { if model.isBusy { ProgressView() } }
            .task { await model.load(records: records) }
            .refreshable { await model.load(records: records) }
            .sheet(isPresented: $showingVault) {
                NavigationStack { CertificateVaultView() }
            }
            .alert(.localized("Signing Identities"), isPresented: Binding(
                get: { model.message != nil },
                set: { if !$0 { model.message = nil } }
            )) {
                Button(.localized("OK"), role: .cancel) { }
            } message: {
                Text(model.message ?? "")
            }
        }
    }

    @ViewBuilder
    private func _identityRow(_ identity: UnifiedSigningIdentity) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(identity.displayName).font(.headline)
                Spacer()
                Text(identity.validityState.displayName)
                    .font(.caption)
                    .foregroundStyle(identity.canStartNativeSigning ? .green : .orange)
            }
            LabeledContent(.localized("Source"), value: identity.source.displayName)
            LabeledContent(.localized("Type"), value: identity.certificateType.displayName)
            if let team = identity.teamIdentifier {
                LabeledContent(.localized("Team"), value: team)
            }
            if let fingerprint = identity.fingerprint {
                LabeledContent(.localized("Fingerprint"), value: String(fingerprint.prefix(12)).uppercased())
            }
            if let expiry = identity.notAfter {
                LabeledContent(.localized("Expires"), value: expiry.formatted(date: .abbreviated, time: .omitted))
            }
            LabeledContent(.localized("Private key"), value: identity.privateKeyAvailable
                ? .localized("Available") : .localized("Unavailable"))
            LabeledContent(.localized("Signing engine"), value: identity.engineReady
                ? .localized("Ready") : .localized("Not ready (vault-only)"))
            if !identity.capabilities.isEmpty {
                Text(identity.capabilities.prefix(8).joined(separator: ", "))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(identity.notices, id: \.self) { notice in
                Text(notice).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
