import Foundation

struct SigningPreferencesState {
    var options: Options
    var profiles: [NamedSigningProfile]
    var canAutoSign: Bool
}

@MainActor
protocol SigningPreferencesProviding: AnyObject {
    func state() -> SigningPreferencesState
    func changes() -> AsyncStream<SigningPreferencesState>
    func saveOptions(_ options: Options)
    func saveProfile(_ profile: NamedSigningProfile)
    func removeProfile(id: String)
    func importProfiles(from url: URL) throws
    func shareProfiles() throws
}

/// Stable preference identifiers are value contracts, not implementation owners.
enum SigningPreferenceKeys {
    static let autoSignAfterImport = "VexSign.autoSignAfterImport"
}
