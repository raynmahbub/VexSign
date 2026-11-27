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
            message = String.localized("The signing certificate store could not be read. No identity was claimed as usable.")
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
            try await self.adapter.disconnect()
            self.providerStatus = try await self.adapter.status()
            self.message = "Community source access turned off. Imported certificates were kept and are still usable."
        }
    }

    func cancelProviderWork() { Task { await self.adapter.cancel() } }

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
        NBNavigationView(String.localized("Signing Identities"), displayMode: .inline) {
            List {
                if let message = model.message {
                    Section { Text(message).font(.footnote).foregroundStyle(.secondary) }
                }
                Section {
                    if model.identities.isEmpty {
                        Text(String.localized("No identities yet. Import a certificate or a PKCS#12 and profile pair."))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.identities) { identity in
                        _identityRow(identity)
                    }
                } header: {
                    Text(String.localized("Identities"))
                }
                Section {
                    if let status = model.providerStatus {
                        LabeledContent(String.localized("Community source"), value: status.state.rawValue)
                        Text(status.detail).font(.footnote).foregroundStyle(.secondary)
                        if status.state != .notConfigured {
                            Button(role: .destructive) {
                                Task { await model.disconnectCommunitySource() }
                            } label: {
                                Text(String.localized("Disconnect Community Source"))
                            }
                        }
                    }
                    Button {
                        showingVault = true
                    } label: {
                        Text(String.localized("Open Keychain Certificate Vault"))
                    }
                } header: {
                    Text(String.localized("Sources"))
                } footer: {
                    Text(String.localized("Disconnecting turns off provider access. It does not revoke certificates or delete imported identities."))
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
            .alert(String.localized("Signing Identities"), isPresented: Binding(
                get: { model.message != nil },
                set: { if !$0 { model.message = nil } }
            )) {
                Button(String.localized("OK"), role: .cancel) { }
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
            LabeledContent(String.localized("Source"), value: identity.source.displayName)
            LabeledContent(String.localized("Type"), value: identity.certificateType.displayName)
            if let team = identity.teamIdentifier {
                LabeledContent(String.localized("Team"), value: team)
            }
            if let fingerprint = identity.fingerprint {
                LabeledContent(String.localized("Fingerprint"), value: String(fingerprint.prefix(12)).uppercased())
            }
            if let expiry = identity.notAfter {
                LabeledContent(String.localized("Expires"), value: expiry.formatted(date: .abbreviated, time: .omitted))
            }
            LabeledContent(String.localized("Private key"), value: identity.privateKeyAvailable
                ? String.localized("Available") : String.localized("Unavailable"))
            LabeledContent(String.localized("Signing engine"), value: identity.engineReady
                ? String.localized("Ready") : String.localized("Not ready (vault-only)"))
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
