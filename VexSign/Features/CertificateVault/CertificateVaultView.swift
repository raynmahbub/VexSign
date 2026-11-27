//
//  CertificateVaultView.swift
//  VexSign
//
//  Reads only the vault's persisted, non-secret inventory. Every control calls
//  the vault model; no parsing, cryptography, Keychain access or file scoping
//  happens in this file.
//

import SwiftUI
import UniformTypeIdentifiers

struct CertificateVaultView: View {
    @StateObject private var model = CertificateVaultModel()
    @WorkspaceQuery(\.importedApps, order: .name) private var apps: [LibraryAppRecord]
    @State private var showingCertificatePicker = false
    @State private var showingProfilePicker = false
    @State private var showingAppPicker = false

    var body: some View {
        List {
            if let loadError = model.snapshot.loadError {
                Section {
                    Text(loadError).foregroundStyle(.red)
                    Button("Recover Unreadable Inventory") { Task { await model.recoverInventory() } }
                }
            }
            vaultSection
            certificatesSection
            profilesSection
            compatibilitySection
            appReadinessSection
            if model.busy { ProgressView("Working…") }
        }
        .navigationTitle("Certificate Vault")
        .task { await model.load() }
        .fileImporter(
            isPresented: $showingCertificatePicker,
            allowedContentTypes: [UTType(filenameExtension: "p12") ?? .data, UTType(filenameExtension: "pfx") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { model.beginCertificateImport(url) }
            case .failure(let error):
                if (error as? CocoaError)?.code != .userCancelled { model.report(error) }
            }
        }
        .fileImporter(
            isPresented: $showingProfilePicker,
            allowedContentTypes: [UTType(filenameExtension: "mobileprovision") ?? .data,
                                  UTType(filenameExtension: "provisionprofile") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { Task { await model.importProfile(url) } }
            case .failure(let error):
                if (error as? CocoaError)?.code != .userCancelled { model.report(error) }
            }
        }
        .sheet(isPresented: Binding(
            get: { model.pendingCertificateURL != nil },
            set: { if !$0 { model.cancelCertificateImport() } }
        )) {
            CertificateVaultPasswordSheet(model: model)
        }
        .alert("Vault", isPresented: Binding(
            get: { model.message != nil },
            set: { if !$0 { model.clearMessage() } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(model.message ?? "")
        }
    }

    @ViewBuilder
    private var vaultSection: some View {
        Section {
            Text("Private keys are stored in the Keychain only. Passwords and PKCS#12 files are not kept in the vault inventory.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Import Identity (.p12/.pfx)") { showingCertificatePicker = true }
            Button("Import Provisioning Profile") { showingProfilePicker = true }
            Button("Refresh Keychain Status") { Task { await model.refreshKeyStates() } }
        } header: {
            Text("Vault")
        }
    }

    @ViewBuilder
    private var certificatesSection: some View {
        Section {
            if model.snapshot.state.certificates.isEmpty {
                Text("No identities in the vault.").foregroundStyle(.secondary)
            }
            ForEach(model.snapshot.state.certificates) { certificate in
                NavigationLink {
                    CertificateVaultCertificateDetail(certificate: certificate, model: model)
                } label: {
                    certificateRow(certificate)
                }
            }
        } header: {
            Text("Certificates")
        }
    }

    private func certificateRow(_ certificate: VaultCertificate) -> some View {
        let keyColor: Color = certificate.keyState == .accessible ? .green : .orange
        let expiryColor: Color = certificate.isExpired() ? .red : .secondary
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(certificate.displayName)
                Spacer()
                Text(certificate.keyState.rawValue)
                    .font(.caption)
                    .foregroundStyle(keyColor)
            }
            Text("\(certificate.shortFingerprint) · \(certificate.fingerprintIdentifier)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Text(expiryText(certificate.notAfter, prefix: "Certificate"))
                .font(.caption)
                .foregroundStyle(expiryColor)
        }
    }

    @ViewBuilder
    private var profilesSection: some View {
        Section {
            if model.snapshot.state.profiles.isEmpty {
                Text("No provisioning profiles in the vault.").foregroundStyle(.secondary)
            }
            ForEach(model.snapshot.state.profiles) { profile in
                NavigationLink {
                    CertificateVaultProfileDetail(profile: profile, model: model)
                } label: {
                    profileRow(profile)
                }
            }
        } header: {
            Text("Provisioning Profiles")
        }
    }

    private func profileRow(_ profile: VaultProfile) -> some View {
        let expiryColor: Color = profile.isExpired() ? .red : .secondary
        let typeText: String = profile.type.capitalized
        let expiry: String = expiryText(profile.expirationDate, prefix: "Profile")
        return VStack(alignment: .leading, spacing: 4) {
            Text(profile.name.isEmpty ? profile.uuid : profile.name)
            Text(profile.appIdentifier ?? "No App ID recorded")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Text("\(typeText) · \(expiry)")
                .font(.caption)
                .foregroundStyle(expiryColor)
        }
    }

    @ViewBuilder
    private var compatibilitySection: some View {
        Section {
            if model.snapshot.state.associations.isEmpty {
                Text("No certificate/profile pairs have been evaluated. Open a certificate to associate one.").foregroundStyle(.secondary)
            }
            ForEach(model.snapshot.state.associations) { association in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(association.outcome.rawValue)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(outcomeColor(association.outcome))
                        Spacer()
                        Text(association.evaluatedAt, style: .shortened)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(association.reasons, id: \.self) { reason in
                        Text(reason).font(.caption)
                    }
                }
            }
        } header: {
            Text("Compatibility")
        }
    }

