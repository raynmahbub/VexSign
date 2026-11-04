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
    @State private var testResult: String?
    @State private var isTesting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "server.rack")
                    .foregroundStyle(.accentColor)
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
                        .buttonStyle(NBButtonStyle(.bordered))

                        Button(role: .destructive) {
                            factory.clearConfiguration()
                        } label: {
                            Label(.localized("Remove"), systemImage: "trash")
                        }
                        .buttonStyle(NBButtonStyle(.bordered))

                        Button {
                            testProvider()
                        } label: {
                            if isTesting {
                                ProgressView().scaleEffect(0.8)
                            } else {
                                Label(.localized("Test"), systemImage: "checkmark.shield")
                            }
                        }
                        .buttonStyle(NBButtonStyle(.bordered))
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
                        showEndpointEditor = true
                    } label: {
                        Label(.localized("Configure Provider"), systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(NBButtonStyle(.prominent))
                }
            }
        }
        .padding()
        .background(Color(uiColor: .quaternarySystemFill))
        .cornerRadius(14)
        .sheet(isPresented: $showEndpointEditor) {
            AnisetteEndpointEditorView(
                endpointString: $endpointString,
                identity: $identity,
                displayName: $displayName,
                policyRevision: $policyRevision,
                onSave: { endpoint, id, name, revision in
                    do {
                        let url = try validateEndpoint(endpoint)
                        try factory.configureHTTPS(
                            endpoint: url,
                            identity: id,
                            displayName: name,
                            policyRevision: revision
                        )
                        showEndpointEditor = false
                    } catch {
                        testResult = "❌ \(error.localizedDescription)"
                    }
                }
            )
            .presentationDetents([.medium])
        }
    }

    private func fillEditor(from descriptor: AnisetteProviderDescriptor) {
        endpointString = descriptor.endpoint?.absoluteString ?? ""
        identity = descriptor.identifier
        displayName = descriptor.displayName
        policyRevision = descriptor.policyRevision
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
                let provider = try HTTPSAnisetteProvider<SystemAnisetteHeaderTransport>(descriptor: descriptor)
                _ = try await provider.freshHeaders()
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
    let onSave: (String, String, String, String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(.localized("HTTPS Endpoint URL"), text: $endpointString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text(.localized("Server Endpoint"))
                } footer: {
                    Text(.localized("The endpoint must return the 10 required Apple anisette headers as JSON. See documentation for format."))
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
                    Button(.localized("Save")) {
                        onSave(endpointString, identity, displayName, policyRevision)
                    }
                    .disabled(endpointString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}