//
//  VaultPersistence.swift
//  VexSign
//
//  One small JSON inventory of public metadata. Private keys and passwords are
//  never written here; they exist only in the Keychain. Writes are atomic and
//  bounded so a truncated or replaced file cannot look like a valid vault.
//

import Foundation

struct VaultPersistence {
    static let schema = 1
    private static let maximumBytes = 4 * 1024 * 1024
    private static let fileName = "vault-inventory.json"

    let directory: URL
    private var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Private/CertificateVault", isDirectory: true)
    }

    init(directory: URL = VaultPersistence.defaultDirectory) {
        self.directory = directory
    }

    func load() throws -> VaultStoredState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .empty }
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        guard data.count <= Self.maximumBytes, !data.isEmpty else { throw VaultError.saveFailed }
        do {
            let state = try JSONDecoder().decode(VaultStoredState.self, from: data)
            guard state.schema == Self.schema else { throw VaultError.saveFailed }
            return state
        } catch {
            throw VaultError.saveFailed
        }
    }

    var hasInventory: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    /// Called only after the user confirms recovery: a corrupt inventory is
    /// preserved beside the live file instead of being silently overwritten.
    func quarantineCorruptInventory() throws {
        guard hasInventory else { return }
        let backup = directory.appendingPathComponent(
            "vault-inventory.unreadable-\(Int(Date().timeIntervalSince1970)).json"
        )
        try FileManager.default.moveItem(at: fileURL, to: backup)
    }

    func save(_ state: VaultStoredState) throws {
        var state = state
        state.schema = Self.schema
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(state)
        guard data.count <= Self.maximumBytes else { throw VaultError.saveFailed }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}
