import Foundation
import Combine

@MainActor
final class SigningPreferencesModel: ObservableObject {
    @Published var options: Options {
        didSet { if !applying && options != oldValue { useCase.saveOptions(options) } }
    }
    @Published private(set) var profiles: [NamedSigningProfile]
    @Published private(set) var canAutoSign: Bool
    private let useCase: SigningPreferencesUseCase
    private let platform: PlatformSystemAdapting
    private var applying = false
    private var observation: Task<Void, Never>?

    init(useCase: SigningPreferencesUseCase, platform: PlatformSystemAdapting) {
        self.useCase = useCase
        self.platform = platform
        let state = useCase.state()
        self.options = state.options
        self.profiles = state.profiles
        self.canAutoSign = state.canAutoSign
        let changes = useCase.changes()
        observation = Task { @MainActor [weak self] in
            for await state in changes {
                guard !Task.isCancelled, let self else { break }
                self.applying = true
                if self.options != state.options { self.options = state.options }
                self.profiles = state.profiles
                self.canAutoSign = state.canAutoSign
                self.applying = false
            }
        }
    }
    deinit { observation?.cancel() }
    var batchBase: Options {
        options.withoutPerAppFields()
    }
    func saveOptions() { useCase.saveOptions(options) }
    func resetToDefaults() { options = .defaultOptions }
    func save(_ profile: NamedSigningProfile) { useCase.saveProfile(profile); profiles = useCase.state().profiles }
    func remove(id: String) { useCase.removeProfile(id: id); profiles = useCase.state().profiles }
    func importProfiles(from url: URL) throws { try useCase.importProfiles(from: url); profiles = useCase.state().profiles }
    func shareProfiles() {
        do { try useCase.shareProfiles() }
        catch { platform.notifyError(error.localizedDescription, sticky: true) }
    }
}
