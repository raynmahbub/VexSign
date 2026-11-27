//
//  CertificateVault.swift
//  VexSign
//
//  One owner for certificate identities, provisioning profiles and their
//  associations. Every mutation is serialized on this actor: two simultaneous
//  imports cannot race for one Keychain label or overwrite each other's index.
//  Private keys are added to the Keychain only; the JSON inventory holds public
//  metadata exclusively.
//

import Foundation
import Security

struct VaultSnapshot: Sendable {
    let state: VaultStoredState
    let loadError: String?
}

actor CertificateVault {
    private let persistence: VaultPersistence
    private let keychain: any VaultKeychainStoring
    private let opener: any VaultIdentityOpening
    private let documentReader: VaultDocumentReader
    private var state: VaultStoredState = .empty
    private var inventoryUnreadable = false

    init(
        persistence: VaultPersistence = VaultPersistence(),
        keychain: any VaultKeychainStoring = VaultKeychainStore(),
        opener: any VaultIdentityOpening = VaultPKCS12Opener(),
        documentReader: VaultDocumentReader = VaultDocumentReader()
    ) {
        self.persistence = persistence
        self.keychain = keychain
        self.opener = opener
        self.documentReader = documentReader
        do {
            state = try persistence.load()
        } catch {
            // Never overwrite an unreadable inventory as though it were empty.
            // The UI must offer explicit recovery first.
            inventoryUnreadable = true
            state = .empty
        }
    }

    func snapshot() -> VaultSnapshot {
        VaultSnapshot(
            state: state,
            loadError: inventoryUnreadable
                ? "The vault inventory could not be read. Recover it before importing or deleting items."
                : nil
        )
    }

    /// Moves the unreadable file aside and reloads. The old file is retained
    /// locally for diagnosis; no private material is in it.
    func recoverInventory() async throws {
        guard inventoryUnreadable else { return }
        try persistence.quarantineCorruptInventory()
        state = try persistence.load()
        inventoryUnreadable = false
    }

    func keyState(id: String) async -> VaultKeyState { keychain.keyState(id: id) }

    // MARK: - Certificates

    func importCertificate(data: Data, password: String, displayName: String?) async throws -> VaultCertificate {
        try requireHealthyInventory()
        let opened = try opener.open(data: data, password: password)
        let id = VaultIdentifier.certificateID(fingerprint: opened.metadata.fingerprint)
        guard !state.certificates.contains(where: { $0.id == id }) else { throw VaultError.duplicateCertificate }
        try keychain.addIdentity(opened.identity, id: id)
        let entry = certificate(from: opened.metadata, id: id, displayName: displayName)
        state.certificates.append(entry)
        do {
            try persist()
        } catch {
            state.certificates.removeAll { $0.id == id }
            discardIdentity(id: id)
            throw error
        }
        return entry
    }

    func replaceCertificate(id: String, data: Data, password: String, displayName: String?) async throws -> VaultCertificate {
        try requireHealthyInventory()
        guard let index = state.certificates.firstIndex(where: { $0.id == id }) else { throw VaultError.certificateNotFound }
        let opened = try opener.open(data: data, password: password)
        guard VaultIdentifier.certificateID(fingerprint: opened.metadata.fingerprint) == id else {
            throw VaultError.replacementRequiresSameIdentity
        }
        let previous = state.certificates[index]
        let previousIdentity = keychain.identity(id: id)
        do {
            try keychain.addIdentity(opened.identity, id: id)
        } catch {
            throw VaultError.keychainWriteFailed
        }
        let replacement = certificate(from: opened.metadata, id: id, displayName: displayName ?? previous.displayName)
        state.certificates[index] = replacement
        do {
            try persist()
        } catch {
            state.certificates[index] = previous
            if let previousIdentity {
                restoreIdentity(previousIdentity, id: id)
            } else {
                discardIdentity(id: id)
            }
            throw error
        }
        return replacement
    }

    func deleteCertificate(id: String) async throws {
        try requireHealthyInventory()
        guard let index = state.certificates.firstIndex(where: { $0.id == id }) else { throw VaultError.certificateNotFound }
        let previous = state.certificates[index]
        let previousAssociations = state.associations
        do { try keychain.deleteIdentity(id: id) } catch { throw VaultError.keychainUnavailable }
        state.certificates.remove(at: index)
        state.associations.removeAll { $0.certificateID == id }
        do {
            try persist()
        } catch {
            // The private key is already gone. Restore a metadata row marked
            // as such rather than leaving the user with an unexplained gap.
            var stale = previous
            stale = VaultCertificate(
                id: stale.id, fingerprint: stale.fingerprint, displayName: stale.displayName,
                commonName: stale.commonName, issuerCommonName: stale.issuerCommonName,
                teamIdentifier: stale.teamIdentifier, serialNumber: stale.serialNumber,
                notBefore: stale.notBefore, notAfter: stale.notAfter,
                keyAlgorithm: stale.keyAlgorithm, keySizeBits: stale.keySizeBits,
                importedAt: stale.importedAt, keyState: .missing
            )
            state.certificates.insert(stale, at: index)
            state.associations = previousAssociations
            throw error
        }
    }

    /// Re-reads each Keychain identity after a lock/unlock cycle or a Keychain
    /// change made outside the app. Missing material becomes visible instead of
    /// looking like a usable certificate.
    func refreshKeyStates() async throws {
        try requireHealthyInventory()
        state.certificates = state.certificates.map { entry in
            var copy = entry
            copy = VaultCertificate(
                id: copy.id, fingerprint: copy.fingerprint, displayName: copy.displayName,
                commonName: copy.commonName, issuerCommonName: copy.issuerCommonName,
                teamIdentifier: copy.teamIdentifier, serialNumber: copy.serialNumber,
                notBefore: copy.notBefore, notAfter: copy.notAfter,
                keyAlgorithm: copy.keyAlgorithm, keySizeBits: copy.keySizeBits,
                importedAt: copy.importedAt, keyState: keychain.keyState(id: copy.id)
            )
            return copy
        }
        try persist()
    }

    // MARK: - Profiles

    @discardableResult
    func importProfile(data: Data) async throws -> VaultProfile {
        try requireHealthyInventory()
        let profile = try VaultProfileImporter.parse(data)
        let previous = state.profiles.first { $0.id == profile.id }
        if let index = state.profiles.firstIndex(where: { $0.id == profile.id }) {
            state.profiles[index] = profile
        } else {
            state.profiles.append(profile)
        }
        do {
            try persist()
            await reevaluateAssociations()
        } catch {
            if let previous, let index = state.profiles.firstIndex(where: { $0.id == profile.id }) {
                state.profiles[index] = previous
            } else {
                state.profiles.removeAll { $0.id == profile.id }
            }
            throw error
        }
        return profile
    }

    func deleteProfile(id: String) async throws {
        try requireHealthyInventory()
        guard let index = state.profiles.firstIndex(where: { $0.id == id }) else { throw VaultError.profileNotFound }
        let previous = state.profiles[index]
        let previousAssociations = state.associations
        state.profiles.remove(at: index)
        state.associations.removeAll { $0.profileID == id }
        do {
            try persist()
        } catch {
            state.profiles.insert(previous, at: index)
            state.associations = previousAssociations
            throw error
        }
    }

    // MARK: - Associations

    @discardableResult
    func associate(certificateID: String, profileID: String, target: VaultCompatibilityTarget) async throws -> VaultAssociation {
        try requireHealthyInventory()
        guard let certificate = state.certificates.first(where: { $0.id == certificateID }) else {
            throw VaultError.certificateNotFound
        }
        guard let profile = state.profiles.first(where: { $0.id == profileID }) else {
            throw VaultError.profileNotFound
        }
        let association = VaultCompatibility.evaluate(
            certificate: certificate, profile: profile, target: target
        )
        let previous = state.associations.first { $0.id == association.id }
        if let index = state.associations.firstIndex(where: { $0.id == association.id }) {
            state.associations[index] = association
        } else {
            state.associations.append(association)
        }
        do {
            try persist()
        } catch {
            if let previous, let index = state.associations.firstIndex(where: { $0.id == association.id }) {
                state.associations[index] = previous
            } else {
                state.associations.removeAll { $0.id == association.id }
            }
            throw error
        }
        return association
    }

    func reevaluateAssociations() async {
        guard !inventoryUnreadable else { return }
        state.associations = state.associations.compactMap { association in
            guard let certificate = state.certificates.first(where: { $0.id == association.certificateID }),
                  let profile = state.profiles.first(where: { $0.id == association.profileID }) else { return nil }
            return VaultCompatibility.evaluate(
                certificate: certificate, profile: profile, target: association.target
            )
        }
        // Derived values are recomputed in memory even if a persistence write
        // fails; a transient disk error must not show a stale verdict as truth.
        do { try persist() } catch { }
    }

    /// Security-scoped reading happens here, never in a SwiftUI view.
    func certificateData(from url: URL) async throws -> Data { try documentReader.read(url) }

    // MARK: - Internals

    private func requireHealthyInventory() throws {
        if inventoryUnreadable { throw VaultError.saveFailed }
    }

    private func persist() throws {
        guard !inventoryUnreadable else { throw VaultError.saveFailed }
        try persistence.save(state)
    }

    private func certificate(
        from metadata: VaultIdentityMetadata,
        id: String,
        displayName: String?
    ) -> VaultCertificate {
        let proposed = (displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return VaultCertificate(
            id: id,
            fingerprint: metadata.fingerprint,
            displayName: proposed.isEmpty ? (metadata.commonName ?? "Imported certificate") : proposed,
            commonName: metadata.commonName,
            issuerCommonName: metadata.issuerCommonName,
            teamIdentifier: metadata.teamIdentifier,
            serialNumber: metadata.serialNumber,
            notBefore: metadata.notBefore,
            notAfter: metadata.notAfter,
            keyAlgorithm: metadata.keyAlgorithm,
            keySizeBits: metadata.keySizeBits,
            importedAt: Date(),
            keyState: keychain.keyState(id: id)
        )
    }

    private func discardIdentity(id: String) {
        do { try keychain.deleteIdentity(id: id) } catch { /* best effort after a rolled-back import */ }
    }

    private func restoreIdentity(_ identity: SecIdentity, id: String) {
        do { try keychain.addIdentity(identity, id: id) } catch { /* the row keeps its missing-key state */ }
    }
}
