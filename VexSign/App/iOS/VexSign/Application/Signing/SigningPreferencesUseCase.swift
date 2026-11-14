import Foundation

@MainActor
final class SigningPreferencesUseCase {
    private let provider: SigningPreferencesProviding
    init(provider: SigningPreferencesProviding) { self.provider = provider }
    func state() -> SigningPreferencesState { provider.state() }
    func changes() -> AsyncStream<SigningPreferencesState> { provider.changes() }
    func saveOptions(_ options: Options) { provider.saveOptions(options) }
    func saveProfile(_ profile: NamedSigningProfile) { provider.saveProfile(profile.withoutOneShotFiles()) }
    func removeProfile(id: String) { provider.removeProfile(id: id) }
    func importProfiles(from url: URL) throws { try provider.importProfiles(from: url) }
    func shareProfiles() throws { try provider.shareProfiles() }
}
