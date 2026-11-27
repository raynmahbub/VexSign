//
//  VaultKeychain.swift
//  VexSign
//
//  The only place that handles Keychain identity material for the vault. Each
//  identity is addressed by a stable content-derived label, is restricted to
//  this device, and requires the device to be unlocked. No key bytes are ever
//  exported into the vault inventory, a log, or a view model.
//

import Foundation
import Security

protocol VaultKeychainStoring: AnyObject {
    func addIdentity(_ identity: SecIdentity?, id: String) throws
    func identity(id: String) -> SecIdentity?
    func deleteIdentity(id: String) throws
    func keyState(id: String) -> VaultKeyState
}

final class VaultKeychainStore: VaultKeychainStoring {
    func addIdentity(_ identity: SecIdentity?, id: String) throws {
        guard let identity else { throw VaultError.keychainUnavailable }
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecValueRef as String: identity,
            kSecAttrLabel as String: VaultIdentifier.keychainLabel(certificateID: id),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // A stable label is intentional: re-importing the same certificate
            // replaces the existing Keychain identity rather than adding a
            // second, ambiguous copy.
            try deleteIdentity(id: id)
            let retry = SecItemAdd(query as CFDictionary, nil)
            guard retry == errSecSuccess else { throw VaultError.keychainWriteFailed }
            return
        }
        guard status == errSecSuccess else { throw VaultError.keychainWriteFailed }
    }

    func identity(id: String) -> SecIdentity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: VaultIdentifier.keychainLabel(certificateID: id),
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let item else { return nil }
        // The query asks for a SecIdentity reference; verify the runtime type
        // before the cast because the Keychain can return other item classes.
        guard CFGetTypeID(item) == SecIdentityGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        return item as! SecIdentity
    }

    func deleteIdentity(id: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: VaultIdentifier.keychainLabel(certificateID: id)
        ]
        let status = SecItemDelete(query as CFDictionary)
        // An already-missing key is the recovery state, not a deletion failure:
        // the user must still be able to remove a stale metadata row.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw VaultError.keychainUnavailable
        }
    }

    func keyState(id: String) -> VaultKeyState {
        guard let identity = identity(id: id) else { return .missing }
        do {
            return try SigningIdentityStore.probe(identity).keyAvailability == .accessible
                ? .accessible
                : .inaccessible
        } catch {
            return .inaccessible
        }
    }
}
