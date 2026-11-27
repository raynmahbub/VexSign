//
//  CertificateVaultModel.swift
//  VexSign
//
//  UI state for the vault. The model never parses a PKCS#12, profiles, Keychain
//  data, or IPA bytes itself: it only reads security-scoped files through the
//  vault and hands the results to the SwiftUI views.
//

import Foundation
import SwiftUI

@MainActor
final class CertificateVaultModel: ObservableObject {
    typealias InspectionReader = (LibraryAppRecord) -> AppBundleInspection?

    @Published private(set) var snapshot = VaultSnapshot(state: .empty, loadError: nil)
    @Published private(set) var message: String?
    @Published private(set) var busy = false
    @Published var pendingCertificateURL: URL?
    @Published var pendingProfileURL: URL?
    @Published var password = ""
    @Published var displayName = ""
    @Published var selectedApp: LibraryAppRecord?
    @Published private(set) var readiness: VaultReadiness?

    private let vault: CertificateVault
    private let inspectionReader: InspectionReader
    private var replacingCertificateID: String?

    init(
        vault: CertificateVault = CertificateVault(),
        inspectionReader: @escaping InspectionReader = { app in VaultInspectionLookup.report(for: app) }
    ) {
        self.vault = vault
        self.inspectionReader = inspectionReader
    }

    func load() async {
        snapshot = await vault.snapshot()
    }

    func recoverInventory() async {
        await run {
            try await vault.recoverInventory()
            await load()
        }
    }

    // MARK: - Certificate import

    func beginCertificateImport(_ url: URL, replacing id: String? = nil) {
        pendingCertificateURL = url
        replacingCertificateID = id
        password = ""
        displayName = id == nil ? url.deletingPathExtension().lastPathComponent : ""
    }

    func cancelCertificateImport() {
        pendingCertificateURL = nil
        replacingCertificateID = nil
        password = ""
        displayName = ""
    }

    func confirmCertificateImport() async {
        guard let url = pendingCertificateURL else { return }
        let replacing = replacingCertificateID
        await run {
            let data = try await vault.certificateData(from: url)
            if let replacing {
                _ = try await vault.replaceCertificate(
                    id: replacing, data: data, password: password, displayName: displayName
                )
            } else {
                _ = try await vault.importCertificate(
                    data: data, password: password, displayName: displayName
                )
            }
            cancelCertificateImport()
            await load()
            self.message = replacing == nil ? "Certificate imported into the Keychain vault." : "Certificate identity replaced."
        }
    }

    func deleteCertificate(_ entry: VaultCertificate) async {
        await run {
            try await vault.deleteCertificate(id: entry.id)
            await load()
            self.message = "Certificate removed from the vault. It was not revoked with Apple."
        }
    }

    func refreshKeyStates() async {
        await run {
            try await vault.refreshKeyStates()
            await load()
        }
    }

    // MARK: - Profiles and associations

    func importProfile(_ url: URL) async {
        await run {
            let data = try await vault.certificateData(from: url)
            _ = try await vault.importProfile(data: data)
            pendingProfileURL = nil
            await load()
            self.message = "Provisioning profile parsed and saved to the vault."
        }
    }

    func deleteProfile(_ profile: VaultProfile) async {
        await run {
            try await vault.deleteProfile(id: profile.id)
            await load()
        }
    }

    func associate(_ certificate: VaultCertificate, with profile: VaultProfile) async {
        await run {
            let target = VaultCompatibilityTarget(
                bundleIdentifier: profile.appIdentifier,
                teamIdentifier: profile.teamIdentifier,
                entitlements: Dictionary(uniqueKeysWithValues: profile.entitlements.map { ($0.key, $0.value) }),
                platforms: profile.platforms
            )
            let association = try await vault.associate(
                certificateID: certificate.id, profileID: profile.id, target: target
            )
            await load()
            self.message = association.reasons.first ?? "Association evaluated."
        }
    }

    func assessSelectedApp() async {
        guard let app = selectedApp else { return }
        await run {
            guard let inspection = inspectionReader(app) else {
                readiness = VaultReadiness(
                    state: .unavailable,
                    certificateID: nil,
                    profileID: nil,
                    explanation: [
                        "This library app has no readable inspection report. Re-import the IPA to produce one before assessing signing readiness."
                    ]
                )
                return
            }
            let snapshot = await vault.snapshot()
            readiness = VaultReadinessAssessor.assess(
                inspection: inspection,
                certificates: snapshot.state.certificates,
                profiles: snapshot.state.profiles,
                associations: snapshot.state.associations
            )
        }
    }

    func report(_ error: Error) { message = error.localizedDescription }

    func clearMessage() { message = nil }

    private func run(_ operation: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        message = nil
        defer { busy = false }
        do {
            try await operation()
        } catch {
            // Vault errors are fixed, non-secret statements by construction.
            message = error.localizedDescription
        }
    }
}