    @ViewBuilder
    private var appReadinessSection: some View {
        Section {
            Picker("Library App", selection: $model.selectedApp) {
                Text("None").tag(nil as LibraryAppRecord?)
                ForEach(apps) { app in
                    Text(app.workspaceName.isEmpty ? (app.identifier ?? app.id) : app.workspaceName)
                        .tag(Optional(app))
                }
            }
            Button("Assess Signing Readiness") { Task { await model.assessSelectedApp() } }
                .disabled(model.selectedApp == nil || model.busy)
            if let readiness = model.readiness {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Readiness: \(readiness.state.rawValue)").font(.headline)
                    ForEach(readiness.explanation, id: \.self) { line in
                        Text(line).font(.caption)
                    }
                    Text("This is an assessment only; it does not sign or install an app.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("App Readiness")
        }
    }

    private func expiryText(_ date: Date?, prefix: String) -> String {
        guard let date else { return "\(prefix): date unavailable" }
        return "\(prefix) expires \(date.formatted(date: .abbreviated, time: .omitted))"
    }

    private func outcomeColor(_ outcome: VaultAssociationOutcome) -> Color {
        switch outcome {
        case .compatible: return .green
        case .requiresAdditionalValidation: return .orange
        case .incomplete: return .yellow
        default: return .red
        }
    }
}

private extension VaultCertificate {
    var fingerprintIdentifier: String { "SHA-256" }
}

private struct CertificateVaultPasswordSheet: View {
    @ObservedObject var model: CertificateVaultModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("PKCS#12 password", text: $model.password)
                    TextField("Display name (optional)", text: $model.displayName)
                }
                Section {
                    Text("The password is held only for this import. No copy is logged, exported, or saved outside the Keychain identity.").font(.caption)
                }
            }
            .navigationTitle("Identity Password")
            .navigationBarTitleDisplayMode(.inline)
            .dismissableKeyboard()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.cancelCertificateImport(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        Task {
                            await model.confirmCertificateImport()
                            dismiss()
                        }
                    }
                    .disabled(model.password.isEmpty || model.busy)
                }
            }
        }
    }
}

private struct CertificateVaultCertificateDetail: View {
    let certificate: VaultCertificate
    @ObservedObject var model: CertificateVaultModel
    @State private var showingReplacementPicker = false

