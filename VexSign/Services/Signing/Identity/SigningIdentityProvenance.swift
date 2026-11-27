// MARK: - Explicit signing identity provenance
//
// Source is recorded at the exact point an integration obtains or imports an
// identity. It is never guessed from a nickname, filename, folder, team name or
// catalogue badge. Only public identifiers are persisted here; passwords,
// tokens and key material never reach UserDefaults.

import Foundation

enum SigningIdentityProvenance: String, Codable, Equatable, Sendable {
    case appleAccountHandoff
    case communityNexCerts
    case importedByUser
}

enum SigningIdentityProvenanceStore {
    static let storageKey = "VexSign.signingIdentityProvenance"
    private static let limit = 512

    static func source(for uuid: String?, defaults: UserDefaults = .standard) -> SigningIdentityProvenance? {
        guard let uuid, UUID(uuidString: uuid) != nil else { return nil }
        return all(defaults: defaults)[uuid].flatMap { SigningIdentityProvenance(rawValue: $0) }
    }

    static func record(_ source: SigningIdentityProvenance, uuid: String, defaults: UserDefaults = .standard) {
        guard UUID(uuidString: uuid) != nil else { return }
        var values = all(defaults: defaults)
        values[uuid] = source.rawValue
        if values.count > limit {
            let extra = Array(values.keys.sorted().prefix(values.count - limit))
            extra.forEach { values.removeValue(forKey: $0) }
        }
        defaults.set(values, forKey: storageKey)
    }

    static func remove(uuid: String, defaults: UserDefaults = .standard) {
        var values = all(defaults: defaults)
        values.removeValue(forKey: uuid)
        if values.isEmpty { defaults.removeObject(forKey: storageKey) }
        else { defaults.set(values, forKey: storageKey) }
    }

    private static func all(defaults: UserDefaults) -> [String: String] {
        (defaults.dictionary(forKey: storageKey) as? [String: String]) ?? [:]
    }
}
