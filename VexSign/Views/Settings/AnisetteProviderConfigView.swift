// MARK: - AnisetteProviderConfigView
/// Configuration UI for the anisette provider (required for free Apple ID authentication).

import SwiftUI
import NimbleViews
import NimbleExtensions
import NativeSigning

struct AnisetteProviderConfigView: View {
    @StateObject private var factory = AnisetteProviderFactory.shared
    @State private var showEndpointEditor = false
    @State private var endpointString = ""
    @State private var identity = "vexsign.local"
    @State private var displayName = "Custom Anisette Server"
    @State private var policyRevision = "1"
    @State private var protocolKind: AnisetteProviderDescriptor.ProtocolKind = .headers
    @State private var testResult: String?
    @State private var isTesting = false
    @State private var catalog: AnisetteServerCatalog?
    @State private var catalogError: String?
    @State private var verifyBeforeSaving = false
    @State private var configurationTask: Task<Void, Never>?
    @State private var configurationRevision = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "server.rack")
                    .foregroundStyle(Color.accentColor)
                Text(.localized("Anisette Provider"))
                    .font(.headline)
            }

            if factory.isConfigured, let descriptor = factory.currentDescriptor {
                // Configured state
                VStack(alignment: .leading, spacing: 8) {
                    Label(descriptor.displayName, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)

                    Text("Endpoint: \(descriptor.endpoint?.absoluteString ?? "On-device")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack {
                        Button {
                            fillEditor(from: descriptor)
                            showEndpointEditor = true
                        } label: {
                            Label(.localized("Edit"), systemImage: "pencil")
                        }
                        .buttonStyle(.bordered)

                        Button(role: .destructive) {
                            factory.clearConfiguration()
                            Task { await NativeSigningManager.shared.synchronizeProvider() }
                        } label: {
                            Label(.localized("Remove"), systemImage: "trash")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            testProvider()
                        } label: {
                            if isTesting {
                                ProgressView().scaleEffect(0.8)
                            } else {
                                Label(.localized("Test"), systemImage: "checkmark.shield")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isTesting)
                    }

                    if let result = testResult {
                        Text(result)
                            .font(.caption)
                            .foregroundStyle(result.contains("✅") ? .green : .red)
                    }
                }
            } else {
                // Not configured state
                VStack(alignment: .leading, spacing: 8) {
                    Text(.localized("No anisette provider configured. Free Apple ID authentication requires an anisette server."))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button {
                        verifyBeforeSaving = false
                        showEndpointEditor = true
                    } label: {
                        Label(.localized("Configure Provider"), systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            DisclosureGroup(.localized("Community anisette servers")) {
                Text(.localized("Reference list, not verified providers. Presets are activated only after the selected protocol completes its check; there is no automatic failover or contact with every server."))
                    .font(.caption).foregroundStyle(.secondary)
                if let catalog {
                    ForEach(catalog.servers) { server in
                        Button {
                            endpointString = server.address
                            displayName = server.name
                            identity = "catalog." + (server.secureEndpoint?.host ?? "invalid")
                            policyRevision = "catalog-" + String(catalog.sourceRevision.prefix(12))
                            protocolKind = .v3
                            verifyBeforeSaving = true
                            testResult = nil
                            showEndpointEditor = true
                        } label: {
                            VStack(alignment: .leading) {
                                Text(server.name)
                                Text(server.address).font(.caption).foregroundStyle(.secondary)
                                if server.secureEndpoint == nil {
                                    Text(.localized("Blocked: HTTPS is required")).font(.caption).foregroundStyle(.orange)
                                }
                            }
                        }
                        .disabled(server.secureEndpoint == nil || isTesting)
                    }
                    Text(String.localized("Catalogue reviewed %@; availability and operators are not verified.", arguments: catalog.reviewedAt))
                        .font(.caption).foregroundStyle(.secondary)
                    Link(.localized("Catalogue source and license"), destination: URL(string: "https://github.com/SideStore/anisette-servers")!)
                }
                if let catalogError { Text(catalogError).font(.caption).foregroundStyle(.red) }
            }
        }
        .padding()
        .background(Color(uiColor: .quaternarySystemFill))
        .cornerRadius(14)
        .task {
            do { catalog = try AnisetteServerCatalog.bundled() }
            catch { catalogError = error.localizedDescription }
        }
        .onDisappear { cancelConfiguration() }
        .sheet(isPresented: $showEndpointEditor, onDismiss: { cancelConfiguration() }) {
            AnisetteEndpointEditorView(
                endpointString: $endpointString,
                identity: $identity,
                displayName: $displayName,
                policyRevision: $policyRevision,
                protocolKind: $protocolKind,
                isSaving: isTesting,
                verifyBeforeSaving: verifyBeforeSaving,
                error: testResult,
                onSave: { endpoint, id, name, revision in
                    guard !isTesting else { return }
                    configurationRevision += 1
                    let configurationID = configurationRevision
                    isTesting = true
                    testResult = nil
                    configurationTask = Task { @MainActor in
                        defer { if configurationRevision == configurationID { isTesting = false } }
                        do {
                            let url = try validateEndpoint(endpoint)
                            if verifyBeforeSaving {
                                let descriptor = try AnisetteProviderDescriptor(identifier: id,
                                    displayName: name, policyRevision: revision, endpoint: url, protocolKind: protocolKind)
                                if protocolKind == .v3 {
                                    let provider = try NativeV3AnisetteProvider(descriptor: descriptor)
                                    _ = try await provider.freshHeaders()
                                } else {
                                    let provider = try HTTPSAnisetteProvider<SystemAnisetteHeaderTransport>(descriptor: descriptor)
                                    _ = try await provider.freshHeaders()
                                }
                            }
                            try Task.checkCancellation()
                            try factory.configureHTTPS(endpoint: url, identity: id, displayName: name, policyRevision: revision, protocolKind: protocolKind)
                            await NativeSigningManager.shared.synchronizeProvider()
                            guard !Task.isCancelled, configurationRevision == configurationID else { return }
                            showEndpointEditor = false
                        } catch is CancellationError {
                            // Dismissing the editor must not activate a provider afterwards.
                        } catch {
                            if !Task.isCancelled, configurationRevision == configurationID {
                                testResult = "❌ \(error.localizedDescription)"
                            }
                        }
                    }
                }
            )
            .presentationDetents([.medium])
        }
    }

    private func cancelConfiguration() {
        configurationRevision += 1
        configurationTask?.cancel()
        configurationTask = nil
        isTesting = false
    }

    private func fillEditor(from descriptor: AnisetteProviderDescriptor) {
        verifyBeforeSaving = false
        testResult = nil
        endpointString = descriptor.endpoint?.absoluteString ?? ""
        identity = descriptor.identifier
        displayName = descriptor.displayName
        policyRevision = descriptor.policyRevision
        protocolKind = descriptor.protocolKind
    }

    private func validateEndpoint(_ string: String) throws -> URL {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw URLError(.badURL) }
        guard let url = URL(string: trimmed) else { throw URLError(.badURL) }
        guard url.scheme?.lowercased() == "https" else {
            throw NSError(domain: "VexSign", code: -1, userInfo: [NSLocalizedDescriptionKey: "Endpoint must use HTTPS"])
        }
        return url
    }

    private func testProvider() {
        guard let descriptor = factory.currentDescriptor else { return }
        isTesting = true
        testResult = nil

        Task {
            do {
                if descriptor.protocolKind == .v3 {
                    let provider = try NativeV3AnisetteProvider(descriptor: descriptor)
                    _ = try await provider.freshHeaders()
                } else {
                    let provider = try HTTPSAnisetteProvider<SystemAnisetteHeaderTransport>(descriptor: descriptor)
                    _ = try await provider.freshHeaders()
                }
                await MainActor.run {
                    testResult = "✅ Provider test successful"
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    testResult = "❌ \(error.localizedDescription)"
                    isTesting = false
                }
            }
        }
    }
}

private struct AnisetteEndpointEditorView: View {
    @Binding var endpointString: String
    @Binding var identity: String
    @Binding var displayName: String
    @Binding var policyRevision: String
    @Binding var protocolKind: AnisetteProviderDescriptor.ProtocolKind
    let isSaving: Bool
    let verifyBeforeSaving: Bool
    let error: String?
    let onSave: (String, String, String, String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(.localized("Anisette protocol"), selection: $protocolKind) {
                        Text(.localized("HTTPS JSON headers")).tag(AnisetteProviderDescriptor.ProtocolKind.headers)
                        Text(.localized("Anisette v3 provisioning")).tag(AnisetteProviderDescriptor.ProtocolKind.v3)
                    }
                    TextField(.localized("HTTPS Endpoint URL"), text: $endpointString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text(.localized("Server Endpoint"))
                } footer: {
                    Text(.localized("Choose the protocol supported by the operator. Header mode requires JSON headers; v3 uses a WSS provisioning exchange and stores a provider-bound ADI identity in device-only Keychain."))
                }

                if let error { Text(error).foregroundStyle(.red) }
                if isSaving { ProgressView(.localized("Checking provider compatibility…")) }
                if verifyBeforeSaving {
                    Text(.localized("Save & Verify contacts the selected operator. In v3 mode this performs ADI provisioning with Apple and the operator, and stores its pseudonymous identifier and ADI blob in device-only Keychain. No Apple ID password, 2FA code or account session is sent to that operator. It does not sign in to your Apple account. Failed checks keep the previous provider."))
                        .font(.caption)
                }
                Section {
                    TextField(.localized("Identity"), text: $identity)
                    TextField(.localized("Display Name"), text: $displayName)
                    TextField(.localized("Policy Revision"), text: $policyRevision)
                } header: {
                    Text(.localized("Provider Identity"))
                }
            }
            .navigationTitle(.localized("Anisette Provider"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(.localized("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(verifyBeforeSaving ? String.localized("Save & Verify") : String.localized("Save")) {
                        onSave(endpointString, identity, displayName, policyRevision)
                    }
                    .disabled(isSaving || endpointString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}