    var body: some View {
        List {
            Section("Identity") {
                detail("Fingerprint", certificate.fingerprint)
                detail("Common name", certificate.commonName ?? "Unavailable")
                detail("Issuer", certificate.issuerCommonName ?? "Unavailable")
                detail("Team", certificate.teamIdentifier ?? "Unavailable")
                detail("Serial", certificate.serialNumber ?? "Unavailable")
                detail("Key", [certificate.keyAlgorithm, certificate.keySizeBits.map(String.init)].compactMap { $0 }.joined(separator: " "))
                detail("Key state", certificate.keyState.rawValue)
                detail("Not before", certificate.notBefore?.formatted() ?? "Unavailable")
                detail("Not after", certificate.notAfter?.formatted() ?? "Unavailable")
            }
            Section("Actions") {
                Button("Replace Identity") { showingReplacementPicker = true }
                Button("Delete from Vault", role: .destructive) {
                    Task { await model.deleteCertificate(certificate) }
                }
            }
            Section("Associated Profiles") {
                let matches = model.snapshot.state.associations.filter { $0.certificateID == certificate.id }
                if matches.isEmpty { Text("No associations yet.").foregroundStyle(.secondary) }
                ForEach(matches) { association in
                    VStack(alignment: .leading) {
                        Text(model.snapshot.state.profiles.first(where: { $0.id == association.profileID })?.name ?? association.profileID)
                        Text(association.outcome.rawValue).font(.caption)
                        ForEach(association.reasons, id: \.self) { Text($0).font(.caption2) }
                    }
                }
            }
        }
        .navigationTitle(certificate.displayName)
        .fileImporter(
            isPresented: $showingReplacementPicker,
            allowedContentTypes: [UTType(filenameExtension: "p12") ?? .data, UTType(filenameExtension: "pfx") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                model.beginCertificateImport(url, replacing: certificate.id)
            }
        }
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).textSelection(.enabled).multilineTextAlignment(.trailing)
        }
    }
}

private struct CertificateVaultProfileDetail: View {
    let profile: VaultProfile
    @ObservedObject var model: CertificateVaultModel

    var body: some View {
        List {
            Section("Profile") {
                detail("UUID", profile.uuid)
                detail("Name", profile.name)
                detail("App ID", profile.appIdentifier ?? "Unavailable")
                detail("Team", profile.teamIdentifier ?? "Unavailable")
                detail("Team name", profile.teamName ?? "Unavailable")
                detail("Type", profile.type)
                detail("Platforms", profile.platforms.joined(separator: ", "))
                detail("Created", profile.creationDate?.formatted() ?? "Unavailable")
                detail("Expires", profile.expirationDate?.formatted() ?? "Unavailable")
                detail("Validity", profile.validity.rawValue)
                detail("Parse status", profile.parseStatus.rawValue)
                detail("Scope", profile.provisionsAllDevices ? "All devices" : "\(profile.provisionedDevices.count) listed devices")
                if !profile.certificateFingerprints.isEmpty {
                    detail("Authorized certificate", profile.certificateFingerprints[0])
                }
            }
            ForEach(profile.limitations, id: \.self) { limitation in
                Text(limitation).font(.caption).foregroundStyle(.orange)
            }
            Section("Entitlements") {
                if profile.entitlements.isEmpty {
                    Text("No entitlements were recorded.").foregroundStyle(.secondary)
                }
                ForEach(profile.entitlements, id: \.key) { entitlement in
                    VStack(alignment: .leading) {
                        Text(entitlement.key).font(.caption.monospaced())
                        Text(entitlement.value).font(.caption2).textSelection(.enabled)
                    }
                }
            }
            Section("Capabilities") {
                if profile.capabilities.isEmpty {
                    Text("No named capabilities were recognized.").foregroundStyle(.secondary)
                } else {
                    Text(profile.capabilities.joined(separator: ", "))
                }
            }
            Section("Certificate Pairing") {
                if model.snapshot.state.certificates.isEmpty {
                    Text("Import a certificate to evaluate this profile.").foregroundStyle(.secondary)
                }
                ForEach(model.snapshot.state.certificates) { certificate in
                    Button("Evaluate \(certificate.displayName)") {
                        Task { await model.associate(certificate, with: profile) }
                    }
                }
            }
            Section {
                Button("Delete Profile", role: .destructive) {
                    Task { await model.deleteProfile(profile) }
                }
            }
        }
        .navigationTitle(profile.name.isEmpty ? "Profile" : profile.name)
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).textSelection(.enabled).multilineTextAlignment(.trailing)
        }
    }
}
